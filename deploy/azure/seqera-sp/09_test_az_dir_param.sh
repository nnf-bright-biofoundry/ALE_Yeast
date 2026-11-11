#!/usr/bin/env bash
# Decides — locally, in ~1 minute — whether `snpeff_cache` can be an `az://` directory,
# instead of finding out inside an Azure Batch head job after a long queue wait.
#
# WHAT IS ACTUALLY IN QUESTION
#   snpeff_cache is a directory param. Three separate operations must succeed, and they
#   fail for different reasons — this script reports them separately:
#
#     1. file('az://…/snpeff_cache').exists()       — does a virtual prefix "exist"?
#     2. .isDirectory()                             — KNOWN false on this account: HNS is
#                                                     disabled, so there are no directory
#                                                     objects. The pipeline already skips
#                                                     this guard for cloud paths (6e47b38),
#                                                     so a false here is NOT a blocker.
#     3. Channel.fromPath(…, checkIfExists: true)   — the real risk, and what
#        + staging the whole tree into a task          annotation_cache_initialisation does.
#
#   Only #3 decides it. #2 is expected to fail and is already worked around.
#
# Needs the SP secret in the environment (never on disk in this repo):
#   read -rs AZURE_CLIENT_SECRET && export AZURE_CLIENT_SECRET
#   ./09_test_az_dir_param.sh 2>&1 | tee "logs/09_$(date -u +%Y%m%dT%H%M%SZ).log"

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./00_vars.sh

if [[ -z "${AZURE_CLIENT_SECRET:-}" ]]; then
    cat >&2 <<'EOF'
AZURE_CLIENT_SECRET is not set. This is a setup step, not a failure.

    read -rs AZURE_CLIENT_SECRET && export AZURE_CLIENT_SECRET
    ./09_test_az_dir_param.sh 2>&1 | tee "logs/09_$(date -u +%Y%m%dT%H%M%SZ).log"

`read -rs` reads silently and keeps the secret out of your shell history.
EOF
    exit 1
fi

CONTAINER="${CONTAINER:-aletest}"
PREFIX="${PREFIX:-ottilie/v2}"
CACHE="az://$CONTAINER/$PREFIX/S288C_reference_test/snpeff_cache"
DB="${DB:-R64-1-1.105}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Credentials go in a temp file outside the repo, never committed, deleted on exit.
cat > "$WORK/az.config" <<EOF
azure {
    storage {
        accountName = '$STORAGE_ACCOUNT'
    }
    activeDirectory {
        servicePrincipalId     = '$SP_APP_ID'
        servicePrincipalSecret = '$AZURE_CLIENT_SECRET'
        tenantId               = '$TENANT_ID'
    }
}
EOF
chmod 600 "$WORK/az.config"

cat > "$WORK/probe.nf" <<'NF'
params.cache = null
params.db    = null

process STAGE_CACHE {
    input:  path cache
    output: stdout
    script:
    // -L is REQUIRED: Nextflow stages a directory input as a SYMLINK into its
    // stage-* area. Plain `find <link>` does not descend into it and reports zero
    // files even when staging succeeded perfectly. Getting this wrong once already
    // produced a confident false "silent failure" verdict.
    """
    echo "--- staged into the task as: \$(ls -ld ${cache} | sed 's/.*-> //') ---"
    find -L ${cache} -maxdepth 2 | head -20
    echo "FILE_COUNT: \$(find -L ${cache} -type f | wc -l)"
    """
}

workflow {
    def p = file(params.cache, type: 'dir')
    log.info "PROBE exists()      = ${p.exists()}"
    log.info "PROBE isDirectory() = ${p.isDirectory()}"
    log.info "PROBE db subdir     = ${file("${params.cache}/${params.db}", type:'dir').exists()}"

    // This is the operation annotation_cache_initialisation actually performs.
    ch = Channel.fromPath(file(params.cache), checkIfExists: true).collect()
    STAGE_CACHE(ch).view { it }
}
NF

echo "cache under test : $CACHE"
echo "snpeff_db        : $DB"
echo

set +e
NXF_VER=25.10.4 nextflow -c "$WORK/az.config" run "$WORK/probe.nf" \
    -w "$WORK/work" --cache "$CACHE" --db "$DB" 2>&1 | tee "$WORK/out.txt"
RC=${PIPESTATUS[0]}
set -e

# The exit code is NOT the verdict. Nextflow stages an az:// directory prefix as an
# EMPTY directory and exits 0 — `find`/`echo` inside the task succeed happily on it.
# Only the count of files that actually arrived decides this.
STAGED="$(grep -oP 'FILE_COUNT:\s*\K[0-9]+' "$WORK/out.txt" | tail -1)"
STAGED="${STAGED:-0}"

echo
echo "=============================== VERDICT ==============================="
echo "exit code = $RC ; files actually staged = $STAGED"
echo
if [[ $RC -eq 0 && "$STAGED" -gt 0 ]]; then
    echo "✅ az:// directory staging WORKS — $STAGED files arrived in the task."
elif [[ $RC -eq 0 && "$STAGED" -eq 0 ]]; then
    cat <<EOF
❌ SILENT FAILURE — the run "succeeded" but staged ZERO files.

   This is the dangerous case, and the reason this script counts files rather than
   trusting the exit code: SnpEff would run against an EMPTY cache and either fail
   obscurely or emit wrong annotations, with nothing in the log pointing here.

   Mechanism: AzPath.isDirectory() is false for a virtual prefix, so Nextflow treats
   the path as a single blob, finds none, and stages an empty placeholder. No error
   is raised at any layer.

   Note this is NOT a listing problem — Channel.fromPath('<prefix>/**') enumerates
   the blobs correctly. It is specifically directory-as-a-path-input staging.

   Fix: tarball + untar for snpeff_cache, mirroring UNTAR_CHR_DIR in
   subworkflows/local/prepare_genome/main.nf. Protocol-agnostic; removes the class.
EOF
    RC=1
else
    cat <<EOF
❌ The run itself failed (exit $RC). Read the error above.

   - auth error -> the SP or its secret, not directory staging. Re-run
     05_verify_sp_access.sh first; this test proves nothing until that passes.
   - checkIfExists -> the prefix could not be resolved at all.
EOF
fi
echo "======================================================================="
exit $RC
