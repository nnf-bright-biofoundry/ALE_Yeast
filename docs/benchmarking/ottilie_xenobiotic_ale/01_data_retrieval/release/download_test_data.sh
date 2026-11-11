#!/usr/bin/env bash
# Fetch the ottilie e2e test-data from a STABLE PUBLIC Azure Blob URL (no SAS, no az login) and write the
# machine-correct samplesheet. FAST path to run the ottilie nf-test / pipeline on a fresh checkout (e.g. a
# newly deployed server) WITHOUT regenerating from SRA — that heavier reproducible path is
# generate_test_data.sh (needs the full reference, the two SRA runs and docker).
#
# Grabs the single bundle tarball (~325 MB compressed) and extracts it into data/ottilie/:
#   fastq_test/                     2 samples, reads on chr I/IV/VII/XV + Mito, a seeded 0.67 of the pairs;
#                                   CUT_PARAMETERS.tsv (the cut), TRUTH_GATE.txt (the checks it passed)
#   S288C_reference_test/           subset FASTA + .fai + .dict + .gb + snpeff_cache/ + chromosomes/
#   S288C_reference/                FULL genome — FASTA + .gb + .gff3 + snpeff_cache/ + chromosomes/
#   README.md                       what the data is: sample↔FASTQ↔SRA, truth set, reference pairing
#
# BOTH references ship, so no second download is needed to run against the full genome. The
# `ottilie_test` profile uses the slimmed one — that pairing is a SPEED choice, not a correctness
# requirement, and it is the pairing the truth set was established against.
# (The igv-reports templates/scripts under docs/igvreports/ are tracked in git, so they already travel.)
#
# The same blobs are ALSO published as an individual file/folder tree (files/**) + a cache-only tarball
# (snpeff_cache.tar.gz) for Seqera/Batch per-file staging — see samplesheet_test_blob.csv and
# DATA_PROVENANCE.md. This script uses the bundle because it is the fastest local (download-then-run) path.
#
# Requires: curl + tar. Content is public (PRJNA590203 SRA + public S288C reference) → no credentials.
# Usage (from anywhere):
#   bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/download_test_data.sh
# Host elsewhere / different version? override the base URL:
#   BLOB_BASE=https://<acct>.blob.core.windows.net/<container>/ottilie/v2  bash .../download_test_data.sh
#
# After it finishes:
#   nextflow run main.nf -profile ottilie_test,docker
#   nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
OUT="${OUT:-$REPO_ROOT/data/ottilie}"   # override to stage into an isolated dir (testing / CI)

# Stable public base URL (container + versioned prefix). No SAS token needed.
# Host provisioned by infra/azure/ (account 'aletestdatapublic', public 'releases' container).
BLOB_BASE="${BLOB_BASE:-https://aletestdatapublic.blob.core.windows.net/releases/ottilie/v2}"
TARBALL="ottilie_test_data.tar.gz"

command -v curl >/dev/null || { echo "ERROR: curl not found." >&2; exit 1; }
command -v tar  >/dev/null || { echo "ERROR: tar not found."  >&2; exit 1; }

mkdir -p "$OUT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "Fetching ottilie test data bundle from:"
echo "  $BLOB_BASE/$TARBALL"
curl -fSL "$BLOB_BASE/$TARBALL" -o "$TMP/$TARBALL"

# Optional integrity check against the published SHA256SUMS (best-effort; skipped if unreachable).
if curl -fsSL "$BLOB_BASE/SHA256SUMS" -o "$TMP/SHA256SUMS" 2>/dev/null; then
    EXPECTED="$(awk -v f="$TARBALL" '$2==f{print $1}' "$TMP/SHA256SUMS")"
    if [[ -n "$EXPECTED" ]]; then
        ACTUAL="$(sha256sum "$TMP/$TARBALL" | awk '{print $1}')"
        [[ "$EXPECTED" == "$ACTUAL" ]] && echo "  checksum OK" \
            || { echo "ERROR: $TARBALL checksum mismatch (expected $EXPECTED, got $ACTUAL)." >&2; exit 1; }
    fi
fi

echo "Extracting into $OUT ..."
tar -xzf "$TMP/$TARBALL" -C "$OUT"

# --- Write the ottilie samplesheet with machine-correct absolute LOCAL paths ---
# Identical to generate_test_data.sh's final block; derived from $OUT so it is valid on THIS machine
# (no hardcoded /home/<user>/... paths). Absolute so it resolves from any launch dir, incl. nf-test.
# For a Seqera/Batch run against blob URLs instead, use samplesheet_test_blob.csv from $BLOB_BASE.
OUT_FASTQ="$OUT/fastq_test"
SAMPLESHEET="$OUT/samplesheet_test.csv"
# The FASTQ names carry the cut's seed and fraction; they are read from the cut record in the bundle.
CUT="$OUT_FASTQ/CUT_PARAMETERS.tsv"
[[ -f "$CUT" ]] || { echo "ERROR: $CUT not in the bundle (a version 1 bundle? this script reads ottilie/v2 and later)." >&2; exit 1; }
{
    echo "experiment,sample,status,clonal_or_population,ploidy,sex,lane,fastq_1,fastq_2"
    awk -F'\t' -v fq="$OUT_FASTQ" 'NR>1 {print "Ottilie_test," $1 ",0,clonal,1,XX,L001," fq "/" $7 "," fq "/" $9}' "$CUT"
} > "$SAMPLESHEET"
( cd "$OUT_FASTQ" && md5sum -c --quiet ./*.fastq.gz.md5 ) || { echo "ERROR: a FASTQ does not match its .md5 sidecar." >&2; exit 1; }

# --- Verify the key inputs the ottilie_test profile references are present ---
echo ""
echo "Fetched:"
ls -lh "$OUT_FASTQ"/*.fastq.gz
ls -lh "$OUT/S288C_reference_test/S288C_R64_test.fa" \
       "$OUT/S288C_reference_test/S288C_R64_test.fa.fai" \
       "$OUT/S288C_reference_test/S288C_R64_test.dict" \
       "$OUT/S288C_reference/S288C_R64.gff3"
du -sh "$OUT/S288C_reference_test/snpeff_cache"
echo "Wrote samplesheet: $SAMPLESHEET"
echo ""
echo "Next:"
echo "  nextflow run main.nf -profile ottilie_test,docker"
echo "  nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test"
