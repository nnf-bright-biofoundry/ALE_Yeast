#!/usr/bin/env bash
# Generate the ottilie test set (the release contract test's input), version 2.
#
# Two samples of Ottilie et al. (parent + evolved), cut down twice:
#   1. to the read pairs that map to chromosomes I, IV, VII, XV and Mito, and
#   2. to a fixed FRACTION of those pairs per sample (seeded, so the cut is reproducible),
# plus the S288C reference subset to the same five contigs.
#
# Provenance:
#   Source:       SRA SRR10985539 (NODRUG-GM2, parent) and SRR10985585 (CBR110-15-R3a, evolved)
#   Publication:  Ottilie et al., Commun Biol 5:128 (2022)
#                 https://doi.org/10.1038/s42003-022-03076-7
#   Contigs:      I (whole-chromosome gain in CBR110), IV (2 truth SNVs), VII (1), XV (1),
#                 Mito (the only contig with its own genetic code and a non-chromosome type)
#   Truth SNVs:   IV:205738 C>A (RPO21), IV:1184212 G>T (TRR1),
#                 VII:233903 G>A (ROG1), XV:639861 G>T (YRR1)
#   Truth CNV:    chr I whole-chromosome gain in CBR110-15-R3a
#
# The reads always come from the SRA FASTQs, never from a pipeline CRAM: since 2026-09-04 the
# pipeline's CRAMs hold trimmed reads, and a set cut from one would be trimmed before the pipeline
# sees it. (Version 1 was cut from CRAMs of an untrimmed run, at full depth.)
#
# What the cut keeps and drops (state it wherever the set is described):
#   kept     both mates of every pair with both mates mapped to one of the five contigs,
#            duplicates and QC-fail reads included
#   dropped  pairs with a mate unmapped or on another contig; secondary and supplementary records
#   then     a seeded fraction of the kept pairs: `samtools view -s SEED.FRACTION` hashes the read
#            name, so a pair is kept or dropped as a whole
#
# Tools: the alignment and every samtools step run in one pinned bwa-mem2 2.2.1 + samtools 1.21
# image (IMAGE below, a public Seqera community image), so the cut does not depend
# on what a conda environment holds. This alignment only selects reads; the pipeline aligns the
# selected reads again with its own aligner. Needs docker
# and `python` (any 3.x, standard library only).
#
# Usage (from anywhere; paths are derived from this script's location):
#   bash .../generate_test_data.sh                  # the published cut, into data/ottilie/
#   bash .../generate_test_data.sh --align-only     # stop after the alignment; print depth per contig
#
# Environment:
#   OUT_ROOT            where fastq_test/, S288C_reference_test/ and samplesheet_test.csv go
#                       (default <repo>/data/ottilie; point it elsewhere to cut a candidate set)
#   SEED                subsampling seed (default 42)
#   FRACTION_PARENT     fraction of the kept pairs, NODRUG-GM2     (default below; form 0.NN)
#   FRACTION_EVOLVED    fraction of the kept pairs, CBR110-15-R3a  (default below; form 0.NN)
#   BUILD_DIR           alignment intermediates, reused between runs (default <repo>/.ottilie_test_build)
#   THREADS             default 4
#
# After a cut: run the pipeline on it and then check_test_data_truth.py on the output. The publish
# script refuses a set whose FASTQs that check has not passed.

set -euo pipefail

# ---------- Configuration ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

# Source data
FULL_REF="$REPO_ROOT/data/ottilie/S288C_reference/S288C_R64.fa"
FULL_GB="$REPO_ROOT/data/ottilie/S288C_reference/S288C_R64_ensembl_chrnames.gb"
FULL_CHR_DIR="$REPO_ROOT/data/ottilie/S288C_reference/chromosomes"
FULL_SNPEFF="$REPO_ROOT/data/ottilie/S288C_reference/snpeff_cache"
FASTQ_DIR="$REPO_ROOT/data/ottilie/fastq"

# Output
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/data/ottilie}"
OUT_FASTQ="$OUT_ROOT/fastq_test"
OUT_REF="$OUT_ROOT/S288C_reference_test"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/.ottilie_test_build}"

# The cut
CHROMS=("I" "IV" "VII" "XV" "Mito")
CHROM_TAG="chrI_IV_VII_XV_Mito"
SEED="${SEED:-42}"
THREADS="${THREADS:-4}"

# bwa-mem2 2.2.1 + samtools 1.21. Digest when the published cut was made (2026-11-11):
# sha256:16df04c120f0ca4dae684f3b892eb36d4fcb72c42a3918a4470058b13169f4da
IMAGE="${IMAGE:-community.wave.seqera.io/library/bwa-mem2_htslib_samtools:e1f420694f8e42bd}"

