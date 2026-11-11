#!/usr/bin/env bash
# Stage the FULL-DEPTH ottilie pilot (4 samples, all chromosomes) to the PRIVATE aletest container,
# for Azure Batch / Seqera runs — benchmarking and the cold-pool disk measurement.
#
#   1. fastq_pilot_full/**        8 FASTQs, renamed <sample>_<SRA>_allchr_R{1,2}.fastq.gz
#   2. S288C_reference/**         full-genome fasta, genbank, snpeff_cache, chromosomes
#   3. samplesheet_pilot_az.csv   samplesheet with az:// paths (local one holds absolute local paths)
#
# ⚠️ THIS IS NOT publish_test_data.sh, AND THE TARGET IS NOT THE PUBLIC ACCOUNT.
#
#   publish_test_data.sh → aletestdatapublic/releases   PUBLIC, no SAS. 2-sample chr-subset TEST set.
#   this script          → aledata/aletest              PRIVATE. 4-sample full-depth PILOT set.
#
# Both sets are public-SRA-derived (PRJNA590203), so neither is sensitive — but the accounts have
# different purposes and must not be conflated. The public account exists so a fresh machine can
# fetch the release test set with no credentials; nothing else belongs there. Phase 0 refuses to
# run against it. See DATA_PROVENANCE.md and blob_layout.md.
#
# ⚠️ WHY THE FILES ARE RENAMED. The test set already self-describes in its own filenames
# (`NODRUG-GM2_chrI_IV_VII_XV_R1.fastq.gz`). Bare SRA accessions (`SRR10985539_1.fastq.gz`) say
# nothing about sample, depth or chromosome coverage — the one naming that could sit beside the
# test files without looking wrong. Sample first for readability, accession kept for provenance,
# `_allchr` so a stray file is never mistaken for a subset one.
#
# ⚠️ workDir MUST be in this same container when the run uses the Entra service principal —
# Nextflow mints ONE container-scoped SAS and reuses it for every blob URL. See
# docs/dev-practices/azure_batch_execution.md §3.
#
# Requires: az CLI (`az login`) with a Storage Blob Data role on the account, and a populated
# data/ottilie/ (fastq/ + S288C_reference/).
#
# Usage (from anywhere):
#   bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/upload_pilot_data.sh
#   DRY_RUN=1 bash .../upload_pilot_data.sh        # print what would upload, touch nothing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
SRC="$REPO_ROOT/data/ottilie"

ACCOUNT="${ACCOUNT:-aledata}"
CONTAINER="${CONTAINER:-aletest}"
PREFIX="${PREFIX:-ottilie/v2}"
[[ "$PREFIX" != "ottilie/v1" ]] || {
    echo "ERROR: ottilie/v1 is frozen (the v1.1.0 tag and its Launchpad version read it). Use ottilie/v2 or later." >&2
    exit 1; }
AUTH="${AUTH:-login}"
DRY_RUN="${DRY_RUN:-}"

# sample:SRA accession — the pilot's 4 samples (data/ottilie/samplesheet_pilot.csv)
PAIRS=(
    NODRUG-GM2:SRR10985539            # parent, no drug
    Doxorubicin16-R2b:SRR10985527
    Carmaphycin-R9-2:SRR10985678
    CBR110-15-R3a:SRR10985585
)

# Reference files the pilot params actually consume. Deliberately NOT the bwa-mem2 indices
# (.0123/.bwt.2bit.64/.amb/.ann/.pac) or .fai/.dict: the validated cloud run does not pass them as
# params, so Sarek builds them in-run. Uploading them changes nothing unless they are also passed,
# and passing them would alter the task graph and break comparability with that run.
REF_FILES=(S288C_R64.fa S288C_R64_ensembl_chrnames.gb)
REF_DIRS=(snpeff_cache chromosomes)

run() { if [[ -n "$DRY_RUN" ]]; then echo "  DRY-RUN: $*"; else "$@"; fi; }

# ---------------------------------------------------------------------------
# Phase 0 — preflight: tools, target, and the public-account guard
# ---------------------------------------------------------------------------
command -v az >/dev/null || { echo "ERROR: az CLI not found (az login required)." >&2; exit 1; }

# The guard that matters. Fail loudly rather than publish a 4 GB dataset world-readable.
if [[ "$ACCOUNT" == "aletestdatapublic" || "$CONTAINER" == "releases" ]]; then
    echo "ERROR: refusing to run against the PUBLIC account/container ($ACCOUNT/$CONTAINER)." >&2
    echo "       The pilot set is staged privately. Publishing the release test set is a" >&2
    echo "       different job with a different script: publish_test_data.sh" >&2
    exit 2
fi
PUBLIC="$(az storage container show --account-name "$ACCOUNT" --name "$CONTAINER" \
    --auth-mode "$AUTH" --query "properties.publicAccess" -o tsv 2>/dev/null || echo error)"
if [[ "$PUBLIC" != "None" && "$PUBLIC" != "" ]]; then
    echo "ERROR: container '$CONTAINER' has publicAccess='$PUBLIC' — expected none." >&2
    echo "       Refusing to upload; this dataset is staged privately by design." >&2
    exit 2
fi

for pair in "${PAIRS[@]}"; do
    for r in 1 2; do
        f="$SRC/fastq/${pair##*:}_${r}.fastq.gz"
        [[ -f "$f" ]] || { echo "ERROR: missing $f — run ../fastq/download_pilot_fastq.sh first." >&2; exit 1; }
    done
done
for f in "${REF_FILES[@]}"; do
    [[ -f "$SRC/S288C_reference/$f" ]] || { echo "ERROR: missing S288C_reference/$f" >&2; exit 1; }
