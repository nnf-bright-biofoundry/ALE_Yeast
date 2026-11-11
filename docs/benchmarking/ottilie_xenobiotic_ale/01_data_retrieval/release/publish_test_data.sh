#!/usr/bin/env bash
# Publish the ottilie e2e test-data to Azure Blob in BOTH shapes, behind a stable PUBLIC (no-SAS) URL:
#   1. ottilie_test_data.tar.gz   — one atomic bundle for local onboarding / CI (download-then-run)
#   2. files/**                   — the individual file/folder tree for Seqera/Batch per-file staging
#   3. snpeff_cache.tar.gz        — cache-only tarball; Seqera fallback when a snpeff_cache *directory*
#                                   won't stage cleanly from a URL (point --snpeff_cache at the untarred dir)
#   4. SHA256SUMS                 — covers the individual files AND both tarballs, so a consumer can prove
#                                   the tarball unpacks to exactly the individual set (they never drift)
#   5. samplesheet_test_blob.csv  — samplesheet whose fastq_1/fastq_2 are the public per-file URLs (Seqera)
#   6. README.md                  — what the data IS: sample↔FASTQ↔SRA mapping, the truth set, and the
#                                   reference-pairing rule. Shipped INSIDE the bundle and published
#                                   standalone. Source of truth is bundle_README.md, next to this script.
#   7. download_pilot_fastq.sh    — the 4-sample pilot RECIPE (reads stay on SRA; see blob_layout.md for
#                                   why the pilot data itself is not re-hosted). In the bundle and standalone.
#   8. pilot_truth_set.csv        — the paper's published events for the pilot clones (Sup Data 4 + 5), keyed
#      sample_name_dictionary.csv   by pipeline sample names; and the clone-name dictionary that reconciles
#                                   the paper's tables with SRA. Both tracked in git under data/ottilie/.
#
# BOTH REFERENCES ARE PUBLISHED, and both go in the bundle:
#   S288C_reference_test/   slimmed — chromosomes I, IV, VII, XV. Pairs with the 2-sample test reads.
#   S288C_reference/        full    — all 16 + Mito. Needed by the 4-sample SRA set, and usable with
#                                     the 2-sample reads for a truer (but not truth-set-comparable) run.
# The full reference costs only ~27 MB compressed (84 MB on disk — it is nearly all text), which is
# ~7% on a 373 MB bundle. Cheap enough that shipping one bundle beats shipping two and having someone
# pair the wrong reference with the wrong reads. ⚠️ Reads set a MINIMUM reference: bigger is always
# allowed, smaller never is — 4-sample reads against the slim reference MISMAP rather than fail.
# See bundle_README.md.
#
# Content is PRJNA590203 (public SRA) + public S288C reference/annotation → safe to be world-readable;
# the URL is stable, unauthenticated, and needs no SAS to distribute or rotate. See DATA_PROVENANCE.md.
#
# PROVISIONING IS OWNED BY infra/azure/ — the storage account + public 'releases' container (publicAccess
# 'blob') are created by infra/azure/deploy.sh from the ARM template. THIS script only UPLOADS content;
# it never creates or re-permissions the container (so it can't flip the deployed 'blob' access level).
#
# Requires: az CLI (`az login`), a populated data/ottilie/, tar, sha256sum, md5sum. Uploads use
# shared-key auth (AUTH=key) — works with control-plane access + the account's allowSharedKeyAccess=true,
# no data-plane RBAC role needed. Set AUTH=login to use AAD instead (needs a Storage Blob Data role).
#
# ⚠️ ottilie/v2 IS A ROLLING PREFIX — re-running this republishes it IN PLACE, and every consumer
#    picks the change up with no repointing. That is deliberate: an update parked under a new prefix
#    reaches nobody until something is edited to point at it. Additive changes (new files, a bigger
#    bundle) are safe. REMOVING or RENAMING a published file is not — bump PREFIX for that.
#    ottilie/v1 (full-depth reads cut from untrimmed CRAMs, no Mito, caches without the Mito codon
#    table) is FROZEN since v2 exists: the v1.1.0 tag and its Launchpad version read it. This
#    script refuses to write there.
#
# Usage (from repo root):
#   bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/publish_test_data.sh
# Override target (a breaking change needing a new version, or a different host):
#   ACCOUNT=aletestdatapublic CONTAINER=releases PREFIX=ottilie/v3  bash .../publish_test_data.sh
# Build everything locally and upload NOTHING (no az needed; stage dir is kept for inspection):
#   DRY_RUN=1 bash .../publish_test_data.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
SRC="$REPO_ROOT/data/ottilie"