SAMPLE_ORDER=("NODRUG-GM2" "CBR110-15-R3a")
declare -A SRR=( [NODRUG-GM2]="SRR10985539" [CBR110-15-R3a]="SRR10985585" )
# The published cut: the same fraction of both samples, which is about 30x for the parent and
# 60x for the evolved clone on the four nuclear chromosomes (the kept pairs give 44.5x and 89.6x).
# The SV junction calls set the floor, not the SNVs: the evolved library yields about a third of
# the parent's junction-spanning pairs per unit depth, and at 30x joint Manta genotypes it
# hom-ref at half of the strain's cassette junctions. Measurements: DATA_PROVENANCE.md.
declare -A FRACTION=(
    [NODRUG-GM2]="${FRACTION_PARENT:-0.67}"
    [CBR110-15-R3a]="${FRACTION_EVOLVED:-0.67}"
)

MODE="cut"
case "${1:-}" in
    "")            ;;
    --align-only)  MODE="align-only" ;;
    --from-sra)    ;;   # the only route now; accepted so older command lines keep working
    --from-cram)
        echo "ERROR: --from-cram is gone. The pipeline's CRAMs hold trimmed reads since 2026-09-04;" >&2
        echo "       the test set is cut from the SRA FASTQs only." >&2
        exit 1 ;;
    *) echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
esac

if [[ "$MODE" == "cut" ]]; then
    for s in "${SAMPLE_ORDER[@]}"; do
        [[ "${FRACTION[$s]}" =~ ^0\.[0-9]+$ ]] || {
            echo "ERROR: fraction for $s is '${FRACTION[$s]}'; expected the form 0.NN (strictly between 0 and 1)." >&2
            exit 1; }
    done
fi
command -v docker >/dev/null || { echo "ERROR: docker not found (the alignment runs in $IMAGE)." >&2; exit 1; }

