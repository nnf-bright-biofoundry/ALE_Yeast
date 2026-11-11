#!/usr/bin/env bash
# Ottilie contract test with a LOCAL head job dispatching tasks to Azure Batch.
#
# The de-risking step between `bin/test_ottilie_blob.sh` (fully local) and a Seqera
# Platform launch. It exercises the Azure half — pool creation via the Entra service
# principal, input staging from blob, container pulls on Batch nodes — while keeping
# two Seqera-only variables out of play: no repo clone (your local working tree runs)
# and no Nextflow version negotiation (you invoke the engine directly).
#
# Inputs come from `az://`, not the public https blob, because the SnpEff cache is a
# directory param: Nextflow's http provider cannot list a directory, but az:// stages
# one correctly (verified — deploy/azure/seqera-sp/RUNBOOK.md). This launcher runs the
# PRE-BUILT reference route (conf/params_ottilie_test_blob.yml names fasta, snpeff_cache,
# snpeff_db and report_gff3 and no profile), which the ottilie test profiles left in 2026-11.
#
# Prerequisites:
#   - test data uploaded:  deploy/azure/seqera-sp/08_upload_test_data.sh
#   - SP access verified:  deploy/azure/seqera-sp/05_verify_sp_access.sh
#
# Usage:
#   source deploy/azure/seqera-sp/00_vars.sh          # exports the ids; no secrets
#   read -rs AZURE_CLIENT_SECRET && export AZURE_CLIENT_SECRET
#   bash bin/test_ottilie_azure_batch.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${NXF_VER:=25.10.4}"; export NXF_VER

# Fail with an explanation rather than a bare 127. nextflow lives in the nf-env conda
# environment, not on the default PATH.
command -v nextflow >/dev/null 2>&1 || {
    echo "nextflow is not on PATH. Activate the toolchain first:" >&2
    echo "    eval \"\$(conda shell.bash hook)\" && conda activate nf-env" >&2
    exit 1
}

for v in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_CLIENT_SECRET; do
    if [[ -z "${!v:-}" ]]; then
        cat >&2 <<EOF
$v is not set. Run these two lines in THIS shell, then re-run:

    source deploy/azure/seqera-sp/00_vars.sh
    read -rs AZURE_CLIENT_SECRET && export AZURE_CLIENT_SECRET

00_vars.sh resolves the ids from Azure and exports AZURE_CLIENT_ID / AZURE_TENANT_ID /
AZURE_BATCH_ACCOUNT / AZURE_STORAGE_ACCOUNT. It prints them TRUNCATED on purpose so
logs stay clean — the variables themselves hold the full values, so do not retype
anything from that output. It never sets AZURE_CLIENT_SECRET.
EOF
        exit 1
    fi
done

BLOB="${OTTILIE_AZ_BASE:-az://aletest/ottilie/v1}"
OUTDIR="${OUTDIR:-az://aletest/ottilie-azurebatch-out}"

echo "engine   : NXF_VER=$NXF_VER"
echo "inputs   : $BLOB"
echo "outdir   : $OUTDIR"
# workDir belongs to conf/azure_batch.config — restating its default here is what went stale.
# Nextflow prints the resolved value in its own banner under "Core Nextflow options".
echo "workdir  : ${AZURE_WORK_DIR:-(default from conf/azure_batch.config)}"
echo

# Params come from a FILE, not a pile of --flags. Two reasons, both learned the hard way:
#   - `--genome null` on the CLI yields the STRING "null", which is truthy. A real null
#     can only be expressed in a config or params file.
#   - a params file is reviewable and is what Seqera consumes in Phase 6, so the local
#     Batch run and the Platform run stay in sync instead of drifting.
nextflow run main.nf \
    -profile docker \
    -c conf/azure_batch.config \
    -params-file conf/params_ottilie_test_blob.yml \
    --outdir "$OUTDIR" \
    -ansi-log false \
    "$@"