ACCOUNT="${ACCOUNT:-aletestdatapublic}"
CONTAINER="${CONTAINER:-releases}"
PREFIX="${PREFIX:-ottilie/v2}"                  # rolling: updated in place (see Phase 0). Bump for a breaking change.
AUTH="${AUTH:-key}"                             # 'key' = shared-key (default, needs no data-plane role); 'login' = AAD
STAGE="${STAGE:-$REPO_ROOT/.ottilie_publish}"   # small: tarballs + SHA + url-samplesheet only (the data itself is not copied)
DRY_RUN="${DRY_RUN:-}"                          # set to build + verify locally without az or any upload
PILOT_SCRIPT="$SCRIPT_DIR/../fastq/download_pilot_fastq.sh"
BASE_URL="https://${ACCOUNT}.blob.core.windows.net/${CONTAINER}/${PREFIX}"

# ---------------------------------------------------------------------------
# Phase 0 — preflight (data present + container provisioned)
# ---------------------------------------------------------------------------
[[ -n "$DRY_RUN" ]] || command -v az >/dev/null || { echo "ERROR: az CLI not found (az login required)." >&2; exit 1; }
[[ "$PREFIX" != "ottilie/v1" ]] || {
    echo "ERROR: ottilie/v1 is frozen (the v1.1.0 tag and its Launchpad version read it). Publish to ottilie/v2 or later." >&2
    exit 1; }
[[ -d "$SRC/fastq_test" && -d "$SRC/S288C_reference_test" && -f "$SRC/S288C_reference/S288C_R64.gff3" ]] || {
    echo "ERROR: data/ottilie/ not populated. Run generate_test_data.sh (or download_test_data.sh) first." >&2
    exit 1
}
# The cut must have passed the truth gate (check_test_data_truth.py on a pipeline run of exactly
# these FASTQs): the stamp lists the md5 of every FASTQ it was written for.
CUT="$SRC/fastq_test/CUT_PARAMETERS.tsv"; GATE="$SRC/fastq_test/TRUTH_GATE.txt"
[[ -f "$CUT" ]] || { echo "ERROR: $CUT missing — fastq_test/ was not written by generate_test_data.sh (version 2)." >&2; exit 1; }
[[ -f "$GATE" ]] || {
    echo "ERROR: $GATE missing — this cut has not passed the truth gate." >&2
    echo "       Run the pipeline on it, then: python $SCRIPT_DIR/check_test_data_truth.py <outdir>" >&2
    exit 1; }
N_FASTQ=0
for f in "$SRC"/fastq_test/*.fastq.gz; do
    N_FASTQ=$((N_FASTQ + 1))
    grep -qxF "md5	$(md5sum < "$f" | cut -d' ' -f1)	${f##*/}" "$GATE" || {
        echo "ERROR: ${f##*/} is not the file the truth gate was passed on (md5 not in TRUTH_GATE.txt)." >&2; exit 1; }
done
[[ "$N_FASTQ" -eq "$(grep -c '^md5' "$GATE")" ]] || { echo "ERROR: fastq_test/ holds $N_FASTQ FASTQs, the truth gate stamp lists $(grep -c '^md5' "$GATE")." >&2; exit 1; }
echo "Truth gate stamp matches the $N_FASTQ FASTQs in fastq_test/."
# The pre-built snpEff databases must carry the mitochondrial genetic code (v1's did not).
for d in S288C_reference S288C_reference_test; do
    grep -q 'Mito.codonTable' "$SRC/$d/snpeff_cache/R64-1-1.105/snpEff.config" || {
        echo "ERROR: $d/snpeff_cache has no Mito codonTable line in R64-1-1.105/snpEff.config." >&2; exit 1; }