# Run a command line inside the image, as the calling user, with the repo mounted at its own path.
dk() {
    docker run --rm -u "$(id -u):$(id -g)" -v "$REPO_ROOT:$REPO_ROOT" -w "$REPO_ROOT" "$IMAGE" bash -euo pipefail -c "$1"
}
case "$OUT_ROOT/" in "$REPO_ROOT"/*) ;; *) echo "ERROR: OUT_ROOT must be inside the repository ($REPO_ROOT): the image only sees that tree." >&2; exit 1 ;; esac
case "$BUILD_DIR/" in "$REPO_ROOT"/*) ;; *) echo "ERROR: BUILD_DIR must be inside the repository ($REPO_ROOT)." >&2; exit 1 ;; esac

echo "============================================"
echo "Generate the ottilie test set"
echo "Mode:      $MODE"
echo "Contigs:   ${CHROMS[*]}"
echo "Samples:   ${SAMPLE_ORDER[*]}"
[[ "$MODE" == "cut" ]] && echo "Seed:      $SEED   fractions: NODRUG-GM2 ${FRACTION[NODRUG-GM2]}, CBR110-15-R3a ${FRACTION[CBR110-15-R3a]}"
echo "Image:     $IMAGE"
echo "Output:    $OUT_ROOT"
echo "Build dir: $BUILD_DIR"
echo "============================================"
echo ""

mkdir -p "$BUILD_DIR"

# ---------- Step 1: align the SRA reads, keep the pairs on the five contigs ----------
# One region BAM per sample, kept in BUILD_DIR: every cut (any seed, any fraction) starts from it.

echo "=== Step 1: alignment and contig extraction ==="
for sample in "${SAMPLE_ORDER[@]}"; do
    srr="${SRR[$sample]}"
    region="$BUILD_DIR/${sample}.region.bam"
    if [[ -s "$region" && -s "$region.bai" ]]; then
        echo "  $sample: reusing $region"
        continue
    fi
    R1="$FASTQ_DIR/${srr}_1.fastq.gz"; R2="$FASTQ_DIR/${srr}_2.fastq.gz"
    [[ -f "$R1" && -f "$R2" ]] || {
        echo "ERROR: $R1 / $R2 not found." >&2
        echo "       Fetch the two runs from SRA first (fasterq-dump $srr --split-files, then gzip;" >&2
        echo "       environment: 01_data_retrieval/environment_data_retrieval.yml)." >&2
        exit 1; }
    [[ -f "${FULL_REF}.bwt.2bit.64" ]] || { echo "  building the bwa-mem2 index of the full reference..."; dk "bwa-mem2 index '$FULL_REF'"; }

    echo "  $sample ($srr): aligning to the full S288C R64 reference (all 17 contigs)..."
    # -K fixes the batch size, so the alignment does not depend on the thread count.
    dk "bwa-mem2 mem -t $THREADS -K 100000000 '$FULL_REF' '$R1' '$R2' 2> '$BUILD_DIR/${sample}.bwamem2.log' \
        | samtools sort -@ 2 -m 1G -T '$BUILD_DIR/${sample}.tmp' -o '$BUILD_DIR/${sample}.sorted.bam' -
        samtools index '$BUILD_DIR/${sample}.sorted.bam'
        samtools flagstat '$BUILD_DIR/${sample}.sorted.bam' > '$BUILD_DIR/${sample}.sorted.flagstat.txt'
        samtools view -b -h -f 1 -F 12 '$BUILD_DIR/${sample}.sorted.bam' ${CHROMS[*]} > '$region.tmp'
        mv '$region.tmp' '$region'
        samtools index '$region'
        rm -f '$BUILD_DIR/${sample}.sorted.bam' '$BUILD_DIR/${sample}.sorted.bam.bai'"
done

# Depth of what was kept, per contig. Read by a person choosing the fractions; `samtools coverage`
# counts primary records only, and nothing is duplicate-marked at this point.
for sample in "${SAMPLE_ORDER[@]}"; do
    dk "samtools coverage '$BUILD_DIR/${sample}.region.bam' > '$BUILD_DIR/${sample}.region.coverage.tsv'"
    echo "  $sample, mean depth of the kept reads before subsampling:"
    awk -F'\t' -v keep="${CHROMS[*]}" 'BEGIN{n=split(keep,k," "); for(i=1;i<=n;i++) want[k[i]]=1}
         NR>1 && ($1 in want) {printf "    %-5s %8.1fx\n", $1, $7; if ($1!="Mito") {b+=$7*$3; l+=$3}}
         END {printf "    nuclear (I, IV, VII, XV) %.1fx\n", b/l}' "$BUILD_DIR/${sample}.region.coverage.tsv"
done
echo ""

if [[ "$MODE" == "align-only" ]]; then
    echo "Stopped after the alignment (--align-only). Fraction for a target depth = target / nuclear depth."
    exit 0
fi

# ---------- Step 2: subset the reference ----------

echo "=== Step 2: reference subset ==="
mkdir -p "$OUT_REF/chromosomes"

dk "samtools faidx '$FULL_REF' ${CHROMS[*]} > '$OUT_REF/S288C_R64_test.fa'
    samtools faidx '$OUT_REF/S288C_R64_test.fa'
    samtools dict -u S288C_R64_test.fa '$OUT_REF/S288C_R64_test.fa' > '$OUT_REF/S288C_R64_test.dict'"
echo "  FASTA: $(wc -l < "$OUT_REF/S288C_R64_test.fa.fai") contigs"

for chr in "${CHROMS[@]}"; do
    cp "$FULL_CHR_DIR/${chr}.fa" "$OUT_REF/chromosomes/"
done
echo "  chromosomes/: ${#CHROMS[@]} files"

# GenBank records of the five contigs, in the order of CHROMS. Records end with '//' alone on a
# line; the file also holds URLs with '//', so split on the whole line.
python - "$FULL_GB" "$OUT_REF/S288C_R64_test.gb" "${CHROMS[@]}" <<'PY'
import re, sys
gb_path, out_path, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(gb_path) as f:
    records = re.split(r'\n//\n', f.read())
by_locus = {}
for rec in records:
    body = rec.strip()
    if body.startswith('LOCUS'):
        by_locus[body.split()[1]] = rec.rstrip()
missing = [c for c in wanted if c not in by_locus]
if missing:
    sys.exit(f"ERROR: no GenBank record with LOCUS {missing} in {gb_path}")
with open(out_path, 'w') as f:
    for c in wanted:
        f.write(by_locus[c].lstrip('\n'))
        f.write('\n//\n')
print(f"  GenBank: {len(wanted)} records: {wanted}")
PY

# The pre-built snpEff database is the full genome's (17 contigs), copied whole: a database may
# hold more contigs than the FASTA, never fewer.
rm -rf "$OUT_REF/snpeff_cache"
mkdir -p "$OUT_REF/snpeff_cache"
cp -r "$FULL_SNPEFF/R64-1-1.105" "$OUT_REF/snpeff_cache/"
[[ -f "$FULL_SNPEFF/snpEff.config" ]] && cp "$FULL_SNPEFF/snpEff.config" "$OUT_REF/snpeff_cache/"
grep -q 'Mito.codonTable' "$OUT_REF/snpeff_cache/R64-1-1.105/snpEff.config" || {
    echo "ERROR: the full reference's snpEff database has no Mito codonTable line in its snpEff.config." >&2
    echo "       Rebuild it (docs/prepare_input/build_snpeff_cache.sh with CODON_TABLES=Mito=Yeast_Mitochondrial)." >&2
    exit 1; }
echo "  snpEff database copied (Mito codon table line present)."
echo ""

# ---------- Step 3: the seeded cut ----------

echo "=== Step 3: subsample pairs and write FASTQ ==="
mkdir -p "$OUT_FASTQ"
rm -f "$OUT_FASTQ"/*.fastq.gz "$OUT_FASTQ"/*.fastq.gz.md5 "$OUT_FASTQ/CUT_PARAMETERS.tsv"

declare -A FQ1 FQ2
for sample in "${SAMPLE_ORDER[@]}"; do
    frac="${FRACTION[$sample]}"
    stem="${sample}_${CHROM_TAG}_seed${SEED}_frac${frac}"
    FQ1[$sample]="$OUT_FASTQ/${stem}_R1.fastq.gz"
    FQ2[$sample]="$OUT_FASTQ/${stem}_R2.fastq.gz"
    echo "  $sample: seed $SEED, fraction $frac"
    # `-s SEED.FRACTION`: integer part = seed, decimal part = fraction of read NAMES kept.
    dk "samtools view -b -h -s '${SEED}.${frac#0.}' '$BUILD_DIR/${sample}.region.bam' \
        | samtools sort -n -@ 2 -m 1G -T '$BUILD_DIR/${sample}.ns' - \
        | samtools fastq -1 '${FQ1[$sample]}' -2 '${FQ2[$sample]}' -0 /dev/null -s /dev/null -"
done
echo ""

# ---------- Step 4: record what was cut ----------

{
    printf 'sample\tsrr\tcontigs\tseed\tfraction\tpairs\tfastq_1\tmd5_1\tfastq_2\tmd5_2\timage\n'
    for sample in "${SAMPLE_ORDER[@]}"; do
        pairs=$(( $(zcat "${FQ1[$sample]}" | wc -l) / 4 ))
        pairs2=$(( $(zcat "${FQ2[$sample]}" | wc -l) / 4 ))
        [[ "$pairs" -eq "$pairs2" && "$pairs" -gt 0 ]] || { echo "ERROR: $sample: R1 has $pairs reads, R2 $pairs2." >&2; exit 1; }
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$sample" "${SRR[$sample]}" "${CHROMS[*]}" "$SEED" "${FRACTION[$sample]}" "$pairs" \
            "$(basename "${FQ1[$sample]}")" "$(md5sum < "${FQ1[$sample]}" | cut -d' ' -f1)" \
            "$(basename "${FQ2[$sample]}")" "$(md5sum < "${FQ2[$sample]}" | cut -d' ' -f1)" \
            "$IMAGE"
    done
} > "$OUT_FASTQ/CUT_PARAMETERS.tsv"
# A fresh cut has not been checked: the truth-gate stamp of an earlier cut must not survive it.
rm -f "$OUT_FASTQ/TRUTH_GATE.txt"

# The samplesheet for the local `ottilie_test` profile, with this machine's absolute paths (valid
# from any launch directory, nf-test's included). Never copy it between machines: rerun this
# script or download_test_data.sh. The blob samplesheets are written by the publish scripts.
SAMPLESHEET="$OUT_ROOT/samplesheet_test.csv"
{
    echo "experiment,sample,status,clonal_or_population,ploidy,sex,lane,fastq_1,fastq_2"
    for sample in "${SAMPLE_ORDER[@]}"; do
        echo "Ottilie_test,$sample,0,clonal,1,XX,L001,${FQ1[$sample]},${FQ2[$sample]}"
    done
} > "$SAMPLESHEET"

echo "============================================"
echo "Test set written"
echo "============================================"
column -t -s $'\t' < <(cut -f1,4,5,6,7 "$OUT_FASTQ/CUT_PARAMETERS.tsv")
echo ""
ls -lh "$OUT_FASTQ"/*.fastq.gz
echo ""
ls -lh "$OUT_REF/S288C_R64_test.fa" "$OUT_REF/S288C_R64_test.gb"
echo ""
echo "Samplesheet: $SAMPLESHEET"
echo "Cut record:  $OUT_FASTQ/CUT_PARAMETERS.tsv"
echo ""
echo "Next: run the pipeline on this set, then"
echo "  python $SCRIPT_DIR/check_test_data_truth.py <outdir>"
echo "which stamps the FASTQs as checked; publish_test_data.sh refuses an unstamped set."
echo "============================================"
