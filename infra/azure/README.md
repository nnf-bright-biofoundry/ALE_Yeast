# infra/azure

Infrastructure-as-code for this project's Azure resources. Deploy with the Azure CLI (`az deployment
group create`). Templates hold **config only — no secrets** (account keys / SAS are minted at runtime,
never committed).

## `storage_account.arm.json` — public release / test-data host

A **dedicated** Storage account + public container for stable **public (no-SAS) URLs** — release artifacts
and the ottilie e2e test-data. Kept separate from the `aledata` account on purpose: enabling anonymous
blob access is an account-level toggle, so isolating it here keeps that exposure off the account that holds
real research data. Content is public-derived (PRJNA590203 SRA + public S288C reference), so world-readable
is fine; public access is for zero-credential fetch (no expiring SAS to distribute/rotate), not necessity.

Creates:
- a `StorageV2` account — `Standard_LRS`, `allowBlobPublicAccess: true`, TLS1_2, HTTPS-only,
  `allowCrossTenantReplication: false`, `defaultToOAuthAuthentication: true`, `allowSharedKeyAccess`
  parameterized (leave `true` for now; flip to `false` once publishers move to OIDC/AAD-only);
- the default blob service with **7-day soft-delete** for blobs and containers (accidental-delete safety net);
- a container (default `releases`) with `publicAccess: Blob` — anonymous **read-only per-object, no
  listing**. That's sufficient for our consumption (a single tarball URL + explicit per-file URLs) and the
  most locked-down option. Use `Container` if you need anonymous listing (`azcopy --recursive` /
  directory-staging); `None` to fall back to a private + SAS host.

The ottilie test-data lives under the **`ottilie/v2/`** prefix inside the container, i.e.
`https://<account>.blob.core.windows.net/releases/ottilie/v2/…` — the template outputs this directly as
`ottilieTestDataBaseUrl` (and the bare container URL as `publicContainerUrl`).

### Deploy

Use `deploy.sh` — it sets the subscription, validates (dry-run), deploys, and prints the base URL. Its
defaults target the confirmed environment (`SUBSCRIPTION=infrastructure-dl-dwh`, `RESOURCE_GROUP=rg-ALEdb`);
override any via env. Account name / region / access level come from `storage_account.parameters.json`
(default account `aletestdatapublic` — the `public` suffix flags it as the intentionally world-readable
account, distinct from the private `aledata`; region `denmarkeast`).

```bash
az login                                   # this account uses conditional access → interactive login
VALIDATE_ONLY=1 bash infra/azure/deploy.sh # dry-run: validate, create nothing
bash infra/azure/deploy.sh                 # validate + deploy, then print outputs
```

Manual equivalent (what `deploy.sh` runs):

```bash
az deployment group create \
    --resource-group rg-ALEdb \
    --template-file infra/azure/storage_account.arm.json \
    --parameters @infra/azure/storage_account.parameters.json \
    --query 'properties.outputs' -o json
```

Deployment outputs include **`ottilieTestDataBaseUrl`** =
`https://aletestdatapublic.blob.core.windows.net/releases/ottilie/v2` — this is exactly the `BLOB_BASE` the
data scripts use (`deploy.sh` prints it at the end).

### Wire it into the data scripts

Account / container / prefix must line up across the template and the publish/fetch scripts
(`docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/`). Note the container is `releases`
(not the scripts' current default `ale-test-data`) — pass `CONTAINER=releases` until the defaults are baked in:

```bash
# Publish both shapes (tarball + individual tree + cache-tar + SHA256SUMS + url-samplesheet).
# Account already has public access from the template → no ENABLE_PUBLIC_ACCESS needed.
ACCOUNT=<account> CONTAINER=releases PREFIX=ottilie/v2 \
  bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/publish_test_data.sh

# Fetch on a fresh machine (no creds):
BLOB_BASE=https://<account>.blob.core.windows.net/releases/ottilie/v2 \
  bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/download_test_data.sh
```

Once the account name is fixed, bake `ACCOUNT`/`CONTAINER` into `publish_test_data.sh` and the default
`BLOB_BASE` into `download_test_data.sh` so consumers need no overrides. See `DATA_PROVENANCE.md` →
"Fetch on a new machine" for the full flow.

### Validate

```bash
# Dry-run (no resources created):
VALIDATE_ONLY=1 bash infra/azure/deploy.sh

# After deploy, confirm the public URL serves with NO credentials:
curl -fsSL "https://aletestdatapublic.blob.core.windows.net/releases/ottilie/v2/SHA256SUMS" | head
```