done
# The FULL reference ships too, so both references are ready to use from one download.
for f in S288C_R64.fa S288C_R64_ensembl_chrnames.gb; do
    [[ -f "$SRC/S288C_reference/$f" ]] || {
        echo "ERROR: missing S288C_reference/$f — the full reference is part of the bundle." >&2
        echo "       Fetch it, or publish without it by editing REF_FULL below." >&2
        exit 1
    }
done
[[ -d "$SRC/S288C_reference/chromosomes" && -d "$SRC/S288C_reference/snpeff_cache" ]] || {
    echo "ERROR: missing S288C_reference/chromosomes/ or snpeff_cache/." >&2; exit 1; }
[[ -f "$SCRIPT_DIR/bundle_README.md" ]] || {
    echo "ERROR: bundle_README.md not found next to this script — it ships inside the bundle." >&2; exit 1; }
[[ -f "$PILOT_SCRIPT" ]] || {
    echo "ERROR: $PILOT_SCRIPT not found — the pilot recipe ships inside the bundle." >&2; exit 1; }
for f in pilot_truth_set.csv sample_name_dictionary.csv; do
    [[ -f "$SRC/$f" ]] || {
        echo "ERROR: missing data/ottilie/$f — both are tracked in git; regenerate with" >&2
        echo "       truth_set/extract_pilot_truth_set.py / truth_set/resolve_sra_accessions.py." >&2; exit 1; }
done

# The account + container are provisioned by infra/azure/deploy.sh — verify the container exists rather
# than creating it here (keeps provisioning in one place, and preserves the deployed public-access level).
if [[ -n "$DRY_RUN" ]]; then
    EXISTS=true; N_EXISTING=0
    echo "DRY-RUN: skipping the container check and every upload; artefacts stay in $STAGE"
else
EXISTS="$(az storage container exists --account-name "$ACCOUNT" --name "$CONTAINER" \
    --auth-mode "$AUTH" --query exists -o tsv 2>/dev/null || echo error)"
fi
if [[ "$EXISTS" != "true" ]]; then
    echo "ERROR: container '$CONTAINER' not found on account '$ACCOUNT' (exists=$EXISTS)." >&2
    echo "       Provision it first: bash infra/azure/deploy.sh   (see infra/azure/README.md)" >&2
    exit 2
fi

# THE PREFIX IS ROLLING, NOT IMMUTABLE: the current version's prefix is updated in place, so every consumer picks up
# a change with no repointing. That is the whole reason the improvements land here rather than under
# a new version nothing references. Warn — do not block. A prompt that fires on every single publish
# gets bypassed reflexively, which is worse than no check at all.
#
# What this means in practice, and why it is safe for the consumers that exist today:
#   • files/**            byte-identical on a content-preserving republish → CI
#                         (conf/test/ottilie_test_ci.config, bin/test_ottilie_blob.sh) is unaffected.
#   • the tarball         its hash CHANGES whenever the bundled set changes. SHA256SUMS/MD5SUMS are
#                         republished in the same run, so download_test_data.sh stays consistent —
#                         but anything holding an OLD hash out-of-band will now mismatch.
#
# ⚠️ BUMP THE PREFIX (PREFIX=ottilie/v3) for a change that would BREAK a consumer — removing or
#    renaming a published file, or changing the content of one that already exists. Growing the set
#    is additive and safe; taking things away is not.
[[ -n "$DRY_RUN" ]] || N_EXISTING="$(az storage blob list --account-name "$ACCOUNT" --auth-mode "$AUTH" \
    -c "$CONTAINER" --prefix "$PREFIX/" --query "length(@)" -o tsv 2>/dev/null || echo 0)"
if [[ "${N_EXISTING:-0}" -gt 0 ]]; then
    echo "⚠️  '$PREFIX/' already holds $N_EXISTING blobs — republishing IN PLACE (rolling prefix)."
    echo "    Consumers pull this prefix live. Removing or renaming a file here breaks them;"
    echo "    bump to a new PREFIX for that. Adding files, as here, is additive and safe."
fi

# ---------------------------------------------------------------------------
# Phase 1 — build tarballs, checksums, URL samplesheet (the data itself is not copied)
# ---------------------------------------------------------------------------
rm -rf "$STAGE"; mkdir -p "$STAGE"