done
for d in "${REF_DIRS[@]}"; do
    [[ -d "$SRC/S288C_reference/$d" ]] || { echo "ERROR: missing S288C_reference/$d/" >&2; exit 1; }
done

echo "Target: az://$CONTAINER/$PREFIX  (account $ACCOUNT, publicAccess=${PUBLIC:-none})"

# ---------------------------------------------------------------------------
# Phase 1 — FASTQs, renamed sample-first
# ---------------------------------------------------------------------------
echo "Uploading 8 pilot FASTQs → $PREFIX/fastq_pilot_full/ ..."
for pair in "${PAIRS[@]}"; do
    sample="${pair%%:*}"; srr="${pair##*:}"
    for r in 1 2; do
        src="$SRC/fastq/${srr}_${r}.fastq.gz"
        dst="$PREFIX/fastq_pilot_full/${sample}_${srr}_allchr_R${r}.fastq.gz"
        echo "  ${srr}_${r}.fastq.gz -> ${dst##*/}"
        run az storage blob upload --account-name "$ACCOUNT" --auth-mode "$AUTH" --overwrite \
            --container-name "$CONTAINER" --name "$dst" --file "$src" -o none
    done
done

# ---------------------------------------------------------------------------
# Phase 2 — full-genome reference (the gff3 is already published there)
# ---------------------------------------------------------------------------
echo "Uploading full reference → $PREFIX/S288C_reference/ ..."
for f in "${REF_FILES[@]}"; do
    echo "  $f"
    run az storage blob upload --account-name "$ACCOUNT" --auth-mode "$AUTH" --overwrite \
        --container-name "$CONTAINER" --name "$PREFIX/S288C_reference/$f" \
        --file "$SRC/S288C_reference/$f" -o none
done
for d in "${REF_DIRS[@]}"; do
    echo "  $d/"
    run az storage blob upload-batch --account-name "$ACCOUNT" --auth-mode "$AUTH" --overwrite \
        --destination "$CONTAINER" --destination-path "$PREFIX/S288C_reference/$d" \
        --source "$SRC/S288C_reference/$d" -o none
done

# ---------------------------------------------------------------------------
# Phase 3 — az:// samplesheet (the local pilot sheet holds absolute local paths)
# ---------------------------------------------------------------------------
echo "Writing $PREFIX/samplesheet_pilot_az.csv ..."
TMP_CSV="$(mktemp --suffix=.csv)"; trap 'rm -f "$TMP_CSV"' EXIT
FQ="az://$CONTAINER/$PREFIX/fastq_pilot_full"
{
    echo "experiment,sample,status,clonal_or_population,ploidy,sex,lane,fastq_1,fastq_2"
    for pair in "${PAIRS[@]}"; do
        sample="${pair%%:*}"; srr="${pair##*:}"
        echo "Ottilie_pilot,$sample,0,clonal,1,XX,L001,$FQ/${sample}_${srr}_allchr_R1.fastq.gz,$FQ/${sample}_${srr}_allchr_R2.fastq.gz"
    done
} > "$TMP_CSV"
run az storage blob upload --account-name "$ACCOUNT" --auth-mode "$AUTH" --overwrite \
    --container-name "$CONTAINER" --name "$PREFIX/samplesheet_pilot_az.csv" --file "$TMP_CSV" -o none

# ---------------------------------------------------------------------------
# Phase 4 — verify on CONTENT, never on exit status
# ---------------------------------------------------------------------------
# A staging check that asserts on exit code has already produced false confidence here once
# (see output_comparison.md). Compare local byte counts against what actually landed.
[[ -n "$DRY_RUN" ]] && { echo "DRY-RUN: nothing uploaded, nothing verified."; exit 0; }

echo ""
echo "Verifying uploaded sizes against local ..."
FAIL=0
for pair in "${PAIRS[@]}"; do
    sample="${pair%%:*}"; srr="${pair##*:}"
    for r in 1 2; do
        local_b=$(stat -c%s "$SRC/fastq/${srr}_${r}.fastq.gz")
        blob_b=$(az storage blob show --account-name "$ACCOUNT" --auth-mode "$AUTH" \
            -c "$CONTAINER" -n "$PREFIX/fastq_pilot_full/${sample}_${srr}_allchr_R${r}.fastq.gz" \
            --query properties.contentLength -o tsv 2>/dev/null || echo missing)
        if [[ "$local_b" == "$blob_b" ]]; then
            echo "  OK    ${sample}_${srr}_allchr_R${r}.fastq.gz  ($blob_b bytes)"
        else
            echo "  FAIL  ${sample}_${srr}_allchr_R${r}.fastq.gz  local=$local_b blob=$blob_b"; FAIL=1
        fi
    done
done

N_REF=$(az storage blob list --account-name "$ACCOUNT" --auth-mode "$AUTH" -c "$CONTAINER" \
    --prefix "$PREFIX/S288C_reference/" --query "length(@)" -o tsv)
echo "  info  $PREFIX/S288C_reference/ now holds $N_REF blobs"

if (( FAIL )); then
    echo ""
    echo "🚨 VERIFICATION FAILED — do not launch against this data." >&2
    exit 1
fi

cat <<EOF

Staged under: az://$CONTAINER/$PREFIX
  fastq_pilot_full/**        4 samples x 2 reads, full depth, all chromosomes
  S288C_reference/**         full-genome fasta + genbank + snpeff_cache + chromosomes
  samplesheet_pilot_az.csv   az:// samplesheet for Seqera / Azure Batch

Layout + how to tell the two ottilie datasets apart: ../../blob_layout.md
EOF
