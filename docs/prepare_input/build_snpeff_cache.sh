#!/usr/bin/env bash
# Build a SnpEff cache for this pipeline from a reference FASTA + GFF3 (Ensembl / NCBI style).
# Companion to process_GeneBank/process_genbank_auto.sh, which starts from a GenBank file instead.
# Docker is the only prerequisite. User page: docs/usage/prepare_reference.md
#
# Usage:
#   bash docs/prepare_input/build_snpeff_cache.sh <snpeff_db> <reference.fa> <annotation.gff3> [out_dir] [genome_description]
#
# Produces  <out_dir>/snpeff_cache/<snpeff_db>/{snpEffectPredictor.bin, sequence*.bin, snpEff.config,
#           genes.gff, sequences.fa}  (+ <out_dir>/snpeff_build_<snpeff_db>.log)
# Then run:  --fasta <reference.fa> --snpeff_cache <out_dir>/snpeff_cache --snpeff_db <snpeff_db>
#
# genome_description (default: the snpeff_db name) is the free-text `<db>.genome : <description>` entry in
# snpEff.config. It is stored inside both .bin files but does not affect annotation. The build is otherwise
# deterministic: same snpEff, same FASTA, same GFF3, same description => byte-identical cache. Give the same
# description to reproduce an existing cache exactly (the project's S288C cache uses `Saccharomyces_cerevisiae`).
#
# CODON_TABLES (environment variable, optional): the genetic code per contig, as `contig=Table[,contig=Table]`,
# e.g. CODON_TABLES=Mito=Yeast_Mitochondrial for S288C. snpEff ignores the annotation's /transl_table and keeps
# no genetic code in the .bin files: it reads `<db>.<contig>.codonTable : <Table>` from the cache's snpEff.config
# at annotation time, and translates every contig without a line with the Standard code. A yeast mitochondrial
# TGA (Trp) is then a stop, so synonymous changes at those codons come out as stop_lost (measured 2026-11-02,
# docs/dev-practices/genbank_reference_input.md §4). Table names are snpEff's (`codon.<Table>` entries of its
# bundled config; the NCBI numbers map as 3=Yeast_Mitochondrial, 4=Mold_Mitochondrial, 11=Bacterial_and_Plant_Plastid,
# 12=Alternative_Yeast_Nuclear); a name the image does not know, or a contig the FASTA does not have, stops the
# build. The .bin files do not change with this variable, only snpEff.config does, so the line can also be
# appended to an existing cache by hand. Unit test: tests/snpeff_codon_table.nf.test.
#
# Rules this encodes:
#  * snpEff version == the pipeline's module (5.1). A cache built by 5.2+ is refused at run time
#    ("Database version: '5.2', Program version: '5.1'"). Override SNPEFF_IMAGE only together with the module.
#  * Layout is FLAT: <snpeff_cache>/<snpeff_db>/snpEffectPredictor.bin — not the <db>/<db>/ form of
#    nf-core's annotation-cache bucket. `--snpeff_db` must equal the directory name.
#  * GFF3 contig names must equal the FASTA headers. snpEff annotates NOTHING, silently, on a mismatch
#    (nf-core/sarek #415) — so this script refuses to build when no name is shared, and warns on partial overlap.
#  * Ensembl GFF3s carry `gene:` / `transcript:` / `CDS:` / `chromosome:` prefixes on ID/Parent and
#    exon `Name=` / `exon_id=` attributes; both break snpEff 5.1's gene models (transcripts without start
#    codons, exons taken for genes). They are stripped here — a no-op on GFF3s that do not have them.
#  * -noCheckCds -noCheckProtein: there is no CDS/protein FASTA to check against. snpEff's own build
#    warnings are kept in the log; read them for a new genome.
set -euo pipefail

DB="${1:?usage: build_snpeff_cache.sh <snpeff_db> <reference.fa> <annotation.gff3> [out_dir] [genome_description]}"
FASTA="${2:?reference FASTA missing}"
GFF="${3:?GFF3 missing}"
OUT="${4:-$PWD}"
DESC="${5:-$DB}"
IMG="${SNPEFF_IMAGE:-quay.io/biocontainers/snpeff:5.1--hdfd78af_2}"

command -v docker >/dev/null || { echo "ERROR: docker not found." >&2; exit 1; }
[[ -f "$FASTA" ]] || { echo "ERROR: FASTA not found: $FASTA" >&2; exit 1; }
[[ -f "$GFF"   ]] || { echo "ERROR: GFF3 not found: $GFF" >&2; exit 1; }

CACHE="$OUT/snpeff_cache"
DBDIR="$CACHE/$DB"
LOG="$OUT/snpeff_build_${DB}.log"
mkdir -p "$DBDIR"