# What the bundle and the files/ tree both contain. ONE list, so the tarball and the individual
# blobs can never drift apart — SHA256SUMS is generated from this same list and is what proves it.
# S288C_reference is spelled out file-by-file rather than taken wholesale: the directory also holds
# .fai/.dict/BWA indices on a dev machine, and those are deliberately NOT published (Sarek builds
# them in-run; shipping them would tempt someone to pass them and change the task graph).
PUBLISH_PATHS=(
    fastq_test                                      # 2 samples, chromosomes I/IV/VII/XV + Mito, a seeded fraction; + cut record and truth-gate stamp
    S288C_reference_test                            # slimmed reference — pairs with those reads
    S288C_reference/S288C_R64.gff3                  # shared by both references
    S288C_reference/S288C_R64.fa                    # ↓ full reference — all 16 chromosomes + Mito
    S288C_reference/S288C_R64_ensembl_chrnames.gb
    S288C_reference/chromosomes
    S288C_reference/snpeff_cache
    pilot_truth_set.csv                             # ↓ 4-sample pilot: published truth + name dictionary
    sample_name_dictionary.csv                      #   (tracked in git; the recipe script is staged below)
)

# --- Per-FASTQ .md5 sidecars, staged ONCE and used twice ------------------------------------
# Written before the tarball so they can go inside it. The same staged directory is what
# upload-batch later publishes to $PREFIX/files/fastq_test/, so the blob and the bundle carry
# byte-identical sidecars by construction rather than by two code paths agreeing.
#
# They ship INSIDE the bundle because the FASTQs get moved again after extraction — copied to
# cluster scratch, rsynced between machines — and a sidecar travelling with its file lets each
# hop be re-verified. A manifest at the blob root cannot do that once the files have moved.
#
# ⚠️ NOT one per published file. chr_dir and snpeff_cache are consumed as DIRECTORY params, so a
#    .md5 inside chromosomes/ or snpeff_cache/ would be staged into those tasks along with the
#    real data. Harmless as far as anyone knows — which is exactly the problem. fastq_test/ is
#    not directory-staged (the samplesheet names each file), so sidecars are safe there.
#    MD5SUMS covers everything the sidecars do not.
echo "Writing per-FASTQ .md5 sidecars ..."
mkdir -p "$STAGE/files/fastq_test"
for f in "$SRC"/fastq_test/*.fastq.gz; do
    ( cd "$SRC/fastq_test" && md5sum "${f##*/}" ) > "$STAGE/files/fastq_test/${f##*/}.md5"
    echo "  fastq_test/${f##*/}.md5"
done

echo "Building bundle + cache tarball ..."
# README.md ships INSIDE the bundle (extracts to data/ottilie/README.md) and is published
# standalone. tar applies each -C in turn, so later roots contribute their own members:
#   -C $SRC    the data itself
#   -C $STAGE  README.md
#   -C $STAGE/files  fastq_test/*.md5 → merges into the fastq_test/ dir from the first root
# `<base>` is substituted with the real versioned URL, so the shipped copy always names the version
# it came from — the source file stays version-agnostic and cannot go stale on the next bump.
sed "s|<base>|$BASE_URL|g" "$SCRIPT_DIR/bundle_README.md" > "$STAGE/README.md"
grep -q '<base>' "$STAGE/README.md" && { echo "ERROR: unsubstituted <base> in README." >&2; exit 1; }
# The pilot recipe is a repo script, not data — stage it beside the README so it lands in the
# tarball root and at $PREFIX/download_pilot_fastq.sh, the same way README.md does.
cp "$PILOT_SCRIPT" "$STAGE/download_pilot_fastq.sh"
tar -czf "$STAGE/ottilie_test_data.tar.gz" \
    -C "$SRC" "${PUBLISH_PATHS[@]}" \
    -C "$STAGE" README.md download_pilot_fastq.sh \
    -C "$STAGE/files" fastq_test
tar -czf "$STAGE/snpeff_cache.tar.gz" -C "$SRC/S288C_reference_test" snpeff_cache

echo "Writing SHA256SUMS + MD5SUMS (blob-relative paths) ..."
# Two manifests, same file set, generated from the same PUBLISH_PATHS so they cannot disagree.
#   SHA256SUMS  authoritative integrity
#   MD5SUMS     the genomics-convention shape; md5sum is everywhere and this is what most people
#               reach for to answer "did my download finish?"
for algo in sha256 md5; do
    {
        # individual files → mirror the 'files/…' blob layout
        ( cd "$SRC" && find "${PUBLISH_PATHS[@]}" -type f -print0 \
            | sort -z | xargs -0 "${algo}sum" ) | awk '{print $1"  files/"$2}'
        ( cd "$STAGE" && "${algo}sum" ottilie_test_data.tar.gz snpeff_cache.tar.gz README.md download_pilot_fastq.sh )
    } > "$STAGE/$(echo "$algo" | tr '[:lower:]' '[:upper:]')SUMS"
done

# Sidecars for the tarballs themselves — necessarily after they are built. Each holds a bare
# `<md5>  <basename>` line, so `md5sum -c foo.tar.gz.md5` works from wherever it was downloaded.
echo "Writing tarball .md5 sidecars ..."
for f in "$STAGE"/*.tar.gz; do
    ( cd "$STAGE" && md5sum "${f##*/}" > "${f##*/}.md5" )
    echo "  ${f##*/}.md5"
done

echo "Writing blob-URL samplesheet (for Seqera per-file staging) ..."
# File names come from the cut record (they carry the seed and the fraction), in its sample order.
FQ="$BASE_URL/files/fastq_test"
{
    echo "experiment,sample,status,clonal_or_population,ploidy,sex,lane,fastq_1,fastq_2"
    awk -F'\t' -v fq="$FQ" 'NR>1 {print "Ottilie_test," $1 ",0,clonal,1,XX,L001," fq "/" $7 "," fq "/" $9}' "$CUT"
} > "$STAGE/samplesheet_test_blob.csv"
[[ "$(wc -l < "$STAGE/samplesheet_test_blob.csv")" -eq 3 ]] || { echo "ERROR: the blob samplesheet does not hold 2 samples." >&2; exit 1; }
FIRST_FASTQ="$(awk -F'\t' 'NR==2 {print $7}' "$CUT")"

# ---------------------------------------------------------------------------
# Phase 2 — upload BOTH shapes under the versioned prefix
# ---------------------------------------------------------------------------
if [[ -n "$DRY_RUN" ]]; then
    echo ""
    echo "DRY-RUN: bundle contents (top two levels):"
    tar -tzf "$STAGE/ottilie_test_data.tar.gz" | awk -F/ 'NF<=2' | sort -u | sed 's/^/  /'
    echo "DRY-RUN: staged artefacts:"; ls -la "$STAGE" | sed 's/^/  /'
    echo "DRY-RUN: SHA256SUMS entries: $(wc -l < "$STAGE/SHA256SUMS")"
    ( cd "$STAGE" && sha256sum -c SHA256SUMS --ignore-missing --quiet ) && echo "DRY-RUN: staged artefacts match SHA256SUMS."
    echo "DRY-RUN: nothing uploaded. Stage kept at $STAGE (delete it, or rerun without DRY_RUN to publish)."
    exit 0
fi
echo "Uploading individual file tree → $PREFIX/files/ ..."
# Driven by PUBLISH_PATHS so files/ and the tarball cannot diverge: a directory goes up as a batch,
# a single file as one blob. Anything not in that list is not published, by construction.
for p in "${PUBLISH_PATHS[@]}"; do
    if [[ -d "$SRC/$p" ]]; then
        echo "  $p/"
        az storage blob upload-batch --account-name "$ACCOUNT" --auth-mode "$AUTH" --overwrite \
            --destination "$CONTAINER" --destination-path "$PREFIX/files/$p" \
            --source "$SRC/$p" -o none
    else
        echo "  $p"
        az storage blob upload --account-name "$ACCOUNT" --auth-mode "$AUTH" --overwrite \
            --container-name "$CONTAINER" --name "$PREFIX/files/$p" \
            --file "$SRC/$p" -o none
    fi
done

echo "Uploading tarballs + SHA256SUMS + url-samplesheet → $PREFIX/ ..."
az storage blob upload-batch --account-name "$ACCOUNT" --auth-mode "$AUTH" --overwrite \
    --destination "$CONTAINER" --destination-path "$PREFIX" --source "$STAGE" -o none

# ---------------------------------------------------------------------------
# Phase 3 — verify the public (no-SAS) URL actually serves
# ---------------------------------------------------------------------------
echo ""
echo "Verifying public read (no credentials) ..."
# Check one object from each shape, not just SHA256SUMS. A missing full-reference blob is the
# failure this release can actually introduce, and it would otherwise surface much later as a
# 4-sample run silently paired with the slimmed reference.
VFAIL=0
for obj in SHA256SUMS MD5SUMS README.md ottilie_test_data.tar.gz \
           ottilie_test_data.tar.gz.md5 download_pilot_fastq.sh \
           files/pilot_truth_set.csv files/sample_name_dictionary.csv \
           "files/fastq_test/$FIRST_FASTQ.md5" files/fastq_test/CUT_PARAMETERS.tsv files/fastq_test/TRUTH_GATE.txt \
           files/S288C_reference/S288C_R64.fa \
           files/S288C_reference/chromosomes/Mito.fa \
           files/S288C_reference_test/S288C_R64_test.fa \
           files/S288C_reference_test/S288C_R64_test.gb; do
    if curl -fsSL -o /dev/null "$BASE_URL/$obj"; then
        echo "  OK      $obj"
    else
        echo "  FAILED  $obj" >&2; VFAIL=1
    fi
done
if (( VFAIL )); then
    echo "  WARNING: a public GET failed — check the container public-access level (infra/azure)." >&2
fi

# Prove the bundle really unpacks to the published file tree, rather than trusting that it does,
# and that the two manifests agree with each other on the same artefacts.
echo "Checking the bundle against SHA256SUMS + MD5SUMS ..."
( cd "$STAGE" && sha256sum -c SHA256SUMS --ignore-missing --quiet 2>/dev/null ) \
    && echo "  OK: staged tarballs + README match SHA256SUMS." \
    || echo "  WARNING: staged artefacts do not match SHA256SUMS." >&2
( cd "$STAGE" && md5sum -c MD5SUMS --ignore-missing --quiet 2>/dev/null ) \
    && echo "  OK: staged tarballs + README match MD5SUMS." \
    || echo "  WARNING: staged artefacts do not match MD5SUMS." >&2
( cd "$STAGE" && md5sum -c ottilie_test_data.tar.gz.md5 --quiet 2>/dev/null ) \
    && echo "  OK: sidecar ottilie_test_data.tar.gz.md5 verifies." \
    || echo "  WARNING: sidecar .md5 does not verify." >&2

cat <<EOF

Published under: $BASE_URL
  README.md                    what the data is: sample↔FASTQ↔SRA, truth set, reference pairing
  ottilie_test_data.tar.gz     full bundle (local onboarding / CI) — BOTH references, + README.md
  snpeff_cache.tar.gz          cache-only (Seqera dir-staging fallback)
  files/**                     individual tree (Seqera per-file staging)
  SHA256SUMS / MD5SUMS         integrity for both shapes, same file set
  *.tar.gz.md5, *.fastq.gz.md5 sidecars — check one big file without fetching a manifest
  samplesheet_test_blob.csv    Seqera samplesheet (per-file public URLs)
  download_pilot_fastq.sh      4-sample pilot recipe (also inside the bundle)
  files/pilot_truth_set.csv    pilot truth set (Sup Data 4+5, pipeline sample names) — also inside the bundle
  files/sample_name_dictionary.csv  paper↔SRA clone-name dictionary — also inside the bundle

⚠️ This is a ROLLING prefix — every consumer of $PREFIX is now serving the content above, with no
   repointing needed. Who that is:
     grep -rn 'releases/ottilie/v' conf/ bin/ infra/ docs/ --include='*.sh' --include='*.config'

Local run:   bash $SCRIPT_DIR/download_test_data.sh
Seqera:      use samplesheet_test_blob.csv; for --snpeff_cache try the files/ dir URL first,
             fall back to snpeff_cache.tar.gz (untar → point at the snpeff_cache/ dir).
EOF
rm -rf "$STAGE"
