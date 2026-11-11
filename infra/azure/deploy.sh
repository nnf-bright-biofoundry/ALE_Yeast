#!/usr/bin/env bash
# Deploy (or just validate) the public release / test-data storage account from the ARM template.
# ARM deployments are declarative + idempotent — re-running converges the resources to the template.
#
# Defaults target the confirmed environment; override any via env:
#   SUBSCRIPTION      Azure subscription            (default: infrastructure-dl-dwh)
#   RESOURCE_GROUP    target RG                      (default: rg-ALEdb, region northeurope)
#   TEMPLATE/PARAMS   ARM template + parameters file (default: alongside this script)
#   DEPLOYMENT_NAME   deployment name in the RG      (default: storage_account)
#   VALIDATE_ONLY=1   run the dry-run validate and stop (create NOTHING)
#
# The account itself lands in the region set in the parameters file (location=denmarkeast), independent
# of the RG's region. Requires: az CLI + an interactive `az login` (this account uses conditional access).
#
# Usage (from anywhere):
#   bash infra/azure/deploy.sh                 # validate + deploy
#   VALIDATE_ONLY=1 bash infra/azure/deploy.sh # dry-run only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSCRIPTION="${SUBSCRIPTION:-infrastructure-dl-dwh}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-ALEdb}"
TEMPLATE="${TEMPLATE:-$SCRIPT_DIR/storage_account.arm.json}"
PARAMS="${PARAMS:-$SCRIPT_DIR/storage_account.parameters.json}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-storage_account}"

command -v az >/dev/null || { echo "ERROR: az CLI not found." >&2; exit 1; }
[[ -f "$TEMPLATE" && -f "$PARAMS" ]] || { echo "ERROR: template/params not found next to this script." >&2; exit 1; }

echo "Subscription : $SUBSCRIPTION"
echo "Resource grp : $RESOURCE_GROUP"
echo "Template     : $TEMPLATE"
echo "Parameters   : $PARAMS"
az account set --subscription "$SUBSCRIPTION"

echo ""
echo "== Validate (dry-run, creates nothing) =="
az deployment group validate \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$TEMPLATE" \
    --parameters "@$PARAMS" \
    --query '{state:properties.provisioningState, error:error}' -o json

if [[ "${VALIDATE_ONLY:-0}" == "1" ]]; then
    echo ""
    echo "VALIDATE_ONLY=1 → stopping before create."
    exit 0
fi

echo ""
echo "== Deploy (creates a PUBLICLY-READABLE container) =="
az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$TEMPLATE" \
    --parameters "@$PARAMS" \
    -o none

echo ""
echo "== Outputs =="
az deployment group show \
    --name "$DEPLOYMENT_NAME" --resource-group "$RESOURCE_GROUP" \
    --query 'properties.outputs.{account:storageAccountName.value, container:containerName.value, containerUrl:publicContainerUrl.value, testDataBaseUrl:ottilieTestDataBaseUrl.value}' -o json

BASE_URL="$(az deployment group show --name "$DEPLOYMENT_NAME" --resource-group "$RESOURCE_GROUP" \
    --query 'properties.outputs.ottilieTestDataBaseUrl.value' -o tsv)"
echo ""
echo "Test-data BLOB_BASE for the data scripts:"
echo "  $BASE_URL"
echo ""
echo "Next: publish the data, then fetch/verify:"
echo "  ACCOUNT=aletestdatapublic CONTAINER=releases PREFIX=ottilie/v2 \\"
echo "    bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/publish_test_data.sh"
echo "  BLOB_BASE=$BASE_URL \\"
echo "    bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/download_test_data.sh"