# --- chromosome-name check (the classic silent failure) ---
fa_chr=$(grep '^>' "$FASTA" | sed 's/^>//; s/[[:space:]].*//' | sort -u)
gff_chr=$(grep -v '^#' "$GFF" | cut -f1 | sort -u)
shared=$(comm -12 <(printf '%s\n' "$fa_chr") <(printf '%s\n' "$gff_chr") | wc -l)
gff_only=$(comm -13 <(printf '%s\n' "$fa_chr") <(printf '%s\n' "$gff_chr") | wc -l)
if [[ "$shared" -eq 0 ]]; then
    echo "ERROR: no contig name is shared between the FASTA and the GFF3 — snpEff would build a cache that annotates nothing." >&2
    echo "  FASTA: $(printf '%s ' $fa_chr | cut -c1-120)" >&2
    echo "  GFF3 : $(printf '%s ' $gff_chr | cut -c1-120)" >&2
    exit 1
fi
[[ "$gff_only" -gt 0 ]] && echo "WARNING: $gff_only GFF3 contig(s) have no FASTA sequence; their features are dropped by snpEff." >&2
echo "Contigs shared by FASTA and GFF3: $shared"

# --- genetic code per contig (CODON_TABLES=contig=Table,...): validated now, written after the build ---
codon_lines=()
if [[ -n "${CODON_TABLES:-}" ]]; then
    known=$(docker run --rm "$IMG" sh -c 'grep -oE "^codon\.[A-Za-z_]+" "$(find / -name snpEff.config -path "*share/snpeff*" 2>/dev/null | head -1)" | cut -d. -f2')
    IFS=',' read -ra entries <<< "$CODON_TABLES"
    for entry in "${entries[@]}"; do
        contig="${entry%%=*}"; table="${entry#*=}"
        [[ "$entry" == *=* && -n "$contig" && -n "$table" ]] || { echo "ERROR: CODON_TABLES entry '$entry' is not contig=Table." >&2; exit 1; }
        grep -qxF "$contig" <<< "$fa_chr" || { echo "ERROR: CODON_TABLES names contig '$contig', which the FASTA does not have." >&2; exit 1; }
        grep -qxF "$table" <<< "$known" || { echo "ERROR: snpEff $IMG has no codon table '$table'. Known: $(tr '\n' ' ' <<< "$known")" >&2; exit 1; }
        codon_lines+=("$DB.$contig.codonTable : $table")
    done
fi

# --- inputs in snpEff's expected names, with the Ensembl clean-up ---
sed '
  /\texon\t/s/;Name=[^;]*//
  /\texon\t/s/;exon_id=[^;]*//
  s/ID=gene:/ID=/g
  s/ID=transcript:/ID=/g
  s/ID=CDS:/ID=/g
  s/ID=chromosome:/ID=/g
  s/Parent=gene:/Parent=/g
  s/Parent=transcript:/Parent=/g
' "$GFF" > "$DBDIR/genes.gff"
cp "$FASTA" "$DBDIR/sequences.fa"

# Genome entry only — no data.dir, so no host path is baked in (the pipeline passes -dataDir itself).
printf '%s.genome : %s\n' "$DB" "$DESC" > "$CACHE/snpEff.config"

cp "$CACHE/snpEff.config" "$DBDIR/snpEff.config"

# --- build ---
echo "Building $DB with $IMG (log: $LOG) ..."
docker run --rm -v "$(cd "$CACHE" && pwd)":/data/cache "$IMG" \
    snpEff build -gff3 -noCheckCds -noCheckProtein -dataDir /data/cache -c /data/cache/snpEff.config "$DB" \
    > "$LOG" 2>&1 || true
[[ -f "$DBDIR/snpEffectPredictor.bin" ]] || { echo "ERROR: build produced no snpEffectPredictor.bin — see $LOG" >&2; tail -20 "$LOG" >&2; exit 1; }

# The codonTable lines go into the cache's config only now: during the build `-c` names a *replacement*
# config, and a codonTable line there makes snpEff demand the `codon.<Table>` definitions in the same file
# ("No such codon table"). At annotation time the bundled config is primary and has them, and the .bin files
# never depend on the line (the protein check is off here), so a build with CODON_TABLES gives the same bins
# as one without (verified 2026-11-02 on R64-1-1.105: all four files identical to the project's cache).
for line in "${codon_lines[@]}"; do
    printf '%s\n' "$line" | tee -a "$CACHE/snpEff.config" >> "$DBDIR/snpEff.config"
    echo "Genetic code: ${line#$DB.}"
done

n_warn=$(grep -c "WARNING" "$LOG" || true)
echo "Built: $DBDIR/snpEffectPredictor.bin  ($(du -sh "$DBDIR" | cut -f1); snpEff build warnings: $n_warn — see $LOG)"
echo
echo "Pipeline parameters:"
echo "  --fasta        $FASTA"
echo "  --snpeff_cache $CACHE"
echo "  --snpeff_db    $DB"
