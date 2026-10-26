# Runbook — Seqera service principal

Audit record for the Azure side of the Seqera Platform / Azure Batch run. **One entry per script
actually executed**, newest last. Raw transcripts live in `logs/` (gitignored); this file is the
committed summary.

**Nothing identifying goes in this file** — no GUIDs, no secrets. Resources are named; the scripts
resolve names to IDs at runtime (see [`00_vars.sh`](00_vars.sh) and the rationale in
[`../README.md`](../README.md)). To resolve a name to its ID you need tenant access, which is exactly
the audience this record is for.

## Target state

| Principal | Scope | Role |
|---|---|---|
| SP `sp-bright-recon-ale-mutations-pipeline-seqera-deploy` (📛 `cfb_ale_mutations_pipeline` until 2026-08-13) | Batch account `aledev4test` | `Azure Batch Data Contributor` |
| same | Storage account `aledata` | `Storage Blob Data Contributor` |

Per-resource scope only — never the resource group, never the subscription.

## Context — why this SP, and where it came from

`cfb_ale_mutations_pipeline` is an **existing app registration that was deliberately freed up and is
now being repurposed** for the Nextflow / Seqera Platform cloud testing. It is not a fresh
registration and not an accidental reuse.

> 📛 **Renamed 2026-08-13 → `sp-bright-recon-ale-mutations-pipeline-seqera-deploy`** (the naming
> standard of its sibling `sp-bright-recon-ale-mutations-pipeline`, suffixed with its purpose). All
> entries below use whichever name was current at the time. `appId`/`objectId` are untouched, and the
> rename propagated to the service-principal object automatically (verified — `00_vars.sh` resolves by
> SP display name, so propagation is what keeps the scripts working). The Seqera credential keeps its
> original name `azure_SP_cfb_ale_mutations_pipeline` — it binds by clientId, so it is functional
> as-is; align it whenever the credential is next re-entered (e.g. the 2027 secret rotation).

Lineage, in order:

1. It originally served the **ALE mutations web app / pipeline**, holding `Contributor` across the
   whole `rg-ALEdb` resource group.
2. That service was migrated to a **new, separately-scoped SP**
   (`sp-bright-recon-ale-mutations-pipeline`), narrowed to `Contributor` on the `ale` Batch account
   plus `Reader` on the `ensembleamp` image gallery.
3. The old RG-wide `Contributor` was then removed from `cfb_ale_mutations_pipeline`, leaving it with
   **no roles and no secret** — i.e. free.
4. **This runbook** claims that free SP for the Seqera / Azure Batch path, granting two per-resource
   data-plane roles and nothing else.

Steps 1–3 were done from `tmp/azure/azure_sp/` (untracked scratch — see the migration note in
[`../README.md`](../README.md)). Step 4 onward is tracked here.

## Log

| Date (UTC) | Script | Operator | Outcome |
|---|---|---|---|
| 2026-07-31 | `01_preflight.sh` | zhlia@dtu.dk | ✅ Read-only, nothing changed. See findings below. |
| 2026-07-31 08:08Z | `02_grant_roles.sh` | zhlia@dtu.dk | ✅ Both roles granted. Verified: **exactly two** assignments, both single-resource. |

### 2026-07-31 08:08Z — grant verified

`az role assignment list --assignee <sp> --all` returns exactly:

| Role | Scope | Created |
|---|---|---|
| `Azure Batch Data Contributor` | Batch account `aledev4test` | 08:08:47Z |
| `Storage Blob Data Contributor` | Storage account `aledata` | 08:08:50Z |

No resource-group- or subscription-scoped assignment exists for this SP. The other five Batch accounts
and all other storage accounts in `rg-ALEdb` remain untouched.

⚠️ Run without `tee`, so there is no transcript in `logs/` for this step. State was verified
independently afterwards by the query above. Use the `| tee` form from `../README.md` next time.

| 2026-07-31 08:13Z | `03_create_secret.sh` | zhlia@dtu.dk | ✅ Client secret created — see the secret table below. Correctly not logged. |
| 2026-07-31 08:21Z | `05_verify_sp_access.sh` | zhlia@dtu.dk | ⛔ Aborted at the `AZURE_CLIENT_SECRET` guard. No Azure calls made. |
| 2026-07-31 08:23Z | `05_verify_sp_access.sh` | zhlia@dtu.dk | ✅ **ALL CHECKS PASSED** — `logs/05_20260731T082340Z.log`. |

### 2026-07-31 08:23Z — access verification passed

Authenticated as the SP against the real data planes. All eight checks green:

| # | Check | Result |
|---|---|---|
| 0 | SP authenticates with the new secret | ✅ secret valid |
| 1 | List Batch pools on `aledev4test` via AAD | ✅ `Azure Batch Data Contributor` effective |
| 2 | List containers on `aledata` | ✅ |
| 3 | Blob upload / download / delete in `debugging` | ✅ all three, probe cleaned up |
| 4a | **Must NOT** reach Batch account `ale` | ✅ correctly denied |
| 4b | **Must NOT** read storage account `aleprojectdata` | ✅ correctly denied |
| 4c | **Must NOT** read resource group `rg-ALEdb` | ✅ correctly denied |

The negative checks are the substantive result: they demonstrate the grant is genuinely confined to two
resources rather than merely being *believed* to be. Both data planes work with **no** role broader than
a single resource — no `Contributor`, nothing at RG or subscription scope.

**Phase 1 of the cloud-run plan (Azure prerequisites) is complete.** The Entra SP is ready to register
as a Seqera credential.

### 2026-07-31 — preflight findings

- **We can self-assign both roles; no subscription admin needed.** The operator holds **`Role Based
  Access Control Administrator`** on `rg-ALEdb`. Its ABAC condition denies assigning only
  `Owner` / `User Access Administrator` / `RBAC Administrator`; `Azure Batch Data Contributor` and
  `Storage Blob Data Contributor` are **not** on that deny list. This closes the plan's flagged
  "known blocker risk" (Phase 1.2) — the earlier `Contributor without deletes` reading was incomplete.
- **SP is a clean slate**: zero credentials, zero role assignments anywhere. Confirms it is free.
- Batch account `aledev4test`: `allowedAuthenticationModes = [SharedKey, AAD]` → **AAD is enabled**,
  which the Entra service-principal path requires. `poolAllocationMode = BatchService` as Seqera
  expects.
- Batch autoStorage already points at `aledata` — the same storage account we grant blob access on, so
  one grant covers both the Nextflow work dir and Batch's own auto-storage.

| 2026-07-31 08:16Z | _(Seqera web UI)_ | zhlia@dtu.dk | ✅ Entra credential registered in **`DTU-Biosustain/RECON-ALE`**. |
| 2026-07-31 08:3xZ | `06_seqera_readback.sh` | zhlia@dtu.dk | ✅ Credential confirmed; schema captured below. |

### 2026-07-31 — Seqera credential registered, schema captured

Credential `azure_SP_cfb_ale_mutations_pipeline` exists in workspace **`DTU-Biosustain/RECON-ALE`**,
created through the web UI as the plan requires (the credentials API does not validate payloads, so a
guessed field name would save cleanly and fail obscurely at launch).

**The schema — this is the scriptable part.** Provider / `discriminator` = **`azure_entra`**, with
these eight keys:

| Key | Value in our credential |
|---|---|
| `discriminator` | `azure_entra` |
| `batchName` | `aledev4test` |
| `storageName` | `aledata` |
| `clientId` | (set — the SP's application id) |
| `tenantId` | (set) |
| `clientSecret` | secret — withheld by the API |
| `batchKey` | not used on the Entra path |
| `storageKey` | not used on the Entra path |

Verified in the readback: `batchName` and `storageName` match the two resources we granted roles on,
and `clientId`/`tenantId` match the SP. Rotation and any future credential can now be scripted against
these key names instead of guessed.

> ⚠️ The API returns `null` for **every** secret field, so "unset" and "set but withheld" are
> indistinguishable in the readback. Do not infer from `batchKey: null` that no shared key is stored —
> for this credential the Entra form simply never collects one, which is the reason to trust it, not
> the readback.

#### Correction to the plan: `tw` **can** create Entra credentials

The plan records as verified that *"`tw` CLI cannot CREATE Entra credentials — only
`--batch-key/--batch-name/--storage-key/--storage-name`, verified identical in 0.26.0 and 0.38.0"*.
That is **wrong**, and it drove the "must use the web UI" decision. The investigation inspected
`tw credentials add azure` — but there is a **separate `azure-entra` subcommand**, present in the
installed 0.26.0:

```
tw credentials add azure-entra -n <name> -w <org/workspace> \
    --batch-name <batch acct> --storage-name <storage acct> \
    --tenant-id <…> --client-id <…> --client-secret <…>
```

Its five required options map exactly onto the schema captured above. Using the UI for the first one
was still the right call — it guaranteed a known-good shape, and the API genuinely does accept
unvalidated payloads — but **rotation and re-creation are a one-liner**, not a UI chore. Prefer this
over hand-rolled `curl` against `/credentials`, since it validates arguments.

`tw credentials add` also offers an **`ssh`** provider (`-k <private key file>`), which is what makes
the GitHub deploy-key route in plan Phase 2 workable.

### ⚠️ Workspace differs from the plan

The cloud-run plan's commands hardcode `zhlia-wsp`; work actually happens in
**`DTU-Biosustain/RECON-ALE` = `79597273081110`** — org-level and **shared**. Every `-w` in the plan
must be changed, the plan's "existing" assets (shared-key credential, CE) live in the other workspace
and are not available here, and `RECON-ALE`'s six pre-existing shared-key CEs belong to other people's
work — "create a NEW CE, never mutate an existing one" therefore holds for a second reason. (Those six
CEs were eventually retired and deleted 2026-08-13, after this work had replaced them.)

| 2026-07-31 08:43Z | `07_github_deploy_key.sh` | zhlia@dtu.dk | ✅ ed25519 deploy keypair generated at `~/.ssh/seqera_ale_yeast_deploy` (0600). |

### 2026-07-31 — GitHub auth: deploy key chosen (💀 superseded 2026-08-05)

The expired `github_Aletechdev` credential forced a choice, and an **SSH deploy key** won on merit:
repo-scoped, read-only, no expiry to lapse, org-owned rather than person-tied (the workspace is
shared, so a personal token breaks the team on one person's expiry). Generated passphrase-less at
`~/.ssh/seqera_ale_yeast_deploy`, verified end-to-end (`ssh -T` answers `Hi Aletechdev/ALE_Yeast!` —
authenticating as the *repository*, which is the proof it is a deploy key; `git ls-remote` lists
`main` and `v1.0.0`), and registered as Seqera `ssh` credential `github_ALE_Yeast_deploykey`.

**All of it invalidated 2026-08-05** — Platform cannot use an SSH key for a pipeline repository (see
that entry). The keypair survives for local/CI clones; the Seqera registration was deleted 2026-08-07.

| 2026-07-31 | `08_upload_test_data.sh` | zhlia@dtu.dk | ✅ 19 blobs → `az://aletest/ottilie/v1/` (new prefix, no collision). |

### 2026-07-31 — testing `snpeff_cache` as an `az://` directory param

Test data uploaded to the **same** storage account the pipeline authenticates against, so
`snpeff_cache` can be exercised as an `az://` prefix rather than the https route (which cannot work —
Nextflow's http provider has no directory listing, hence the tarball workaround in
`bin/test_ottilie_blob.sh`).

Uploaded (~400 MB of the ~64 GB `data/ottilie/`): `S288C_reference_test/` (15 blobs, incl.
`snpeff_cache/R64-1-1.105/`) and `fastq_test/` (4 blobs). The SP's `Storage Blob Data Contributor`
covers reads at run time — no SAS or shared key needed.

#### RESULT — `az://` directory staging **WORKS**; `--snpeff_cache az://…` is viable

Measured 2026-07-31, verified under two independent auth paths (SP client secret; user-delegation SAS
from an interactive Entra login) and with and without a trailing slash:

| # | Operation | No trailing slash | Trailing slash |
|---|---|---|---|
| 1 | `file('az://…/snpeff_cache').exists()` | true | true |
| 2 | `.isDirectory()` | **false** | **true** |
| 3 | `…/R64-1-1.105` subdir `.exists()` | true | true |
| 4 | `Channel.fromPath(…, checkIfExists: true)` | passes | passes |
| 5 | **Files actually staged into the task** | **7 of 7 ✅** | **7 of 7 ✅** |
| 6 | `Channel.fromPath('az://…/snpeff_cache/**')` | all 7 blobs | — |

**Staging works regardless of the trailing slash**, and regardless of `isDirectory()` returning false.
Nextflow downloads the tree into a `stage-*` directory and symlinks it into the task work dir. The
trailing slash only changes what `isDirectory()` reports (#2) — and the pipeline appends one anyway,
since `snpeff_annotation_cache_key` is `""`, so `file("${snpeff_cache}/")` is what actually gets
evaluated.

Practical consequence: **no tarball workaround is needed for `az://`.** The https limitation is real
and unchanged (no directory listing over http, hence `bin/test_ottilie_blob.sh` untarring locally), but
it does **not** carry over to `az://`. Uploading the test data to `aledata` was the right move and
resolves plan Phase 5's flagged "single most likely functional failure".

> ⚠️ **Correction — an earlier entry here claimed the opposite.** A first pass concluded "az:// stages
> an empty directory, silent failure, use a tarball". That was **wrong**, and the cause was the test,
> not the pipeline: Nextflow stages a directory input as a **symlink**, and `find <link>` does not
> descend into a symlink — so it reported 0 files while all 7 were present. `find -L` shows them.
> `09_test_az_dir_param.sh` now uses `-L`. Two lessons kept deliberately: a verdict must assert on
> staged **content** rather than exit status (still true), and a probe that reports absence must be
> proven able to detect presence before its negative result is believed.

<details>
<summary>Superseded first-pass finding (kept for the record)</summary>

#### ~~RESULT — `az://` directory staging silently produces an EMPTY directory~~

Measured 2026-07-31, and **reproduced twice under two independent auth paths** (the SP client secret,
and a user-delegation SAS minted from an interactive Entra login) — so it is a property of Nextflow's
Azure path handling, not of the credential:

| # | Operation | Result |
|---|---|---|
| 1 | `file('az://…/snpeff_cache').exists()` | **true** |
| 2 | `.isDirectory()` | **false** |
| 3 | `file('az://…/snpeff_cache/R64-1-1.105').exists()` | **true** |
| 4 | `Channel.fromPath(…, checkIfExists: true)` | **passes** — no error |
| 5 | Directory staged into a task | **empty — 0 of 7 files** |
| 6 | `Channel.fromPath('az://…/snpeff_cache/**')` | **works — all 7 blobs enumerated** |

**The distinction that matters.** Nextflow *can* handle `az://` folder paths — #6 proves listing and
globbing over a virtual prefix work fine on this flat (non-HNS) account. What fails is narrower:
passing a **directory prefix as a `path` input** and expecting the tree to be staged. Because
`isDirectory()` is false (#2), Nextflow treats the prefix as a single blob, finds no such blob, and
stages an empty placeholder. **Nothing errors at any layer** — the task exits 0.

Adding a zero-byte directory-marker blob (`…/snpeff_cache/`) was tested and does **not** help:
`isDirectory()` stays false and staging stays empty. The marker was removed afterwards.

> ⚠️ This is the worst failure shape available: not a crash but a silent wrong result. SnpEff would
> annotate against an empty cache and either fail obscurely or emit wrong annotations, with nothing in
> the log pointing back here. The first version of `09_test_az_dir_param.sh` reported ✅ for exactly
> this run because it keyed the verdict on the **exit code**; it now counts the files that actually
> arrived and fails when zero. Any future check of this kind must assert on staged content, never on
> exit status.

**So `--snpeff_cache az://…` is not viable**, and the earlier hope that `az://` would succeed where
`https://` could not is wrong — for different reasons in each case (no directory listing over http; no
directory staging over az).

~~Fix: tarball + untar, mirroring `UNTAR_CHR_DIR`.~~ **Not needed** — see the corrected result above.
A `snpeff_cache` untar path remains a reasonable robustness idea for https-only environments, but it is
**not** a blocker for the Azure run.

</details>

### 2026-08-05 15:44Z — compute environments forged (plan Phase 4) — 💀 CEs since superseded

Two new CEs on the Entra credential (`ale-ottilie-nf25104` and `…-fusion` — single-pool, default boot
disks; both later replaced by the dual-pool/256 GB generation and deleted). None of the six
pre-existing shared CEs was touched. Durable findings, each verified at the time:

- ✅ **Batch Forge works with an Entra SP** — `Azure Batch Data Contributor` on the account sufficed;
  no subscription-level role, no `AuthorizationFailed`.
- ✅ **`-e NXF_VER=25.10.4` stores as head-only** (`head:true, compute:false`), which is all a pin can
  need: **no `nextflow` binary ever executes on a Batch node** (verified from a task wrapper — only
  `NXF_TASK_WORKDIR`/`NXF_DEBUG` are forwarded into containers), so a `both:`/compute pin is a no-op.
  Storing is not taking — always confirm the run log reports the pinned version.
- ⚠️ **Fusion + Entra forged with `managedIdentity*` all `null`** — contradicting the research lead
  that a user-assigned managed identity is required. Runtime proof came 2026-08-07 (`XFwlgZnKvUvpu`).
- ✅ **Forge pools carried the verified `ubuntu-hpc/2404` image** — checked against every pool on the
  account rather than assumed. Re-pinning rules: [`azure_batch_execution.md` §4](../../../docs/dev-practices/azure_batch_execution.md).
- ⚠️ **`tw` 0.26 `--wait AVAILABLE` fails on the *poll*** (`Error reading entity from input stream`)
  while the CE is created fine — re-running creates a **duplicate CE**; read back via the REST API
  instead. Fixed by upgrading to **0.38.0** the same day (SHA-256-verified; the 0.26 binary kept for
  rollback). 0.38 also brought `--pre-run`/`--launch-container` and `--wait` on launch; `tw launch`
  still has no single-param option, so `outdir` must travel in a params file.

### 2026-08-05 — 🚨 the SSH deploy key CANNOT be used to clone the pipeline repo

**Two independent constraints whose intersection is empty:** a GitHub deploy key is an SSH credential
*by definition*, and Seqera Platform's Git integration is **HTTPS-only** — no URL form bridges that.
The key is genuinely valid (`git ls-remote` over SSH reads the repo fine; the same repo over HTTPS:
`Repository not found`), but Platform never consults it. This invalidates the Phase 2 decision above.
Three independent confirmations it is by design: the docs list only HTTPS providers (PAT / GitHub
App / …); Seqera `ssh` credentials exist to reach **SSH-enabled compute environments**, not Git; and
`tw credentials add ssh` has no `--base-url`, so an ssh credential cannot be bound to a Git host even
in principle (readback: `baseUrl: null`).

Also learned, kept because the errors mislead: `tw launch <scp-style-url>` reports `Pipeline '…' not
found on this workspace` (it fell back to a *name* lookup, the message describes the fallback);
**registering to the Launchpad is not a way around** (the Launchpad *is* `tw pipelines` — same
validation, and the head job clones at run time anyway, so a live credential is needed either way);
**Seqera credentials are workspace-scoped** and secret values read back as `null`, so a credential in
another workspace can only be re-entered from the original token, never copied; and the repo is
genuinely private, so *some* credential is unavoidable.

### 2026-08-05 — GitHub App ruled out (no org ownership) → classic PAT

**Decision: classic PAT**, because the better options were blocked by org permissions, not by merit:

| Option | Verdict |
|---|---|
| **GitHub App**, org-owned | **The right answer, and unavailable** — creating and installing one needs org-owner rights on `Aletechdev`, which the operator lacks. A *personally*-owned App buys nothing over a PAT. |
| **Fine-grained PAT** | Real least privilege (`Contents: Read`, one repo) but needs an org owner's *approval*. Submitted in parallel — approved in ~1 day; see 2026-08-07. |
| **Machine-user + PAT** | Repo-scoped and person-free, needs only repo-admin. ⚠️ An outside collaborator on a private repo consumes a paid seat. |
| **Classic PAT (chosen)** | The only option needing nobody's permission. ⚠️ **Cannot be narrowed** — `repo` is all-or-nothing read+write across every reachable repo; strictly broader than the deploy key. The price of the fallback, not a tuning oversight. |

> ⏰ **Record any token's owner and expiry in the table below when it is created** — a shared org
> workspace on one person's token fails, a year later, for someone who doesn't know who to chase.
> 🔁 **Swap to an org-owned GitHub App when an org owner is available** — a credential change and
> nothing else.

### 2026-08-06 — ✅ classic PAT registered; repo clones; first Launchpad entry live (💀 both since replaced)

`personal_token_classic_ALE_yeast` unblocked the clone — proven by `tw pipelines add` succeeding,
since it validates the repository at registration time. Entry `yAMP-ottilie-test` registered (CE
`ale-ottilie-nf25104`, profile `docker`, params pasted from `conf/params_ottilie_test_blob.yml`).
Both since replaced: the PAT by the fine-grained token (2026-08-07), the entry by
`yAMP-ottilie-test-az` (2026-08-12/13). Durable findings:

- ⚠️ **Fine-grained PAT gotcha**: the org *does* appear in the token's **Resource owner** dropdown —
  if the repo seems missing, the cause is Resource owner still set to the personal account.
- ⚠️ **`tw pipelines update` is broken** (HTTP 500; every alternative route fails too — the full
  four-route table is in the 2026-08-12 entry). Every edit is delete-and-re-add, minting a new id.
  **Superseded 2026-10-05 for the params box:** `14_register_pipeline.sh --update` changes it in
  place through `PUT /pipelines/{id}` (2026-10-05 entry).
- **One entry serves many CEs and profiles** — both are overridable per launch, which is also the
  methodologically clean way to compare two CEs with nothing else varying. Separate `outdir` per run.
- 🚨 **An entry stores a pasted COPY of params (`paramsText`), never a reference** — editing the repo
  file changes nothing that entry launches, and the copy rots in silence (the same hazard is written
  into [`seqera_cloud_deployment_checklist.md`](../../../docs/seqera_cloud/seqera_cloud_deployment_checklist.md)
  as if it were a setup step). The fix is profiles + a generated box — see 2026-08-12. Two conditions
  or the profile silently does nothing: the box must not shadow it (`paramsText` is passed as a
  params file, which beats config), and the profile edit must be **pushed** (Platform clones GitHub).
- 📛 Renamed 2026-08-12: `params_ottilie_blob.yml` → `params_ottilie_test_blob.yml` (it is the
  2-sample subset, not a generic default; still read by `bin/test_ottilie_azure_batch.sh` for the
  local head-job path).

## Client secret

| Key id (short) | Display name | Created | **Expires** |
|---|---|---|---|
| `ba06d604…` | `seqera-platform` | 2026-07-31 08:13Z | **2027-07-31 08:13Z** |

> Azure's `hint` field is deliberately **not** recorded here: it is the first three characters of the
> secret itself. Negligible cryptographically, but it is credential material, and this tree holds none.
> Key id plus display name identify the credential unambiguously. Read the hint live with
> `az ad app credential list` if ever needed to match a secret to a key id.

Exactly one credential exists on the app — `--append` worked as intended and nothing was clobbered.
The secret value was never written to this repo.

> ⏰ **Set a calendar reminder for ~2027-06-30** (one month before expiry). An expired secret fails at
> launch with an opaque Azure auth error, a year from now, when nobody has touched this in months —
> this is the single most likely cause of a future "it just stopped working".
>
> 📌 **Since 2026-08-13 the repo also self-warns**: a Claude Code SessionStart hook
> (`.claude/settings.json`) runs `bin/check_credential_expiry.sh` each session and starts warning 60
> days out — for this secret AND the GitHub PAT. It backs up the personal-calendar reminder rather
> than replacing it (it only fires for whoever opens sessions in this repo). After any rotation,
> update the script's dates alongside this file.

### 2026-08-06 — ✅ PHASE 6 COMPLETE: Platform head job runs end-to-end and reproduces the baseline

`ottilie-dualpool-01` (`3C5zYMYY5M32dO`) **SUCCEEDED** — **170 tasks, 0 failed**, matching the local
baseline exactly (138 submitted + 32 cached), with **zero `DiskFull`** on either pool.

Proven for the first time, all in this run: `NXF_VER=25.10.4` takes in a Platform head job; the private
repo clones over HTTPS with the PAT; inputs *and* both directory params (`snpeff_cache`, `chr_dir`)
stage from blob under the Entra SP; containers pull; and **`publishDir` writes to `outdir` from a
Platform-hosted head job** — the last exemption to the same-container SAS rule that had only ever been
verified locally.

**Output comparison vs the verified local-head-job baseline** (`az://aletest/ottilie-azurebatch-out/`):

| | |
|---|---|
| files in common | 529 (540 baseline vs 534 new — the delta is entirely timestamped `pipeline_info/` artifacts; the baseline has two sets because Phase 3.5 ran twice) |
| byte-size identical | 464 |
| differing | 65 — **all in explained classes** |
| **cohort deliverables** | **9/9 byte-identical (md5)** — `cn_cohort_collapsed/full`, `cn_bins_continuous`, `cn_chr_summary_call/germline`, `cn_segments_call/germline`, `sv_cohort_matrix_union/_pass` |

⚠️ **`contentMd5` is NOT populated on these blobs** (0/534) — Azure only stores it when the uploader
supplies it, and Nextflow's publish path does not. The plan's "blob `Content-MD5` vs local md5" method
therefore **does not work here**; compare by size first, then download and hash the files that matter.

The 65 differences classify as: MultiQC plot renders (pdf/png/svg) and `multiqc_data`; igv-reports
`sessionDictionary`; bgzf/gzip framing on `.vcf.gz`/`.tbi`; CRAM ±1 byte; and two Sarek `csv/` files
that **embed the absolute output path** (`seqera-runs/2026-08-06-04` is longer than
`ottilie-azurebatch-out`, which exactly accounts for the +12/+33 byte deltas). Nothing uncategorised,
no variant-content differences.

**`versions.yml` differs by provenance, not content:** `Aletechdev/AMP: v1.0.0` (baseline) vs
`Aletechdev/AMP: v1.0.0-g86c4672` (Platform). nf-core appends the short commit when the pipeline runs
from a **Git clone**; a local-directory run has no commit id. Expected, and desirable.

### 2026-08-06 — root cause of the two failed runs: Docker on the OS disk

Two earlier runs died at **122/138** and **169/170 tasks with ZERO failed tasks** — the signature of a
head-job death, not a pipeline error. The chain:

1. Pool nodes hit **`DiskFull`** and went `unusable`.
2. The head job's node died with them, so Batch rescheduled the head task.
3. The replacement head job tried to re-fetch Platform's **ephemeral launch config** and got **403** —
   the URL is **single-use**. A recoverable node failure therefore became a total run loss.

**It is Docker, not task scratch.** An unusable node had only **0.07 GB across 205 files** in its Batch
task directories — the pressure is `/var/lib/docker` overlay2 on the **OS disk**, from this pipeline's
many tool images (GATK, snpEff, CNVkit, Manta, TIDDIT, igv-reports, MultiQC, FastQC, bwa/samtools).

⚠️ **Concurrency was NOT the cause** — an early hypothesis that proved wrong. The second failure was a
**solo** run. Concurrency only reached the limit faster.

**Fix, both parts needed:**

- **`--dual-pool`** puts the head job on its own pool, so a worker-side disk failure can no longer kill
  a run that is 98% done. This is the durable fix, and it is *cheaper* (head on `Standard_D2s_v3`).
- **`--worker-boot-disk-size 256`** stops the workers filling in the first place.

CE `ale-ottilie-nf25104-bigdisk` (💀 since deleted): the first dual-pool + 256 GB CE, forged with
`tw add … forge` flags — a route later found to silently create **fixed-size** pools (see the
2026-08-07 cost incident); CEs are forged from a template now (`13_create_compute_env.sh`). Verified
at the Azure level that the disk flags genuinely applied (64 GB head / 256 GB worker vs `null` on the
older CEs).

⚠️ **Dual pool requires explicit per-pool VM counts** — omitting `--head-vm-count`/`--worker-vm-count`
fails despite the help text claiming a default. ⚠️ **Dual pool cold-starts slower** — ~17 min for the
head pool to provision vs ~4 min single-pool, because the head job waits on its *own* VM.

> The nicer long-term fix — Docker's data-root on `/mnt` (150 GB ephemeral NVMe) via a pool start
> task — is **deliberately parked** (2026-08-13, see Open items): it needs a `manual` CE that takes
> pool lifecycle, the image pin and `azcopy` back from Forge, to solve a problem dual-pool + 256 GB
> already solved. `preRunScript` cannot do it (head-job scope, not a start task). Detail: §9–§10 of
> [`azure_batch_execution.md`](../../../docs/dev-practices/azure_batch_execution.md).

### 2026-08-06 — other Platform behaviours worth not rediscovering

- **The CE's `NXF_VER` env var beats the launch-UI "Nextflow version" selector.** A run submitted with
  `26.04` selected in Advanced settings still executed **25.10.4**; the selection was silently ignored.
  So you cannot test another engine version from the UI while the CE pins one — use a CE without the
  env var, or a launch-time `--pre-run` that re-exports it.
- **Transient head-job startup failure:** `Unable to access config file .../ephemeral/… Connection
  timed out`, with `start: None` and no Nextflow version reported. Network-level, unrelated to storage,
  credentials or config — it never reached the point of resolving a path. Retry.
- **Seqera shows `manifest.name`, falling back to the repo-derived project name** when a run dies before
  parsing `nextflow.config`. That made one pipeline appear under two names in the runs view; fixed by
  aligning `manifest.name` to the repo handle (see `CLAUDE.md` → Pipeline Identity & Naming).
- **Node `idle` is healthy** — the lifecycle is `creating → starting → idle → running`. `idle` means
  provisioned and waiting for work. The states to worry about are `unusable`, `offline`,
  `startTaskFailed`, `preempted`, `leavingPool`.
- **Batch refuses node removal while autoscale is enabled** (`Remove VMs not allowed when AutoScale is
  enabled`). Use `az batch node reboot --node-reboot-option terminate`. ⚠️ A rebooted node can report
  `state: running, errors: null` and then return to `unusable` minutes later — do not declare a pool
  healthy from one sample.
- ⚠️ **Do not run two pipelines concurrently against one work dir.** Identical code+inputs+params
  produce **identical task hashes**, so both write the same `az://…/nf-work/<hash>` directories. Without
  `-resume` Nextflow does not check for existing dirs and collects outputs by glob, so stale files from
  another run can be picked up as this run's outputs. Use `tw launch --work-dir` to separate them.
- **`tw launch` has no `--resume` flag** in 0.38 (UI/API only).

### 2026-08-07 — ✅ swapped classic PAT → **fine-grained PAT**; org approval landed in ~1 day

`github_ALE_Yeast_finegrained` swapped in; `personal_token_classic_ALE_yeast` deleted from the
workspace **and revoked at GitHub** — two separate actions, and only the second retires the `repo`
read+write reach (a workspace readback looks identical either way). **Correction** to the 2026-08-05
framing ("this org has refused/queued these before"): approval took **about one day**, so the next
person should submit the fine-grained request first and wait a day before reaching for a classic token.

✅ **Verified in live use without spending a run** — reusable technique: note the credential's
`lastUsed` via the API (a genuine usage stamp, distinct from `dateCreated`/`lastUpdated` — all three
differ), open the pipeline's Launchpad form, re-read: `lastUsed` advances, because rendering the form
fetches repo content with the credential live rather than replaying the stored pipeline record. The
`ssh` deploy-key credential read **`never`** under the same test — empirical confirmation that
Platform structurally cannot consult it for a pipeline repo — and was **deleted the same day** (the
keypair survives for local/CI clones). 🗑️ `07_github_deploy_key.sh` was deleted with it (it handed
out dead instructions; recoverable from git history), leaving a deliberate gap in the numbered
sequence. **There is deliberately no replacement script for the GitHub credential**: the token is
minted in the GitHub UI and registered with the hand-typed one-liner under *GitHub PAT* below, so the
secret never enters a transcript or shell history.

**What this fixes, and what it does not.** Blast radius: closed (`Contents: Read` on one repo replaces
`repo` read+write on everything). Person-tied dependency and finite expiry: **unchanged** — the
org-owned GitHub App remains the durable answer and its open item stays open.

### 2026-08-07 — ✅ same-container rule CONFIRMED under a Platform head job (falsification test)

The rule "with an Entra SP, `workDir` must be in the same **container** as the inputs" was verified only
with a **local** head job. Run `48kJmc9QY6Q3h9` (`ottilie-xcontainer-01`) tested it under Platform:
identical to the known-good launch except `--work-dir az://debugging/nf-work-xcontainer`, inputs left in
`aletest`, `outdir` unchanged so only one variable moved.

**Result: 0 succeeded / 6 failed**, dying in `PREPARE_GENOME` ~6 min in (mostly pool warm-up — a cheap
test, no real compute billed). Every failed process reads an input from `aletest`: `SAMTOOLS_FAIDX`,
`GATK4_CREATESEQUENCEDICTIONARY`, `BWAMEM1_INDEX`, `PREPARE_GFF3`, `FASTQC`.

```
.command.log:  Unable to download path:
               https://aledata.blob.core.windows.net/aletest/ottilie/v1/S288C_reference_test/S288C_R64_test.fa
.command.err:  (0 bytes)
```

⚠️ **`.command.err` was empty**, so from the Seqera UI (which shows stderr) this failure looks like *no
error at all*. The real message lives only in `.command.log` in the blob work dir. Anyone debugging a
silent exit-1 here must go fetch it.

So the constraint is a **requirement, not a convention**, and it holds regardless of where the head job
runs — the node-side SAS is minted the same way either way. `outdir` in another container remains
**unproven under Platform**: this run died before publishing, so it tested nothing about `outdir`.
Detail: [`azure_batch_execution.md` §3](../../../docs/dev-practices/azure_batch_execution.md).

The failed run's work dir (58 blobs in the shared `debugging` container) was deleted afterwards.

### 2026-08-07 — ✅ ottilie e2e passed; the hand-edited snapshot is validated

`nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test` → **PASSED in 802 s**, run
**without** `--update-snapshot` on purpose.

This closes a caveat: the `manifest.name` change was applied to `tests/ottilie_e2e.nf.test.snap` **by
hand** (one line, `Aletechdev/AMP` → `Aletechdev/ALE_Yeast`) rather than regenerated, and was therefore
unverified. A pass proves both halves — the edited value is what the pipeline now emits, **and** nothing
else moved, since the `stable_path` md5 layer would have failed otherwise. The snapshot file is
unchanged on disk after the run.

### 2026-08-07 — Fusion CE re-forged with the dual-pool + disk fixes (💀 since deleted)

`ale-ottilie-nf25104-bigdisk_fusion`: Fusion v2 + Wave, dual-pool, 256 GB workers — carrying the
§9–§10 fixes over so a Fusion run isolates **Fusion** as the single variable instead of re-hitting
`DiskFull`. The original single-pool `…-fusion` was disabled.

### 2026-08-07 — ✅ Fusion + Entra verified, and node disk usage MEASURED (one run, `XFwlgZnKvUvpu`)

`ottilie-fusion-diskprobe` on `ale-ottilie-nf25104-bigdisk_fusion`, with
[`conf/disk_probe.config`](../../../conf/disk_probe.config) attached via `--config`, a **fresh** outdir
(`az://aletest/seqera-runs/2026-08-07-02-fusion`) and a **fresh** work dir (`nf-work-fusion02`).
**SUCCEEDED — 170/170 tasks, 0 failed, 0 `DiskFull`.**

**1. Fusion + Entra SP works.** The plan flagged this as *unverified*, since the only working Fusion CE
was on a **shared-key** credential. It now runs on the Entra SP, with dual-pool and 256 GB workers.
All **9 cohort deliverables byte-identical** to the validated non-Fusion baseline
(`seqera-runs/2026-08-06-04`), 534 blobs. Note this run is on current `main` (`d8956ef`, the new
`manifest.name`) while the baseline is `86c4672` — so the deliverables match across **both** the Fusion
change and four commits.

⚠️ An earlier Fusion run (`3eXbxZVVpOPtGW`) also succeeded 170/170, but it shared outdir
`2026-08-07-01` with the non-Fusion `5Ped8HWvzzjoDx`, so that directory is a **mixture** and is not a
citable artifact. `2026-08-07-02-fusion` is the clean one.

**2. Peak OS-disk usage is ~65 GB** — measured across 21 nodes, not inferred:

| disk size | peak used | range | free at peak |
|---|---|---|---|
| 246.9 G | **65.2 G (26%)** | 56.7–65.2 G | 182 G |

- A 57–65 GB working set overruns the default OS disk, whatever it is — that is the whole `DiskFull`
  story, and it confirms the concurrency hypothesis was wrong: a solo run exceeds the default on its
  own. ⚠️ **This bullet originally asserted "the default is ~30 GB, so 57–65 GB overruns it 2×".
  That figure was an assumption, never measured**, and `az vm image show` does not return
  `osDiskImage.sizeInGb` for this image. The default is only known to be *large enough* for 122/138
  and 169/170 tasks before filling, i.e. somewhere near the 65 GB peak — 64 GB would fit the observed
  failure timing exactly, but that is inference. See
  [`azure_batch_execution.md` §9](../../../docs/dev-practices/azure_batch_execution.md).
- 256 GB is ~3.8× the peak; 128 GB would suffice. The margin costs ~$0.05/hr across four nodes.
- ✅ **The `/mnt` relocation fix is viable**: 65 GB fits inside the 150 GB ephemeral NVMe — the
  assumption that fix rested on.

⚠️ **Correction to the config's original comment:** `beforeScript` runs **inside the container**, not on
the node (`hostname` = container id, `/` = `overlay`). The reading is still valid — overlay2's `df`
reports the backing filesystem, and 246.9 G matches the OS disk — but the mechanism is not as stated.
⚠️ **Under Fusion the work-dir `df` is useless**: it reports a synthetic `fusion 8.0P … 50% /fusion`.
Only the `root:` line is usable there.

### 2026-08-07 — 🚨 COST INCIDENT: `tw --dual-pool` creates FIXED-SIZE pools (~$66/day)

**Ten nodes ran idle for hours.** Both dual-pool CEs forged with `tw` read back
`autoScale: null`, which Azure builds as `enableAutoScale: False` — fixed at 1 head + 4 workers:
**8× `E4ds_v4` + 2× `D2s_v3` ≈ $2.75/hr compute plus ~$324/month of managed disks**, billing
regardless of load. Noticed only because a cold pool was wanted for a disk baseline and the pools
would not drain; **reproduced deliberately** with a throwaway CE — repeatable CLI behaviour, not a
one-off. Root cause: for dual-pool the CLI **omits** the `autoScale` field (single-pool is
unaffected), nothing warns, and `tw` reports success. The web UI *can* set it — but "use the UI" was
**superseded 2026-08-11**: CEs are created from a template now (next entry). Remediation: pools
resized to 0; the fixed-size CEs were eventually deleted 2026-08-13.

**Guard added:** [`12_verify_compute_env.sh`](12_verify_compute_env.sh) asserts `autoScale` on both
pools (plus workDir and disk sizes) and fails with the resize/delete steps. ⚠️ **CEs are immutable** —
verify *before* launching, not after the invoice.

⚠️ **A new pool shows 1 node for its first ~5 minutes by design** (the Forge formula pins the first
interval) — `1 + 1` right after creation proves nothing; **`0 + 0` fifteen minutes later** is the real
check. Unrelated to Wave/Fusion. ⚠️ **`--worker-vm-count` is a CEILING under autoscale**, not an
allocation.

### 2026-08-11 — ✅ CEs are now created from code (`tw compute-envs import`)

**CEs are no longer created by hand, and not the way that was planned either.** The plan was a raw REST
creator, "since the CLI cannot express the one field that matters". `tw` *can*: **`compute-envs
export`/`import` round-trip `autoScale`**, and neither subcommand had been tried — the 2026-08-07
investigation stayed inside `add ... forge`'s flag set and generalised from it. **No API client was
written.**

| Ran | Result |
|---|---|
| `tw compute-envs export -n …_autoScale_manual_noFusion` | `headPool.autoScale: true` / `workerPool.autoScale: true` in the exported JSON |
| `./13_create_compute_env.sh ale-ce-import-test` | CE `5HMxAhK0lWX4X7JUDhoOVm` AVAILABLE; `12_verify_compute_env.sh` **6/6 OK** |
| `az batch pool list` at creation | both pools `enableAutoScale: True`, at the expected `1 + 1` |
| same, 17 min later (08:20Z) | **`0 + 0`** — autoscale genuinely working |
| `./13_create_compute_env.sh … --delete` | CE DELETED; both pools disposed by 08:25Z, no orphaned disks |

Cost of the test: ~5 node-minutes (1× `D2s_v3` + 1× `E4ds_v4`).

**Two corrections to the 2026-08-07 entry above.**

1. **`tw add ... forge` CAN set autoscale**, via explicit `--head-no-auto-scale=false
   --worker-no-auto-scale=false`. Undocumented in `--help`; from
   [seqeralabs/tower-cli#658](https://github.com/seqeralabs/tower-cli/issues/658). Verified here by
   inspecting the request payload with `tw -v` against an existing CE name — the collision is rejected
   *after* the body is printed, so the check costs nothing and creates nothing.
2. **The field is OMITTED, not sent as `null`.** The control payload (no flags) has no `autoScale` key
   at all on either pool; the `null` in the 2026-08-07 entry is Platform's readback of the missing
   field. Both descriptions are correct, at different layers.

**Decision: `import` is the route, `=false` is an escape hatch.** `add ... forge` has **no flags** for
`jobMaxWallClockTime`, `deleteJobsOnCompletion`, `deleteTasksOnCompletion` or
`terminateJobsOnCompletion`, so a flag-built CE silently takes Platform defaults for the four
job-lifecycle settings our CEs pin (`7d` / `never`). Fixing autoscale that way trades a loud bug for a
quiet one. The template is a readback, so every field in it is one Platform wrote.

⚠️ **The upstream fix is not released.** [#659](https://github.com/seqeralabs/tower-cli/pull/659) is
**open/unmerged** as of 2026-08-11 and **0.38.0 is the latest release** — there is no version to upgrade
to. Re-check when it merges: plain `add --dual-pool` becomes safe, but the job-lifecycle gap remains.

**Files:** [`13_create_compute_env.sh`](13_create_compute_env.sh) (`<name> [--fusion|--delete]`) ·
[`ce_import_template.json`](ce_import_template.json) (export of the working non-Fusion CE; `--fusion`
flips only `fusion2Enabled`/`waveEnabled`). ⚠️ `tw` strips the template's trailing `"labels": []` —
labels go through `--labels`, not the config body. The script refuses to run if the template's
`autoScale` is not `true`.

### 2026-08-12 — Launchpad params moved into the repo, and the one default that refuses to move

**New entry `yAMP-ottilie-test-az` (`172614290773283`)**, registered by
[`14_register_pipeline.sh`](14_register_pipeline.sh) because `update` is dead (four-route table
below). Config profiles **`docker, ottilie_test_az`** — the params live in the repo, read from the
clone at every launch, so there is no pasted copy to rot. The CE is the autoscaling non-Fusion keeper;
`nextflowVersion` and `configText` unset. **One entry, not one per dataset** — profiles are
overridable per launch, exactly as the CE is, so the full-depth pilot runs from this same entry with
`-p docker,ottilie_pilot_az` plus its own `outdir`. (An earlier same-day registration of this entry
under id `227711052831937` was itself replaced within hours — the id churn below is why.)

⚠️ **There is NO way to change a registered entry in place — all four routes were tried (2026-08-12):**

| Route | Result |
|---|---|
| `tw pipelines update` | **HTTP 500**, any combination of options |
| `PUT /pipelines/{id}` direct | **HTTP 400**, both with `name` added and with the full launch object round-tripped from `GET` |
| `tw pipelines versions manage` | only **renames** a version or sets it default — cannot create one |
| `tw pipelines import --overwrite` | works, but reports *"New pipeline added"* and **the pipeline id changes** — delete-and-re-add underneath |

So every edit mints a new pipeline id, and **a bookmarked Launchpad URL breaks each time**
(no longer true for a params-box change: `PUT` works when `launch` carries `computeEnvId`,
2026-10-05 entry). Nothing in
this repo depends on the id; only this entry records it. Platform pipelines *do* carry versions
(`yAMP-ottilie-test-az-1`, default), but nothing exposed by `tw` or the API can add one
(2026-10-05: a `PUT` that changes the entry does add one and makes it the default).

🔬 **And the version hash is blind to the repo — a reproducibility trap.** `main` advanced
`bd4e49a` → `b2c069a` (six commits, two new profiles, a config refactor) and the hash was
**byte-identical before and after**: it is content-addressed over the *stored entry* only. The entry
pins the branch **name**; Nextflow resolves it to a commit at launch, so the same entry runs different
code as `main` moves. Re-registering identical content also reproduces the hash under a *new* id —
seen three times today — so an unchanged hash proves nothing either way.
**Never cite a pipeline name, version name or hash as provenance.** Use the run's `commitId` (run
`2eiGBEA0NXagap` recorded `bd4e49a3b3ea…`, which the entry never mentioned), the `versions.yml` in the
published outdir, or `--commit-id <sha>` at registration for an entry whose results you intend to cite.
Full detail: [`azure_batch_execution.md` §14](../../../docs/dev-practices/azure_batch_execution.md).

**`-p <profile>` stores a REFERENCE; `--params-file` stores a SNAPSHOT.** The profile name is resolved
by Nextflow after the head job clones the repo, so params are whatever the file says at launch time.
`--params-file` is read once by `tw` and frozen into `paramsText`. Because `update` is broken, a frozen
copy can only be changed by re-registering; the profile is changed by a commit and a push.

**🖥️ The box nevertheless carries the FULL param set — a deliberate UX trade.** Platform's launch form
populates its fields from `paramsText` only; profile values are applied at runtime but never displayed,
so the launch page showed an empty `input` box and a reader had to open the profile to learn what would
run. That break was judged worse than the alternative. The box is therefore **generated from the
profile** (`./14_register_pipeline.sh --generate`), not hand-copied, and a normal run of the script
re-derives it and **aborts on drift** — so the two artifacts cannot silently diverge.

⚠️ **Consequence: a Launchpad run is now driven by the box, not the profile** (`-params-file` beats
config). Changing a param means edit profile → `--generate` → commit → re-register, and re-registering
mints a **new pipeline id** every time. The profile remains the single source of truth and is what local
runs and nf-test actually execute.

**`outdir` is emitted as a deliberately disposable default:** `az://aletest/seqera-runs/yAMP-out-test-DUMP`.
It is *not* taken from the profile — the profile's value is a Groovy timestamp, and freezing one
evaluation of it into the box would send every future run to one stale second. A populated field was the
whole point of generating the box, so the compromise is a destination whose **name announces that it is
not one**: runs that leave it publish on top of each other, and since `publishDir` overwrites but never
deletes, that directory accumulates a mixture and is not citable. ⚠️ **Change it in the launch form for
anything you intend to compare, publish or cite.** The profile's timestamped
`yAMP-out-test-<YYYYMMDD-HHMMSS>` still governs local runs, which have no params box.

**🚨 First launch failed, and the cause is worth knowing.** Run `2eiGBEA0NXagap`, `-profile
docker,ottilie_test_az`, died with `No such file or directory: s3://annotation-cache/snpeff_cache/R64-1-1.105`
— the nf-core default — even though the profile sets an `az://` path *and Platform's own resolved
config for that run shows the `az://` value*. The launch form **injects some `nextflow_schema.json`
defaults into the submitted params**, and submitted params beat config. Four params were submitted from
a two-line box: `step` and `outdir` from the box, `snpeff_cache` and `custom_config_base` injected.
Not every schema default is injected — `split_fastq` and `genome` were not, and the profile's values
survived — which is precisely what makes it easy to miss. Mechanism, and the two API calls that
distinguish *submitted* from *resolved*: [`azure_batch_execution.md` §13](../../../docs/dev-practices/azure_batch_execution.md).

**Consequence: `snpeff_cache` is repeated in the params box on purpose.** It is the only param that
must be, and it is also the one that differs between the two datasets
(`S288C_reference_test/snpeff_cache` vs `S288C_reference/snpeff_cache`). So running the pilot from this
entry means changing **two** things at launch — `-p docker,ottilie_pilot_az` *and* that path. The box
says so in a comment. If the pilot becomes routine, give it its own entry instead.

⚠️ **`nextflowVersion` deliberately unset**, unlike the old entry which stored `26.04`. That never took
effect — the CE's `NXF_VER=25.10.4` wins (§12) — and it contradicts what runs, since 26.x cannot parse
`nextflow.config`. Pinning the engine per *pipeline* rather than per *CE* is arguably the better model,
but neither `tw pipelines add` nor `tw launch` has a `--nextflow-version` flag, so it is UI-only, and
the CE pin also covers ad-hoc launches. Revisit if `tw` gains the flag.

⚠️ **The params box cannot be empty or comments-only** — Platform rejects that with *"Invalid
ParamsText format"*, because a comments-only document is valid YAML that parses to `null` rather than an
object. Hence the inert `step: "mapping"` (already the schema default). **Comments themselves are
preserved verbatim**, confirmed by readback, which is what makes the box usable as in-place guidance.

⚠️ **The launch form cannot display what a profile sets.** It renders from `nextflow_schema.json` plus
the stored `paramsText`, never from a profile — so `input`, `fasta` and `tools` appear blank even though
they are set at runtime. That is the real cost of this design; the comment block in the box is the
mitigation. 📌 Do **not** "fix" it by moving dataset paths into `nextflow_schema.json`: schema defaults
are pipeline-wide, are applied by nf-schema at runtime, and would make an ottilie samplesheet the
default for every use of this pipeline — besides diverging from upstream Sarek 3.5.1.

**The profiles compute a timestamped `outdir`** (⚠️ *corrected 2026-09-10: this paragraph originally
began "`outdir` is not pinned in the box" — true on 2026-08-12, superseded the next day by `b7f91a4`,
which pins the box to the disposable `yAMP-out-test-DUMP` default described above; the box value wins on
Platform, so the timestamp below now governs local runs and Platform launches whose `outdir` field is
cleared*). Both `_az` profiles compute
`az://aletest/seqera-runs/yAMP-out-{test,pilot}-<YYYYMMDD-HHMMSS>` in Groovy, so two launches can never
publish into the same directory even if nobody edits anything. Verified at run time: consecutive runs
resolved `…-20260812-150202` and `…-20260812-150208`, and an explicit `outdir` still overrides. ⚠️ It is
evaluated when the head node parses the config, so a `-resume` publishes to a **new** directory — pass
an explicit `outdir` when resuming. ⚠️ `workflow.runName` is **not** available in config on 25.10.4
(`Unknown config attribute`), which is why this uses a timestamp rather than the Platform run name.

✅ **The old `yAMP-ottilie-test` (`227651105760023`) was deleted 2026-08-13**, once run
`1XuapND2cN2oCO` proved the new entry end to end. It was kept until then precisely because a readback
proves configuration, not behaviour.

**Registration is now scripted:** [`14_register_pipeline.sh`](14_register_pipeline.sh) +
[`launchpad_params_ottilie_test_az.yml`](launchpad_params_ottilie_test_az.yml). The box content lives
in the repo, so the copy Platform holds is reproducible and reviewable rather than existing only in a
browser field — which is how the 2026-08-07 entry came to carry params naming a file that no longer
existed. The script deletes-then-adds (no working `update`), refuses a params box that does not parse
to a non-empty object, asserts `snpeff_cache` is present and `nextflowVersion` unset on readback, and
warns when `conf/test/` has uncommitted changes or local is ahead of `origin` — the two ways a launch
silently runs code you are not looking at. `DRY_RUN=1` prints without touching anything.

**Still an interim shape.** Every param is duplicated between the profile and the generated box — the
duplication this change set set out to remove. It is accepted because the two alternatives were worse:
a minimal box breaks the launch-page UX, and no box at all breaks the run outright (`snpeff_cache`).
The duplication is at least *generated and drift-checked* rather than hand-maintained. A genuinely
elegant fix needs one of: Platform reading profiles when rendering the form, Platform not injecting
schema defaults, or `tw pipelines update` working so the box can be refreshed without a new id.

### 2026-08-13 — ✅ the profile/box change set VALIDATED by a run, and two new traps

**Run `1XuapND2cN2oCO`**, launched from the UI on `yAMP-ottilie-test-az` → CE `yAMP-ce-nofusion-256`,
`outdir az://aletest/seqera-runs/yAMP-out-test-20260813`. **All nine cohort deliverables byte-identical
to the `2026-08-06-04` baseline** (downloaded and md5'd — `contentMd5` is not populated on
Nextflow-published blobs), 534 blobs.

| Proved by this run | Evidence |
|---|---|
| Config refactor (`ottilie_common` + `_az` profiles) is behaviour-preserving **in the cloud** | 9/9 deliverables identical; local `nextflow config` equality had only proved it on paper |
| Params via the generated box, not a pasted copy | 17 submitted params, 16 ours + `custom_config_base` |
| `snpeff_cache` repeated in the box fixes §13 | ran past the point that killed `2eiGBEA0NXagap`; **no `s3://` injection** |
| **Engine pin moved CE → Launchpad entry** | head job ran **25.10.4** with **no `NXF_VER` on the CE** |
| `import` carries `nextflowVersion` where `add` cannot | that pin arrived via `14_register_pipeline.sh` |
| A CE forged by `13_create_compute_env.sh` runs real work | dual-pool, autoscaled, no `DiskFull` |
| `main` is resolved at launch (§14) | run recorded `commitId b7f91a44`, which the entry never names |

🚨 **Trap 1 — the run was reported `UNKNOWN` while succeeding.** Platform froze at 132/9 (`lastUpdated`
11:47:31Z) because the head job **completed the pipeline and then hung instead of exiting**, so the
terminal status was never sent. `tw runs cancel` killed it (`exitCode 137`) and pools drained to `0+0`
within 5 minutes — but the run is now filed as **`CANCELLED`**, for a run whose outputs are complete
and verified. ⚠️ **Cite this run by evidence, never by its Platform status.** Mechanism, both failure
directions, and the two authoritative sources:
[`azure_batch_execution.md` §15](../../../docs/dev-practices/azure_batch_execution.md).

🚨 **Trap 2 — `jobMaxWallClockTime` does not apply to the head job.** `ce_import_template.json` sets
`"7d"`; Azure reported `TimeSpan.MaxValue` (no limit) on `nf-workflow-1XuapND2cN2oCO`. A hung head job
therefore holds its node **indefinitely** — the head pool cannot scale to 0 while a task is `running`.
Only noticed because the pool was being watched. **Added to Open items.**

**Also changed today:** `NXF_VER` removed from `ce_import_template.json`; `12_verify_compute_env.sh`
no longer requires it (`EXPECT_NXF_VER` defaults empty — set it to re-assert on an older CE);
`14_register_pipeline.sh` registers via `import` with `NEXTFLOW_VERSION` and asserts it on readback.
⚠️ The trade: a launch that does **not** come from an entry carrying the pin now gets Platform's
default engine, and 26.x cannot parse `nextflow.config`.

### 2026-08-13 — 🧊✅ COLD-POOL DISK BASELINE MEASURED (full-depth pilot, run `18wEWW90THA2Ek`)

**Base ≈ 45 G, pipeline adds ≈ 15 G, peak 60.0 G of 246.9 G; task-scratch disk peaked at 2.7 G.**
The 2026-08-12 spec was executed as written: fresh CE `yAMP-ce-coldprobe-256` forged with
`13_create_compute_env.sh` (6/6 checks; new pools = genuinely cold nodes), launched from
`yAMP-ottilie-test-az` with `-p docker,ottilie_pilot_az --config conf/disk_probe.config`, params
overridden to **two lines only** (pilot `snpeff_cache` + explicit
`outdir az://aletest/seqera-runs/yAMP-out-pilot-coldprobe-20260813`), fresh
`workDir az://aletest/nf-work-coldprobe-20260813`. **SUCCEEDED — 310/310 tasks, 0 failed**, 54 min
(13:23–14:17Z), engine **25.10.4**, `commitId 6fc71d5`. All 310 `.command.log`s were harvested — the
numbers are a census, not a sample. Conclusions + numbers live in
[`azure_batch_execution.md` §9 → cold-pool baseline](../../../docs/dev-practices/azure_batch_execution.md);
the headlines: the base is the `ubuntu-hpc 2404` OS image itself (~45 G before any pipeline image);
image pulls, not data, drive the growth (11× the input data did not move `/` usage); **128 GB would
suffice**; the `/mnt` relocation fix has ample headroom (images ~15 G + scratch ≤2.7 G vs 150 G).
The CE was deleted after harvest; pools disposed; the Batch account is back to only
`yAMP-ce-nofusion-256`'s two pools. Outputs kept at the outdir above (no truth set — diagnostic, not
citable as a validation).

Traps found while doing it, each verified:

- **`deleteTasksOnCompletion: true` (our template) erases Batch task records as tasks finish**, so a
  post-hoc task→node mapping via `az batch task list` is impossible — the per-process jobs survive
  (`deleteJobsOnCompletion: never`) but are all empty. Also: those jobs are named
  `job-<hash>-<PROCESS>` with **no run id in the name** — filter by *pool id* to find a run's jobs.
  Node attribution for the measurement came from Seqera's task records (workdir + timestamps) plus
  the df trajectories themselves; a future run wanting exact mapping must snapshot task lists *during*
  the run.
- **`tw pipelines export` silently omits `nextflowVersion`** even when the entry has it set —
  readback shows `None` while `GET /pipelines/{id}/launch` shows `25.10.4`. Do not audit the engine
  pin via `export`.
- ✅ **`tw launch` from an entry DOES carry the entry's `nextflowVersion`** (verified in the submitted
  launch record before the run started), and **does not inject schema defaults when `--params-file`
  is given** — 2 params in, 2 params submitted, no `s3://` `snpeff_cache`. The §13 injection is a
  launch-*form* behaviour.
- ✅ **The head job exited cleanly** — status `SUCCEEDED`, pools drained to 0 unaided. The
  `1XuapND2cN2oCO` hang is therefore intermittent, not systematic; the reaper open item stays open.

### 2026-08-13 — ✅ Fusion does NOT lift the same-container rule; cross-container `outdir` publish DOES work (run `3AJ4JRNkb7D2dG`)

`ottilie-xcontainer-fusion-01` repeated the `48kJmc9QY6Q3h9` predicted-failure launch on a freshly
forged Fusion CE (`yAMP-ce-fusion-256`, forged and deleted the same day by `13_create_compute_env.sh
… --fusion`): inputs in `aletest`, `--work-dir az://debugging/nf-work-xcontainer-fusion-20260813`,
explicit `outdir` back in `aletest`, `conf/disk_probe.config` attached. **FAILED — 0/6 tasks, the
same six `aletest`-reading processes as the baseline, ~5 min in** (engine 25.10.4, `commitId ff0c57c`).
A cheap test, and each of its four findings is one the baseline could not give:

1. **The same-container rule is a property of the credential delegation, not of the data path.**
   Fusion consumed the same single container-scoped user-delegation SAS Nextflow mints for the
   work-dir container and presented it against `aletest` — `.fusion.log` records the server's
   `403 AuthenticationFailed` with the string-to-sign scoped to the work-dir container, plus Fusion's
   own summary: *"Fusion authenticated successfully but lacks permission to access this resource."*
   The rule is now confirmed under both the azcopy (non-Fusion) and FUSE (Fusion) data paths —
   **do not design around Fusion lifting it.** §3 of
   [`azure_batch_execution.md`](../../../docs/dev-practices/azure_batch_execution.md) updated.
2. **Debuggability is better under Fusion.** `.command.err` is non-empty (`Permission denied` from
   samtools) and `.fusion.log` carries the full 403 — unlike the non-Fusion signature, where the only
   evidence is `Unable to download path` in `.command.log` and stderr is empty.
3. **Cross-container `outdir` under a Platform head job: proven for `publishDir` writes.** The head
   job published five `pipeline_info/` files into
   `az://aletest/seqera-runs/yAMP-out-xcontainer-fusion-20260813/` (kept as evidence) while `workDir`
   sat in `debugging` — publishing runs in the head process under the full SP credential, exempt from
   the node SAS rule, now verified under Platform and not only locally. Task-output publishing uses
   the same head-side mechanism but has not been demonstrated end-to-end by a successful
   cross-container run.
4. **The disk probe is `root:`-only under Fusion, `/mnt` line included.** Cold node: 47.4 G of
   246.9 G ≈ the ~45 G base + first image pulls. The `work:` line reports Fusion's synthetic
   `8.0P /fusion`; the `mnt:` line reports the **container overlay**, not the host `/mnt` — so
   Fusion-cache-vs-Docker competition for the ephemeral disk remains unmeasurable from inside a
   container. No cache-growth data from this run (it died before real I/O); that needs a successful
   same-container Fusion run with the probe attached.

Cleanup: CE deleted (pools and disks disposed — the Batch account is back to only
`yAMP-ce-nofusion-256`'s two pools); the `debugging` work dir purged; the outdir evidence blobs kept.

### 2026-08-13 — 🧊✅ FUSION CACHE FOOTPRINT MEASURED (run `47xZrJ3vg4avR9`): ≲3 G on the OS disk at test-set scale

`ottilie-fusion-cache-01` executed the open item's recipe as written: fresh **cold** Fusion CE
(`yAMP-ce-fusion-256`, second forge of that name, deleted after harvest), inputs + `workDir` together
in `aletest` (`nf-work-fusion-cache-20260813`), `conf/disk_probe.config` attached, explicit
`outdir az://aletest/seqera-runs/yAMP-out-fusion-cache-20260813`. **SUCCEEDED — 170/170 tasks, 0
failed**, engine 25.10.4, `commitId f3b852d`, head job exited cleanly. All 170 `.command.log`s
harvested — a census, not a sample.

| `root:` usage (170 readings) | value |
|---|---|
| min (first task on a cold node) | **45.4 G** — the `ubuntu-hpc` base, matching the non-Fusion cold baseline exactly |
| median / p90 | 53.5 G / 55.5 G |
| **peak** | **63.0 G of 246.9 G (26%)** |

**Conclusion: at test-set scale Fusion adds ≲3 G of OS-disk pressure** — the non-Fusion cold picture
is base ~45 G + images ~15 G ⇒ ~60 G, and the Fusion peak with the same image set is 63.0 G. The
sizing conclusions are unchanged (256 GB ample, 128 GB would still suffice), and the parked `/mnt`
relocation stays parked — Fusion adds no reason to revisit it at this scale.

Caveats, so the number is not over-read:

- **No per-node attribution under Fusion**: the probe's `host=` is the *container* id there — 170
  distinct values across ≤5 nodes — where non-Fusion runs showed node-stable ids (21 hosts across
  340 tasks on 2026-08-07). The peak is a fleet-wide max, not a per-node trajectory.
- **Cache growth may scale with data volume.** The test set stages ~400 MB of inputs; eviction was
  not probed. Re-measure at pilot scale if Fusion ever becomes the default — the standing interim
  policy (probe attached to Fusion dev runs) covers exactly this.
- Readings are point-in-time at task start (`beforeScript`), so intra-task growth is invisible —
  the same limitation as every probe run.

Outputs published to the outdir are **diagnostic, not citable** (probe perturbs task hashes; no
baseline comparison — Fusion output identity was already proven by `XFwlgZnKvUvpu`). Cleanup: CE
deleted with pools and disks; work dir purged after harvest; the Batch account is back to only
`yAMP-ce-nofusion-256`'s two pools.

### 2026-09-01 — ✅ Launch form trimmed to the Tier-1 surface; entry re-registered (id `164422644302756`)

The Seqera launch form now renders **26 visible parameters** (was 122): the schema is generated from
a visible-param allowlist — `conf/schema_overlay.yml` applied by `bin/apply_schema_overlay.py`
(commit `fd31e1f`; hidden params stay reachable via the form's "Show hidden params" toggle and the
YAML view). `joint_manta` defaults to `true` pipeline-wide (`37867a5`), aligning Launchpad runs with
the validated local recipe — the box never set it, so Seqera had silently been running per-sample
Manta. Box regenerated with `--generate` (chr_dir and genbank dropped — Control-FREEC-/breseq-only,
staged-but-unused on Tier-1; `joint_manta` fell out as profile-equals-default) and the entry
re-registered by `14_register_pipeline.sh`: **new pipeline id `164422644302756`** (replaces
`172614290773283` — id churn per the four-route table above). Readback verification all-green,
engine pin `25.10.4` preserved. The registered revision includes the FS-gated SOR filter
(`4c45fb8`), so the next Launchpad run is the first cloud run with the new soft filter.

### 2026-09-02 — ✅ LOCAL-vs-SEQERA 4-SAMPLE PILOT: EQUIVALENT (first cloud run of the SOR_FS filter)

Same commit (`fedfab7`) both sides. **Seqera** run `4sagA2Le4rx1m2` (`ottilie-pilot-sorfs-compare-seqera`,
launched via `tw launch yAMP-ottilie-test-az -p docker,ottilie_pilot_az` + the two-line params file per
the `18wEWW90THA2Ek` recipe): **307/307 tasks, 63 min**, outdir
`az://aletest/seqera-runs/yAMP-out-pilot-sorfs-compare-20260902`. **Local** `run_ottilie_pilot.sh`:
**315/315 tasks, 1h57m**, `output_ottilie_pilot_2026-09-02/` (local dir deleted 2026-09-10 — superseded by the 2026-09-08 re-cut comparison; this result stands). 146 Seqera deliverables compared
(mutation_reports, all VCFs, csv/, versions yml):

- **Every cohort table byte-identical**: `cn_cohort_*.csv`, `sv_cohort_matrix_*` (union + pass),
  `contig_copy_number.csv`, all per-sample pass_stats. All 16 igv-report HTMLs: identical `tableJson`.
- **Zero record-level VCF differences.** 40 VCFs differ in headers only (`##GATKCommandLine` /
  `##reference` / `##bcftools_*Command` work-dir paths; `##TIDDITcmd` `--threads 4` vs `2` — CPU
  count, not settings). 29 `.tbi` diffs are index binaries over proven-identical content.
- `SOR_FS_filter` present and identical both sides — SOR_FS (`4c45fb8`) is now **validated
  end-to-end on both execution paths**; the SPLIT/soft-filter/joint-Manta recipe reproduces on the
  re-registered entry (id `164422644302756`) with the trimmed schema and `joint_manta` default.
- Known classes, all expected: `versions.yml` `v1.0.0-gfedfab7` (clone) vs `v1.0.0` (local dir);
  csv manifests embed each side's outdir paths; `index.html` differs by generation timestamp.
- **Task delta 315 vs 307 = `--save_mapped`**, passed only by the local launcher (kept for
  `generate_test_data.sh --from-cram`): 4× `BAM_TO_CRAM_MAPPING` + 4× `INDEX_MERGE_BAM`,
  publish-only, zero analytic effect (also the two extra entries in the local versions yml).

### 2026-09-08 — ✅ Hard filter out of the recipe; entry re-registered (id `166797736834160`)

Launch-form batch D closed. `hard_filter_haplotypecaller_joint` left every ALE recipe (`4acec56`:
`ottilie_common.config`, the blob params file, the pilot/tier-2 launchers; the pipeline default was
already `false`) — the step only produced a per-sample VCF lineage the mutation report drops, at a
filter + SnpEff + stats task per sample. e2e re-recorded (175 → 159 tasks, only the `hard_filtered.*`
family moved). `custom_config_base` lost its schema default the same day (`4461f20`), closing the last
config-vs-schema default mismatch, so a Launchpad run no longer pulls nf-core's institutional configs
from GitHub while a local run does not (`azure_batch_execution.md` §13). Box regenerated with
`--generate` (the one diff: the hard-filter line gone) and the entry re-registered by
`14_register_pipeline.sh` after the push: **new pipeline id `166797736834160`** (replaces
`164422644302756` — id churn per the four-route table above). Readback all-green, engine pin `25.10.4`
preserved, box 13 keys. The next Launchpad run is the first cloud run without the hard filter and with
trimming on by default — it is the §A2 baseline re-cut, and its expected differences against the
2026-08-03 baseline are tabled in `output_comparison.md` §2.10.

### 2026-09-08 — ✅ BASELINE RE-CUT on the current recipe (run `2W0uOsPYt03NAL`) — cloud reproduces local

**The reference output set for local-vs-cloud comparison is now
`az://aletest/seqera-runs/yAMP-out-test-recut-20260908`** (replaces `ottilie-azurebatch-out/`, cut
2026-08-03 with no trimming and the hard filter on). Launched from the re-registered entry
(`166797736834160`) via `tw launch --params-file` = the box **minus `snpeff_cache`** (doubling as the
§13 acceptance test: 12 params submitted, no `snpeff_cache`/`custom_config_base` injected, profile's
`az://` cache path resolved), `-p docker,ottilie_test_az`, commit `bc31fd2`, engine 25.10.4.
**SUCCEEDED 159/159 tasks, 0 failed, 26 min** (15:05–15:32Z) — the same 159 the local e2e runs.

Compared 2026-09-09 against the local e2e output of the same commit range (`4acec56`'s re-record),
by the 3-tier method in `output_comparison.md` §3:

- **Tier 1 (names):** 569 blobs = 477 files + 85 `.azure_blob_dir` markers + 7 `pipeline_info/`;
  local 483 files. **Nothing on one side only** outside `pipeline_info/`.
- **Tier 2 (sizes):** 404/477 same size; 73 differ, every one in a known class.
- **Tier 3 (content):** 240 byte-identical, incl. **all 14 cohort tables** under `mutation_reports/data/`
  (the nine deliverables + `contig_copy_number.csv` + 4 `pass_stats.tsv`). **42/42 VCFs record-identical**
  (`bcftools view -H`), **10/10 igv-report `tableJson` identical**, **both CRAMs read-identical**
  (3,611,680 and 1,726,650 records; `samtools view -T <fasta>` — the cloud CRAM's embedded `UR:` is a
  Batch path, so without `-T` samtools decodes nothing and hashes empty output — a trap, not a diff).
  Remaining differences: timestamps (snpEff CSV `Date`, fastp `time used`, report `Generated`),
  embedded paths (`csv/*.csv`, `##reference`, `@RG DS`, MultiQC sources/log), gzip/tabix framing,
  MultiQC renders, `versions.yml` `-gbc31fd2`.
- **One new class found — MultiQC's SnpEff breakdown tables show the effect categories of whichever
  report was parsed LAST** (`snpeff_effects.txt`, `snpeff_variant_effects_region.txt`): the module resets
  its per-section totals at every file's section header, so the plotted category set is the last file's
  (Manta's on the Batch node, HaplotypeCaller's on ext4, TIDDIT's standalone); shared cells agree
  exactly and the general SnpEff table is cell-identical. Deterministic per filesystem (the exact local
  task re-run twice is byte-identical), different across them. MultiQC 1.25.1 bug, not ALE's; recorded
  as `output_comparison.md` §2.11 and a roadmap item to report upstream. Already excluded from the e2e
  snapshot (the `.nftignore` reason was wrong and is corrected).

The 4-sample pilot sensitivity re-check runs locally (`output_ottilie_pilot_2026-09-09/`); its result
goes to `04_validate/`, not here.

## GitHub PAT (retired 2026-10-26: no GitHub credential, the public repo clones anonymously)

> **Current state (2026-10-26): the workspace needs no GitHub credential.** `nnf-bright-biofoundry/ALE_Yeast`
> is public (since 2026-09-04), Platform clones a public pipeline over anonymous HTTPS, and a GitHub
> credential would only raise the launch form's GitHub API rate limit (anonymous: 60 requests per hour
> per Seqera egress IP, shared). Decided with the repo transfer: the token below is owner-scoped to
> `Aletechdev`, cannot be re-pointed, and has matched nothing since 2026-10-23; the run of 2026-10-26
> (`4tiNtBjO5ozg2y`) confirmed launches work without it. Consequences: no entry in
> `bin/check_credential_expiry.sh`, the 2027-07-24 calendar reminder was cancelled on 2026-10-26, and the
> org-owned GitHub App item is closed. **If the form ever fails with a GitHub rate-limit error**, the
> way back is a token whose resource owner is `nnf-bright-biofoundry` (the org must allow fine-grained
> PATs; deploy keys are disabled there and were never usable for a Platform pipeline anyway), registered
> with the recipe below and `--base-url https://github.com/nnf-bright-biofoundry/ALE_Yeast`, or an
> org-owned GitHub App. The credential `github_ALE_Yeast_finegrained` was **deleted from the workspace
> by the user on 2026-10-26** (read back: two credentials remain, `rgALE_batch_aledev4test` (`azure`,
> shared key, the older CEs) and `azure_SP_cfb_ale_mutations_pipeline` (`azure_entra`, the `yAMP` CE)).
> The token itself was revoked at `github.com/settings/tokens` by the user the same day. Nothing remains of it.

The record of the credential as it was in use (2026-08-07 → 2026-10-23), kept for the next person who
needs to register one:

| Seqera credential | Provider | Scope | Owner | Created | Expires |
|---|---|---|---|---|---|
| `github_ALE_Yeast_finegrained` (`2NhER3hJHchursPHekAV1P`) | `github` | **`Contents: Read` on `ALE_Yeast` only**, resource owner `Aletechdev` | **personal** account of the operator — GitHub user `zhliUU`, Seqera user `zhlia` | 2026-08-07 | 2027-08-07 (retired 2026-10-26 before expiry) |

**Registered `baseUrl` = `https://github.com/Aletechdev/ALE_Yeast`** — read back from the API, and
worth recording because it is **repo-level, not org-level**. That is the field Platform matches a
pipeline URL against, so this credential answers for *this repository only*; a second repo under
`Aletechdev` would need its own credential, which mirrors the token's own `Contents: Read on ALE_Yeast`
scope rather than fighting it. ⚠️ Earlier entries in this runbook show `--base-url
https://github.com/Aletechdev` (org-level) — that is what was typed for the **classic** PAT. Rotating
with the org-level form would register a *differently scoped* match than the credential in use, and if
both existed they would overlap on this repo — exactly the ambiguity warned about below.

> ⏰ ~~**Calendar reminder set for ~2027-07-24**~~ (cancelled 2026-10-26, no token to expire). The reasoning
> stays valid for any future token: this is a *shared org
> workspace* running on *one person's* personal token: when it lapses, every launch in the workspace
> fails with the opaque `Unknown pipeline repository or expired Git credentials`, and the person who
> can fix it may not be the person who hits it. This has already happened once here —
> `seqera-platform-ale-16april2026` expired unnoticed and cost a full debugging session. **A year of
> silence is exactly the condition under which that recurs.**

Re-registering or rotating it — run it yourself so the token never enters a transcript or shell history:

```bash
read -rsp 'GitHub token: ' GH_TOKEN && export GH_TOKEN
tw credentials add github -n github_ALE_Yeast_finegrained -w DTU-Biosustain/RECON-ALE \
    -u zhliUU -p "$GH_TOKEN" --base-url https://github.com/Aletechdev/ALE_Yeast
```

`-u` must be the GitHub account that **owns the token**, not the org and not the Seqera username.
Both values above reproduce the credential currently in use; verify after any change with
`GET /credentials?workspaceId=…`, which returns `baseUrl` and `keys.username` in clear (secrets read
back as `null`).

⚠️ **Add before deleting, and never leave two `github` credentials matching the same `--base-url`** —
which one Platform picks is undefined, so an overlapping pair makes any failure unattributable.

<details><summary>Retired — the classic PAT it replaced (2026-08-06 → 2026-08-07)</summary>

| Seqera credential | Provider | Owner | Created | Expiry (if never revoked) |
|---|---|---|---|---|
| `personal_token_classic_ALE_yeast` (`Z3yo4zFgy1xfdW0Ts11kI`) | `github` | **personal** account of the operator (Seqera user `zhlia`) | 2026-08-06 | 2026-11-04 (Wed) |

Scope: classic **`repo`**. ⚠️ This could not be narrowed — `repo` grants read *and write* on every
repository the owner can reach, so it was **strictly broader than the deploy key it replaced**. That is
a property of classic PATs, not a configuration mistake: GitHub provides no read-only scope for private
repositories. It was deliberately given a short 90-day expiry because it was always a stopgap; in the
event it was retired after **one day**.

Deleted from the `RECON-ALE` workspace on 2026-08-07. ⚠️ **Deleting the Seqera credential does not
revoke the token** — see the open item below.

</details>

## Open items

> 📋 **Slimmed 2026-08-13** (from ~1,440 lines: superseded sagas compressed, 💀 marks entries whose
> resources no longer exist, every ⚠️ and correction kept). The standing convention (`CLAUDE.md`'s):
> dated record here — *what was run, when, what was concluded* — durable rules in
> `azure_batch_execution.md`, summary + pointer in `CLAUDE.md`. Write new entries in that shape, keep
> corrections (so wrong conclusions are not re-derived), and after edits run
> `python docs/dev-practices/check_docs.py` — broken links must be 0.
> 📌 `NEXT_TASKS.md` (the 2026-08-07 handoff file) was **retired 2026-08-13**: its Task 1 (CE-as-code)
> was closed 2026-08-11, this banner absorbed Task 2 (doc slimming, executed the same day), and every
> remaining item it listed was already tracked in the list below.

- [x] Grant the two roles (`02_grant_roles.sh`) — done 2026-07-31, verified.
- [x] Create a client secret (`03_create_secret.sh`) — done 2026-07-31.
- [x] Verify both data planes (`05_verify_sp_access.sh`) — done 2026-07-31, all checks passed.
- [x] Register the Entra credential in Seqera via the web UI — done 2026-07-31, schema captured.
- [x] Create a new compute environment bound to the `azure_SP_cfb_ale_mutations_pipeline` credential,
      with `NXF_VER=25.10.4` pinned via the head-job environment (plan Phase 4) — done 2026-08-05,
      two CEs (non-Fusion + Fusion), both AVAILABLE. The six existing CEs were not repointed.
- [x] Add `outdir` to `conf/params_ottilie_test_blob.yml` — done 2026-08-05, date-stamped, preview-verified.
- [x] Create a classic GitHub PAT and register it in `RECON-ALE` — done 2026-08-06,
      `personal_token_classic_ALE_yeast`; the repo clones over HTTPS. **Superseded 2026-08-07.**
- [x] Register the Launchpad pipeline — `yAMP-ottilie-test` (`227651105760023`), done 2026-08-06.
- [x] Chase the **fine-grained PAT** approval — **approved and swapped in 2026-08-07**, ~1 day after
      submission. Credential `github_ALE_Yeast_finegrained`; the classic credential was deleted from the
      workspace and the new one is **confirmed in live use** — opening the Launchpad form advances its
      `lastUsed` on demand (see the entry above).
- [x] Record the current PAT's owner and expiry — done: expires **2027-08-07**, see the table above.
- [x] **Revoke the retired classic token at `github.com/settings/tokens`** — done 2026-08-07. Deleting
      the Seqera credential only stopped Platform using it; revoking at GitHub is what actually retires
      the `repo` read+write reach. Both halves are now complete, so the switch's security benefit is
      banked rather than merely intended.
- [x] Delete the unused `github_ALE_Yeast_deploykey` (`ssh`) credential from `RECON-ALE` — done
      2026-08-07, verified by readback (three credentials remain: `github`, `azure_entra`, `azure`).
      The keypair itself is untouched and stays usable for local/CI clones; only the Platform-side
      registration was removed.
- [x] ⏰ ~~Calendar reminder for **~2027-07-24**~~ cancelled 2026-10-26 (no token to expire) — **set 2026-08-07**
      by the operator. ~~2026-10-21~~ — obsolete, that was the classic token's date. ⚠️ The reminder
      lives in *one person's* calendar, which is the same single-point dependency as the token itself;
      it fires two weeks early because re-issuing a fine-grained PAT on an org-owned repo needs a fresh
      org-owner approval, empirically ~1 day.
- [ ] 📌 **(optional, when a citable pilot artifact is needed)** Validation-grade cloud pilot run,
      lightweight form: one clean run from `yAMP-ottilie-test-az` with `-p docker,ottilie_pilot_az`
      (plus the pilot `snpeff_cache` path per the params-box comment), **no probe**, fresh outdir —
      then a **truth-set spot-check** (the known ottilie mutations present in the cohort
      deliverables), *not* a byte comparison against the months-old local pilot (different tool set,
      older commit — reconciling would cost more than it proves; decided 2026-08-13). Until then the
      pilot's cloud viability rests on `18wEWW90THA2Ek` (310/310, diagnostic).
- [x] 🔁 ~~**Swap to an org-owned GitHub App** when an org owner is available~~ **Closed 2026-10-26 by
      dropping the GitHub credential altogether** (section above; entry of 2026-10-26, later). History:
      still the durable answer *if* a credential is ever needed again.
      The fine-grained PAT closed the *blast-radius* half of the problem (`Contents: Read` on one repo,
      not `repo` on everything) but **not** the *person-tied* half: a shared org workspace still depends
      on one person's token, now expiring 2027-08-07 instead of 2026-11-04.
      **2026-10-09:** the repository has been public since 2026-09-04, which opens a third option: no
      GitHub credential at all. Platform launches a public pipeline from its URL and a credential only
      raises the GitHub API rate limit (Seqera Git docs); the `yAMP` entry binds no GitHub credential,
      so dropping it needs no re-registration. Keep-or-drop trade-off and the drop recipe:
      [`roadmap.md` → Deployment](../../../docs/dev-practices/roadmap.md#deployment--seqera-launch-ui--schema).
- [x] `tw launch` (plan Phase 6) and compare outputs against the local-head-job baseline — **done
      2026-08-06**: `3C5zYMYY5M32dO` SUCCEEDED, 170/170 tasks, 9/9 cohort deliverables byte-identical.
- [x] Point the `yAMP-ottilie-test` Launchpad entry at `ale-ottilie-nf25104-bigdisk` — done 2026-08-07,
      verified by readback (`computeEnvId 6buIkRXLMZFgDXs5NkyuH`).
- [x] Retire the superseded CEs — **disabled** 2026-08-07 (`ale-ottilie-nf25104`, the original
      single-pool `…-fusion`). Delete them once no run history needs them; disabling already prevents
      accidental use.
- [x] Re-forge the Fusion CE with the §9–§10 fixes — done 2026-08-07,
      `ale-ottilie-nf25104-bigdisk_fusion` (`5acBaUVwry7j0DJmLnwyh0`), AVAILABLE.
- [x] Confirm the same-container rule under a **Platform** head job — done 2026-08-07, run
      `48kJmc9QY6Q3h9`: 0/6 tasks, `Unable to download path` in `.command.log`. See the entry above.
- [x] **Does the pipeline still work under Fusion?** — done 2026-08-07, run `XFwlgZnKvUvpu`: 170/170,
      0 `DiskFull`, all nine cohort deliverables byte-identical to `seqera-runs/2026-08-06-04`. See the
      entry above.
- [x] 🧊 **Fusion cache footprint on the OS disk** — **measured 2026-08-13: ≲3 G at test-set scale.**
      Run `47xZrJ3vg4avR9` executed the recipe as written (fresh cold Fusion CE, same-container,
      probe attached); peak `root:` 63.0 G vs the non-Fusion cold expectation of ~60 G with the same
      image set. Disk sizing conclusions unchanged; the `/mnt` relocation stays parked. Full census
      + caveats in the dated entry.
- [x] **Does Fusion lift the same-container rule?** — **answered 2026-08-13: NO.** Run
      `3AJ4JRNkb7D2dG` repeated the `48kJmc9QY6Q3h9` launch on a fresh Fusion CE and failed
      identically (0/6, same six tasks); `.fusion.log` shows the container-scoped SAS being rejected
      with a 403 against `aletest`. The rule tracks the **credential delegation**, indifferent to the
      data path. See the 2026-08-13 entry.
- [x] **`outdir` in a different container under a Platform head job** — **proven 2026-08-13 for
      `publishDir` writes**: the same run published `pipeline_info/` into `aletest` while `workDir`
      sat in `debugging`. Task-output publishing uses the same head-side mechanism; an end-to-end
      demonstration by a successful cross-container run has not happened (and cannot, given the rule
      above blocks task *reads* — the only way to see it would be inputs+workDir together in one
      container and `outdir` in another).
- [x] 📏 **Measure actual node disk usage** — done 2026-08-07: **peak 65.2 G of 246.9 G (26%)**.
      ⚠️ Measured on **warm** nodes (already ~340 tasks across two runs), so it is a multi-run
      accumulation, and the base-OS vs pipeline-image split is **still unknown**. → split settled by
      the cold-pool baseline below.
- [x] 🧊 **Cold-pool disk baseline — DONE 2026-08-13**, run `18wEWW90THA2Ek` on the full-depth pilot
      (310/310 tasks), executed exactly as the 2026-08-12 spec (fresh CE via
      `13_create_compute_env.sh`, `-p docker,ottilie_pilot_az --config conf/disk_probe.config`,
      fresh outdir + workDir, `-resume` forfeited deliberately). **Cold base 45.4–45.5 G; peak
      60.0 G; pipeline images + writable layers ≈ 15 G; task-scratch disk ≤ 2.7 G.** Images
      dominate — 11× the data did not move `/` usage; **128 GB would suffice**. Numbers + what
      remains open (Fusion's `/mnt` cache):
      [`azure_batch_execution.md` §9 → cold-pool baseline](../../../docs/dev-practices/azure_batch_execution.md),
      and the dated entry above.
- [ ] Repoint `yAMP-ottilie-test` at `…_autoScale_manual_noFusion`, then **delete both fixed-size CEs**
      (`ale-ottilie-nf25104-bigdisk`, `…-bigdisk_fusion`) — deletion disposes their pools and disks.
- [ ] Move Docker's data-root to `/mnt` via a pool start task (needs a `manual` CE) — the better fix
      than a larger OS disk; see the note above. ✅ **Unblocked 2026-08-13**: the cold-pool baseline
      measured the image set at ~15 G and task scratch at ≤ 2.7 G, so the 150 GB ephemeral disk has
      ample headroom. Still open: whether Fusion's cache would compete for `/mnt` (unmeasurable from
      inside a container — see the §9 probe caveat). 📌 **Deliberately parked, not queued** (decided
      2026-08-13): at 4 autoscaling workers the managed-disk cost is cents per run, while a manual CE
      means taking pool lifecycle, the image pin and `azcopy` back from Forge. Interim: attach
      `conf/disk_probe.config` to Fusion dev runs and to the first run after adding a tool — the
      `root:` line shows both Fusion cache pressure and image-set creep. Revisit if the image set
      nears ~100 G, worker counts scale well past 4, or Fusion becomes the default.
- [x] GitHub auth decided and keypair generated (`07_github_deploy_key.sh`) — the pre-existing
      `github_Aletechdev` credential had in fact expired. ⚠️ **That script was deleted 2026-08-07**
      (obsolete route; see the entry above) — the numbered sequence skips 07 by design.
- [x] Deploy key registered on the repo and as a Seqera `ssh` credential; auth + read access verified.
      ⚠️ **The Seqera-side registration was deleted 2026-08-07** (Platform cannot use it for a pipeline
      repo — 2026-08-05). The keypair on the repo is untouched and stays usable for local/CI clones.
- [x] ~~Use the SSH form `git@github.com:Aletechdev/ALE_Yeast.git` in every launch~~ — **dropped
      2026-08-07.** Launches go through the **`yAMP-ottilie-test` Launchpad entry** (`tw launch
      yAMP-ottilie-test -w DTU-Biosustain/RECON-ALE …`), which carries the HTTPS repo URL and resolves
      the `github` credential itself — so no launch names a Git URL at all. The SSH route is closed, not
      pending.
- [ ] ⚠️ **Push before every launch — a standing check, not a one-off.** Seqera clones from GitHub, so
      anything unpushed does not exist for a cloud run: a run against `--revision main` silently uses
      whatever `origin/main` holds, and the failure mode is a *successful* run of stale code rather than
      an error. Confirm `git status` is clean and `main` is level with `origin/main` first. ⚠️ Launching
      a **tag** is not a way around this — a tag pins whatever it pointed at, which is how
      `--revision v1.0.0` came to lack the cloud-portability fixes.
- [ ] 🔬 **Re-test Platform resume — the 2026-08-07 attempt was inconclusive, not negative.** The UI's
      Resume toggle *does* work at the API level: relaunch `5Ped8HWvzzjoDx` recorded `resume: true` with
      the **original** `sessionId` (`128211f9-…`, from the successful `3C5zYMYY5M32dO`) and
      `resumeDir: az://aletest/nf-work-04`. But it re-ran from the start — **`cached=0`** at 64 tasks.
      **Do not conclude resume is broken**: the test was confounded. `wBQPdPBbfyZAH` — a *non*-resume
      relaunch (`resume: false`, new session) — was executing **concurrently into the same work dir**,
      rewriting the very task directories the resuming run needed. Nextflow re-runs a task whose work
      dir is incomplete or altered, which is exactly what it would have found.
      **Retest cleanly, after the local clean run + comparison against the latest pipeline**, and change
      one thing at a time:
      1. Nothing else running against that work dir.
      2. Keep `outdir` **identical** to the run being resumed — it differed here
         (`2026-08-06-04` → `2026-08-07-01`), and whether `outdir` perturbs task hashes is unverified.
      3. Same revision/commit — ✅ **already ruled out as a cause.** The resumed run pinned
         `commitId 86c4672`, identical to the original, even though `main` had moved four commits on.
         Platform honours `resumeCommitId`, so a moving branch does **not** break resume.
      Expect ~170 `cached` and a couple of minutes' wall clock. If `cached=0` persists under those
      conditions, the likely cause is that Platform does not persist Nextflow's **cache DB** — the
      `stage-<sessionId>` directory in the work dir is a *staging* area, and it has not been confirmed
      to contain the hash→result mapping resume actually needs.
- [x] Rename the app registration to match its new purpose — **done 2026-08-13**:
      `cfb_ale_mutations_pipeline` → `sp-bright-recon-ale-mutations-pipeline-seqera-deploy` (see the
      📛 note in *Context* above). Verified: the rename propagated to the SP object, exactly one SP
      matches the new name, and `SP_DISPLAY_NAME` in `00_vars.sh` was updated in the same commit.
      The operator is an app **owner** (with pasdom@dtu.dk, phaneuf@dtu.dk), so no admin was needed.
      Seqera credential name deliberately kept — binds by clientId.
- [x] Rotate the exposed secret on `sp-bright-recon-ale-mutations-pipeline` — **done 2026-08-14, all
      five steps.** New secret `rotated-2026-08` (key id `0026e21c…`) minted by the operator with the
      parameterized `03_create_secret.sh`, swapped into the ALE-mutations service and tested; the
      exposed 2026-06-03 secret (key id `8af5a144…`) then **deleted** — verified: the app now holds
      exactly one credential, expiring **2027-08-14**, which
      [`bin/check_credential_expiry.sh`](../../../bin/check_credential_expiry.sh) now tracks with the
      standard 60-day lead (the every-session nag is retired). Original scoping kept below for the
      record:
- [x] ~~(scoping)~~ Rotate the exposed secret on `sp-bright-recon-ale-mutations-pipeline` (the *other* SP — the
      sibling serving the migrated ALE-mutations service, `Contributor` on Batch `ale` + `Reader` on
      `ensembleamp`). Its secret sat in plaintext in `tmp/azure/azure_sp/.azure_sp.env` from
      ~2026-06-03 until the file was deleted 2026-08-13. **Scoping done 2026-08-13**: never committed
      (verified — no commit in history touched `tmp/` or any `azure_sp` path), never left this VM, so
      this is hygiene, not incident response. The SP holds exactly **one** secret (created 2026-06-03,
      **expires 2026-11-02**), i.e. the exposed value is the live one. **Decision: live-swap; operator
      will run it later.** Recipe — typed in the operator's own terminal, never through an agent/`tee`
      (the secret prints to stdout):
      1. `APP=$(az ad sp list --display-name sp-bright-recon-ale-mutations-pipeline --query "[0].appId" -o tsv)`
      2. `az ad app credential list --id "$APP" -o table` — note the old `keyId`.
      3. `az ad app credential reset --id "$APP" --append --years 1 --query password -o tsv` —
         `--append` keeps the old secret working, so the service keeps running.
         📌 Steps 1–3 also exist as a guarded script (TTY check, confirmation, keeps existing
         creds): `SP_DISPLAY_NAME=sp-bright-recon-ale-mutations-pipeline SECRET_LABEL=rotated-2026-08
         ./03_create_secret.sh` — still typed in your own terminal, never through an agent.
      4. Swap the new value into the ALE-mutations service's config (off this machine) and verify it.
      5. `az ad app credential delete --id "$APP" --key-id <old keyId>` — this step is the actual
         revocation; until it runs, the rotation is not complete.
      ⚠️ The app is co-owned with pasdom@dtu.dk and phaneuf@dtu.dk — coordinate before step 5.
      ⏰ Backstop: the exposed secret self-expires **2026-11-02** even if rotation slips.
- [ ] 🚨 **Make something reap a hung head job.** `jobMaxWallClockTime: "7d"` in
      `ce_import_template.json` does **not** apply — Azure reported `TimeSpan.MaxValue` on
      `nf-workflow-1XuapND2cN2oCO` (2026-08-13), so a head job that hangs after completing holds its
      node until a human notices; the head pool cannot scale to 0 while a task is `running`. Options:
      find where the setting is actually honoured (job vs task constraints), set
      `constraints.maxWallClockTime` on the Batch job directly, or add a cheap post-run check. Until
      then: **after any run that ends in a non-terminal state, check
      `az batch pool list --query "[?contains(id,'<ce-id>')].[id,currentDedicatedNodes]" -o tsv`.**
- [x] Delete the six DISABLED compute environments — **done 2026-08-13**, including both **fixed-size**
      ones (`ale-ottilie-nf25104-bigdisk`, `…-bigdisk_fusion`) from the 2026-08-07 cost incident. All
      were at 0 nodes first; deletion disposed their pools and disks.
      **`yAMP-ce-nofusion-256` (`4xdBRYm1K1rbql3g5CgnSg`) is now the only compute environment.**
      Checked first that no Launchpad entry depended on them — `ALE-Yeast-aledev4test` and
      `ALE_Sarek_dev` already pointed at previously-deleted CEs.
      📌 The two Azure pools with no CE behind them were **also deleted** (2026-08-13), for a clean
      starting point: `nf-pool-21b27…-Standard_E4ds_v4` — a Nextflow **auto-pool** from *local*
      head-job runs, which no CE owns and CE deletion therefore never touches — and
      `tower-pool-4bPUf5SLRHx9gllkj29reo`, orphan of an earlier deletion. Both were at 0 nodes and free.
      ⚠️ This gives up `-resume` on the affected local runs (§2: a resumed run asks for its pool by id
      and fails with *"not in active state"*). Accepted deliberately — those runs are short enough to
      redo. Note the auto-pool is **not** permanently lost: its id is a hash of the pool spec, so the
      next local Batch run with the same `conf/azure_batch.config` recreates the identical id.
      **The Batch account now holds only `yAMP-ce-nofusion-256`'s two pools.**
      ⚠️ `yAMP-ce-nofusion-256` is **warm** after run `1XuapND2cN2oCO`, so the cold-pool disk baseline
      still needs a freshly forged CE — not this one. ✅ Done exactly that way later the same day:
      `yAMP-ce-coldprobe-256`, forged for run `18wEWW90THA2Ek` and deleted after harvest (see the
      cold-pool baseline entry above), leaving the account again with only the keeper's two pools.

### 2026-09-11 — ✅ Idle-state cost audit: nothing always on

Prompted by the portal's "Dedicated Core Count (Avg)" chart showing a non-zero dashed line for
`aledev4test`. Three checks, all clean: `12_verify_compute_env.sh` → `autoScale True True`; both
`tower-pool-4xdBRYm1K1rbql3g5CgnSg-{head,worker}` at 0 nodes, autoscale on, no active jobs;
`11_check_cost.sh` → 33 DKK over 30 days, entirely on the four run days. The portal line is Azure
Monitor bridging a *sparse* metric (Batch emits `CoreCount` only while nodes exist) with a dashed
segment, and averaging only the existing samples. The two pools are the CE's own, forged at
creation, free at 0 nodes. Residual risks (hung head job, 7-day worker cap, work-dir growth) and the
three-command audit are now in
[`azure_batch_execution.md` §8.1](../../../docs/dev-practices/azure_batch_execution.md).

### 2026-09-11 — ✅ ALE-specific `tower.yml` verified on Platform (run `5s5ufIqc8nWdNn`)

Sarek's inherited `tower.yml` filled the run's *Outputs* tab with per-sample mosdepth / bcftools-stats /
snpEff txt tables and the MultiQC report twice, and never listed `mutation_reports/`. Replaced in
`db94fe3` with eight patterns: index, cohort report, `samples/*_report.html`, the three cohort CSVs,
`multiqc/multiqc_report.html`. Launched the test entry (`tw launch --params-file`, box minus
`snpeff_cache`, outdir `az://aletest/seqera-runs/yAMP-out-test-toweryml-20260911`): **SUCCEEDED
150/150 tasks, 0 failed, 27 min** (11:29–11:56Z), commit `db94fe3`. 150 not 159 because `153be06`
removed the nine `TABIX_TABIX` tasks (local snapshot re-recorded then). `GET /workflow/<id>/reports`
returned exactly **14 entries** — the 8 patterns, each per-sample report auto-suffixed with its
filename — no txt, one MultiQC, every file < 10 MB on the test set so all preview. Browser check
(user, same day): per-sample IGV reports render — igv.js / Tabulator load from their CDNs — **and the
index's relative links resolve inside the preview**, so the tab navigates like a local copy. That
disproves the earlier assumption (stated in the plan and briefly in the README) that each report is
served in isolation; corrected the same day. Zip-the-folder was rejected before running: the pilot's `mutation_reports/` is 137 MB against
a 25 MB download cap, and igv-reports embed base64 alignments so it would not compress.

### 2026-09-14 — ✅ Seqera token: one file, one script, auto-exported (token only)

A session spent four probes finding the Tower token because nothing pointed at
`~/.config/ale-seqera/sp.env` (the tw skill named a worktree `.env` that no longer exists; the
new-machine doc and CLAUDE.md never mentioned the file). Fixed in three places: `10_store_secret.sh`
now prompts for BOTH secrets (Enter keeps the existing value, so rotating one never re-asks the other);
`~/.bashrc` on the dev VM exports **only** `TOWER_ACCESS_TOKEN`/`SEQERA_ACCESS_TOKEN` into every shell,
placed above the interactive guard so agent/IDE shells get it too (the SP secret stays on-demand via
`00_vars.sh`, by decision); the tw skill, CLAUDE.md and `new_machine_setup.md` §9 all name the file and
the snippet. Verified: fresh `bash -l` → token 76 chars, SP secret unset, `tw info` answers. A shell
started before the edit (this session's) does not see it — restart the shell or export inline.

### 2026-09-14 — ✅ Outputs tab reordered + relabelled (`tower.yml`; run `3AqxTildpQMIE3`)

On run `3BOrydQ9kJrgaH` the *Outputs* tab listed the 14 entries **sorted by display label** (Cohort…,
Copy-number…, MultiQC…, Mutation report dashboard…, Per-contig…, Per-sample…, SV…), so the index sat
fourth and the two CN tables were split. The Platform docs (`reports/overview`) do not document a sort,
so the fix does not depend on one: every label now starts with a number. New order — 1 index (*Start
here*), 2 SNV & InDel report (all samples), 3 SV table, 4 CN windows table, 5 contig copy-number table,
6 MultiQC, 7 per-sample IGV reports (auto-suffixed per file). Labels also drop "cohort" for "all
samples", matching the dashboard's own section headings ("All Samples: …"); no file or path changed, so
the patterns and the 14-entry count are the same. **To verify:** launch the test entry as on 2026-09-11
and confirm the tab reads 1→7 and that `GET /workflow/<id>/reports` still returns 14 entries.
**Done the same day:** test entry, `tw launch --params-file` (box minus `snpeff_cache`), run
`yAMP-out-test-tabordering-20260914` → **SUCCEEDED 150/150, 0 failed, 25 min** (10:20–10:45Z), commit
`7de1fbe`, outdir `az://aletest/seqera-runs/yAMP-out-test-tabordering-20260914`. `GET /workflow/<id>/reports`:
**14 entries**, every label numbered as intended, every file < 10 MB (largest: MultiQC 5.0 MB, per-sample
HC reports 2.9–3.4 MB), the seven per-sample reports auto-suffixed with their filenames. The API returns
the list in arbitrary order (5, 4, 7…, 3, 2, 6, 1), confirming the tab's order is a client-side sort —
which is exactly why the numbers live in the labels. Browser check of the 1→7 reading order: user.

### 2026-09-11 — ✅ Dashboard header names the complete-output folder (run `3BOrydQ9kJrgaH`)

`fe055a1`: `mutation_reports/index.html` prints "Complete output: `<outdir>`" (string-resolved, no
`file()` — a cloud outdir needs no credentials at DAG-build time). Test entry, `tw launch
--params-file`, run **named after its outdir** (`yAMP-out-test-outdirhdr-20260911`; a `tw launch`
habit only — the Platform launch form auto-names runs): **SUCCEEDED 150/150, 0 failed, 24 min**
(14:54–15:18Z). Published index header reads
`az://aletest/seqera-runs/yAMP-out-test-outdirhdr-20260911`; Outputs tab unchanged at 14 entries,
0 txt. Local e2e (779 s, snapshot unchanged) had already shown the absolute-path form.

### 2026-09-28 — ✅ QC-first pair on Platform (runs `5m9NorL3JmkHFq` → `464Scp5QNoznbD`): first cloud `PREFLIGHT_REFERENCE` and MultiQC 1.35; Outputs entry for the QC-only report (run `1DtqOzNj59CITv`)

Entry `166797736834160` unchanged: `--generate` produced an identical box and the live readback
equalled it, so no re-registration — the id survives. Commit `e761f66`, engine 25.10.4, CE
`yAMP-ce-nofusion-256`.

**Run 1, QC-only** — `15_launch_run.sh --set outdir=az://aletest/seqera-runs/yAMP-qc-first-20260928
--set qc_only=true` (params = the box + the two overrides; `tw launch --params-file` replaces the
box). Submitted 18:14:22Z, RUNNING 18:24:53 (head-pool cold start 10.5 min), SUCCEEDED 18:35:59;
12.2 min wall, est. $0.05. Downloaded and checked against `tests/qc_gate.sh` part (a): 18 tasks,
exactly the 15 allow-listed processes, `multiqc/yAMP-QC-only-run_multiqc_report.html`, preflight row
OK with the 13-contig note, 4 post-trim FastQC zips, 187 files.

**Run 2, Resume** — `15_launch_run.sh --resume 5m9NorL3JmkHFq --set outdir=<the same>` =
`tw runs relaunch` (session `834a93c6…` kept, commit pinned `-r e761f66…`, profiles kept, params
replaced by the box + outdir, no `qc_only`). Submitted 18:36:59, RUNNING 18:39:00 (warm head node,
2 min). Head-job log: `Pipeline completed successfully` at 19:07:37 — 136 succeeded, **17 cached**,
0 failed = 153 tasks. Part (b) of the gate applied to the downloaded outdir against the local e2e
output of the same commit: (b1) every run-1 task except MULTIQC CACHED; (b2) task list == the local
e2e's 153; (b3) `qc_gate_compare.py`: 530 names equal, 145 snapshot files md5-identical, 42/42 VCFs
record-identical. **Cloud reproduces local; the QC-first pair equals a one-shot run on Platform.**
Names vs the 2026-09-08 baseline: 270 only in run 2 = the 157 files of run 1's QC-only MultiQC folder
+ the 113 dated in `output_comparison.md` §2.10 (rows 09-09, 09-23, 09-24, 09-28 — the first three
added today from the same comparison); 60 only in the baseline, all dated. Est. $0.14.

**Platform lost run 2 (`azure_batch_execution.md` §15, second occurrence).** Tower-client HTTP
retries at 18:51–18:52, status UNKNOWN from 19:00 while the workflow kept completing tasks and
publishing; after the trace was saved at 19:07:40 the head job hung — stuck posting the terminal
status (log ends there, Batch task `running` afterwards). Decided from the head log + outdir, never
the status. `16_watch_run.sh` now treats UNKNOWN as a grace period with the two authoritative
commands. Trap recorded in §15: `az batch task file download` refuses an existing destination
(`ERROR: File … already exists`, exit 2) — a poll loop that discards stderr reads a stale log. Disposition: still `running` at 19:32Z, 25 min after completion, Platform still UNKNOWN → stopped on Batch at 19:34:00Z (`az batch task stop` — this CLI has no `terminate`; Batch reports state `completed`, exit code 137, result `failure`, ended 19:33:59Z) so the head node can drain; Platform keeps **UNKNOWN**, the honest record for a verified-successful run (`tw runs cancel` would have stamped CANCELLED, §15).

**Outputs tab.** Run 1's was empty: every `tower.yml` pattern names a full-run deliverable and the
QC-only report has its own file name. `702a4c0` adds the pattern (label `6b.`); verified on run 3
`1DtqOzNj59CITv` — QC-only on `702a4c0`, launched while run 2 ran (the head node has **2 task
slots**, so two head jobs run side by side), SUCCEEDED 19:02:50, 8.5 min on warm pools, $0.04, part
(a) contract passes again: `GET /workflow/<id>/reports` → 1 entry (`6b. …`), run 1 → 0.

**Pool facts read from Batch:** autoscale evaluates every 5 min and halves the count when idle → head
pool (D2s_v3, max 1 node, 2 slots) gone within ~5 min of idle, worker (E4ds_v4, max 4) within ~15;
a QC-only run launched ~15 min ahead pre-warms both for a demo. Platform lists 115 processes for a
QC-only and a full run alike (the registered DAG); 15 vs 61 carry tasks.

**New scripts, validated by use:** `15_launch_run.sh` (runs 2 and 3), `16_watch_run.sh` (runs 2
and 3, incl. the UNKNOWN branch on run 2), `17_download_outdir.sh` (every download today — the az
CLI user login had expired under the 14-day policy mid-session; the script reads with the pipeline's
SP via azcopy and touches no CLI login state).

### 2026-09-29 — ✅ The Outputs tab fills while the run is going (run `5CiOiON5oJuETn`)

Question before building the early MultiQC reports: does Platform list a `tower.yml` match while the
run is RUNNING, or only at completion? Seqera's docs are silent and nf-core's say "after the pipeline
has completed". The plugin says during: `TowerReports.groovy` (Nextflow v25.10.4 = nf-tower 1.17.5)
appends each matching publish to `nf-<id>-reports.tsv` and, when the launch dir is not the work dir,
copies it to the work dir at most once a minute from a timer.

Run: an ordinary one-shot test-set run of the Launchpad entry at `702a4c0` (GitHub `main`; the one
local-only commit, `8b83da4`, was docs + scripts), launched with `tw launch … --params-file <box +
outdir>` rather than `15_launch_run.sh`, which refuses while local `main` is ahead. Outdir
`az://aletest/seqera-runs/yAMP-live-outputs-20260929` (disposable). Polled `GET /workflow/<id>` and
`GET /workflow/<id>/reports` every 30 s.

Submitted 09:22:33Z, RUNNING 09:28:43 (cold head pool, 6 min), SUCCEEDED 09:54:18 — 153/153 tasks,
25.6 min. The list grew **while RUNNING**: 1 entry at 09:43:12 (*5.*, contig copy number), then 4 → 7
→ 8 → 9 → 10 → 12 by 09:53:28; 14 at SUCCEEDED (*1.* index and *6.* MultiQC, published last). Lag
from task completion to first listed: *5.* 44 s, *4.* 18 s, *3.* 71 s, *2.* 29 s — the one-minute
sync plus the 30-s poll. MultiQC completed 09:53:28 and was listed only with SUCCEEDED (inside one
sync period of the end). From the tasks API: read QC (FastQC, fastp) complete 8.9 min into RUNNING,
alignment QC (duplicate metrics, samtools stats, mosdepth) at 12.2 min — so MultiQC reports built at
those two points could be listed ~17 and ~13 min before the end of this run. Written up in `azure_batch_execution.md` → Outputs tab.

### 2026-09-29 — ✅ Three MultiQC reports on Platform: read-QC and alignment-QC listed while RUNNING (run `Wxgvs037pXLV8`)

First Platform run of `82fa664` (three MultiQC reports + the *yAMP input checks* table): one-shot
test-set run from the Launchpad entry (`15_launch_run.sh`, box + outdir
`az://aletest/seqera-runs/yAMP-staged-mqc-20260929`, disposable), polled every 30 s as on run
`5CiOiON5oJuETn`. Submitted 11:54Z, RUNNING 12:05:09 (cold head pool), SUCCEEDED 12:29:15 — 155/155
tasks, 24.1 min.

| Entry | Task completed | First listed (30-s poll) | Into RUNNING | Before the end |
|---|---|---|---|---|
| *6a* MultiQC read-QC | 12:13:35 | 12:14:18 | 9.2 min | 15.0 min |
| *6b* MultiQC alignment-QC | 12:21:25 | 12:21:55 | 16.8 min | 7.3 min |
| *6* MultiQC complete-QC | 12:28:25 | 12:29:01 (still RUNNING) | 23.9 min | 0.2 min |

*6a* was the first entry of the run, 4.6 min before any dashboard file (*5.* at 12:18:52); 16 entries
at SUCCEEDED (14 + the two early reports). Report sizes 2.68 / 2.83 / 3.03 MB — all previewable
(< 10 MB). The estimate from run `5CiOiON5oJuETn` (~17 / ~13 min before the end, from input
completion times) held for read-QC and was optimistic for alignment-QC: its inputs completed 11 min
before the end here and the task then queued 49 s for a slot (submit 12:18:16, start 12:19:05; MultiQC
itself 21 s). Unlike the morning run, the complete report — published in the run's last minute — was
listed before SUCCEEDED: whether a last-minute file makes it depends on where the plugin's one-minute
timer is. `reports/preflight/` downloaded (`17_download_outdir.sh`): both tables md5-identical to the
local e2e snapshot of the same commit (`preflight_samplesheet_params_mqc.tsv` 615c0f7c…,
`preflight_reference_mqc.tsv` 65b33526…) — the DAG-build table's `collectFile(storeDir: az://…)` works
on Batch. Finding: all three MultiQC tasks ran with 4 CPUs / 12 GB — `base.config`'s
`withName: 'MULTIQC'` reaches the aliases (Nextflow applies base-name selectors, then alias, then
fully-qualified — `ProcessConfigBuilder.applyConfig`, v25.10.4), not `process_single` as first written.
The alignment-QC task's 49-s wait was that 4-CPU request queueing for a whole free slot; since this
entry the two early reports request 1 CPU / 6 GB (`conf/base.config`).

### 2026-09-30 — ⚠️ Outputs-tab preview: links to pages work, file downloads are blocked (sandboxed viewer); the content cookie is scoped to the report's folder

Seen by the user on run `Wxgvs037pXLV8`: from the previewed index, the SNV card opened
`cohort_report.html`, but the CSV / VCF download buttons did nothing. Probed from the dev VM with
the API token (read-only):

- `GET /workflow/<id>/reports?workspaceId=…` → 16 entries, `basePath
  /content/redirect/reports/wsp/<ws>/<run>/`, each `path` = `<n>/<file>` (`15/index.html`). The
  redirect endpoint 307s **any** path under it to a signed `user-data.cloud.seqera.io/content/download/
  reports/…/<n>/<path>?token=` URL — a nonexistent file comes back 200 with 0 bytes, so the tab's
  "View" is a plain proxy onto the report's folder in blob.
- Serving `15/index.html` with the token sets `CONTENT_TOKEN` (`Max-Age=3600`,
  `Path=/content/download/reports/wsp/<ws>/<run>/15`, HttpOnly, SameSite=Strict). With that cookie
  alone — what a browser sends when it follows a relative link — `cohort_report.html`,
  `samples/*.html`, `data/*.csv`, `data/*.vcf.gz` and `vcf/haplotypecaller/*.vcf.gz` all return 200,
  **registered in `tower.yml` or not**. `15/../multiqc/multiqc_report.html` returns 401: outside the
  cookie path. So the server serves everything under the bundle and nothing beside it.
- The front-end (`chunk-IH47IZNG.js`, `data-cy="html-viewer"`) renders a report in
  `<iframe sandbox="allow-scripts allow-popups allow-forms">` — no `allow-downloads`. Browsers block
  every download started inside such a frame (by `download` attribute or by navigating to a
  non-renderable type), silently, and pop-ups inherit the sandbox, so `target="_blank"` does not
  escape it either. Reproduced with headless Chromium: the same sandbox flags around the pilot index,
  a click on the VCF button → no download event, no error.

Done the same day (committed with the dashboard batch): every file the index offers for download is
now its own `tower.yml` entry (2b/2c SNV & InDel CSV + VCF, 3b SV VCF, 4b uncollapsed CN) so the
tab's own Download button serves it; the index detects being framed, says so beside each download
row (right-click → *Open link in new tab* works: a browser-opened tab is not sandboxed and the cookie
is sent — verified with Playwright against the live run for the SV VCF, the SV CSV and the cohort VCF,
and a button click in the preview opened as its own top-level tab downloads too) and hides the
browser-generated "rows shown" export. **To verify on the next Platform run:**
the `.vcf.gz` entries are listed and downloadable (mime type is deduced from the extension; the docs
list only html/csv/tsv/pdf/txt as *renderable*). Consequence for the index's planned links to the two
early MultiQC reports: relative `../multiqc/` links are dead in the preview, so those reports must be
co-published into `mutation_reports/` if the index is to link them.

### 2026-10-01 — ⚠️ A worker task sat `running` for 29.5 min without starting (run `4xHktQIoVD1t3Z`, cancelled); head-job environment names read

2-sample test set from commit `f6f2f94` (`15_launch_run.sh --name yAMP-index-offline-20261001`, outdir
`az://aletest/seqera-runs/yAMP-index-offline-20261001`, disposable and incomplete). Launched to look
at the new mutation report index on Platform; it never got that far.

| UTC | Event |
|---|---|
| 08:57:30 | SUBMITTED |
| 09:08:34 | RUNNING (11 min of head-pool cold start, as usual) |
| 09:13:00 | the worker node is allocated; it goes on to complete 21 tasks |
| 09:26:31 | `VARIANTFILTRATION_FALLBACK` submitted — Batch task `nf-48a087863a468e9077de75dc1ab82102`, `running` from 09:26:32 |
| 09:43 – 09:55 | 126 succeeded / 0 failed / 1 running at every poll; the task's directory holds `.command.sh` and `.command.run` only, no `.command.log` |
| 09:56:03 | `tw runs cancel` |
| 09:56:04 | the task ends (`TaskEnded`); 09:56:10 the head task ends, exit 137; Platform: `CANCELLED` |
| 09:57 | worker pool target 0 (1 node still draining), head pool 1 node |

The same task on `Wxgvs037pXLV8` and `5CiOiON5oJuETn`: 140 s and 149 s of wall time, 5 s and 8 s of
work. Its image (`gatk4_gcnvkernel`, this process only) was a first pull on that node; the node
reported no error and the registry answered from the dev VM. Inferred, not measured: the pull hung — **disproved the same day, see the next entry: it was slow, not hung**.
Not caused by the commit under test — the task runs before the report and its module is unchanged
since the last good run. Recognition recipe, bound (the task's 4 h `time`, not the job's 7 d) and what
to read before cancelling next time: `docs/dev-practices/azure_batch_execution.md` §18.

**Head-job environment, names only** (`az batch task show … --query "environmentSettings[].name"` on
this run's head task): `TOWER_WORKFLOW_ID`, `TOWER_WORKSPACE_ID`, `TOWER_REPORTS_FILE`, `NXF_UUID`,
`NXF_WORK`, `NXF_OUT_FILE`, `NXF_LOG_FILE`, `NXF_TML_FILE`, `NXF_CLOUDCACHE_PATH`,
`NXF_CONFIG_BASE64`, `NXF_PRERUN_BASE64`, `NXF_IGNORE_RESUME_HISTORY`, `NXF_SYNTAX_PARSER`,
`NXF_ANSI_LOG`, `NXF_PLUGINS_DEFAULT`, `AZ_WORK_URL`, `AZ_SAS`. So a pipeline can read its Seqera run
id (and the numeric workspace id) from the environment. It cannot read the address of its own run
page: that URL is built from the organisation and workspace *names*, which Platform sends to the
Tower plugin only in the response to the trace *begin* call, after the DAG is built, where the plugin
keeps it in a private field (`TowerClient.groovy`, Nextflow 25.10.4) and prints it once ("Monitor the
execution with Seqera Platform using this URL"). Platform's injected config carries only
`tower { enabled; endpoint }` (read with `tw runs view --config`). Hence the optional
`seqera_workspace_url` parameter behind the index's run link.

### 2026-10-01 (later) — ✅ correction: the "hung" pull was a slow one — a 2 GB image layer at 0.36 MB/s; ⚠️ a startup timeout reading the params file

Two more launches of the 2-sample test set from `973027b`, same outdir
`az://aletest/seqera-runs/yAMP-index-runline-20261001`.

**`GJbeDu3B5XZqX` — FAILED at startup, not a pipeline error.** Platform's error report ends
`Cannot parse params file: https://api.cloud.seqera.io/ephemeral/<id>.yaml`; no start time, no commit,
no Nextflow version on the run. Head log: repository cloned by 10:11:58Z, then
`java.net.ConnectException: Connection timed out` at 10:14:11Z under `CmdRun.readYamlFile` — the head
node could not open a connection to the host that had served it the SCM config 2 min 27 s earlier.
Relaunched unchanged as `4REMpK9OCBKY4z` at 10:16:40Z, which parsed the same params.
(`azure_batch_execution.md` §10, the transient-startup paragraph.)

**`4REMpK9OCBKY4z` — the same process "stuck" again, and this time the registry was measured.**
`VARIANTFILTRATION_FALLBACK`, Batch task `nf-1f9b138eb9f668f995a94067ea5de29a`, `running` since
10:35:16Z on a different node (private IP only, no inbound endpoint — no way in), again only
`.command.sh` and `.command.run` in its directory. From the dev VM, 11:30–11:37Z, with a registry
token from `cerbero.seqera.io`:

| Read | Result |
|---|---|
| manifest of `gatk4_gcnvkernel:edb12e4f0bf02cd3` | 14 layers, 2 013 MB; one layer of 1 977 MB |
| that layer, whole, 300 s limit | 108 920 832 bytes — 0.36 MB/s |
| that layer, 30 s from the start / from the 1 GB offset | 0.31 MB/s / 0.41 MB/s |
| the 30 MB layer, same host (`community-cr-prod.seqera.io`, Cloudflare) | 71 MB/s |
| control: a 39 MB GitHub release asset | 54 MB/s |

0.36 MB/s × 1 977 MB ≈ 91 min, against ≈ 2 min for the same pull on 2026-09-29. So the entry above
("inferred, not measured: the pull hung") was **wrong**, and `4xHktQIoVD1t3Z` was cancelled about an
hour before it would have continued by itself. Platform also flipped this run to `UNKNOWN` at 11:19Z
and back to `RUNNING` a minute later (§15: not an outcome). Seqera's status page: "All Systems
Operational". The slow blob is on Seqera's community registry; nothing on our side changed.
`azure_batch_execution.md` §18 is rewritten around the measurement, with a row in §16.

### 2026-10-01 (afternoon) — ✅ 2-sample run `4REMpK9OCBKY4z` SUCCEEDED: Run line with a live Seqera link, inlined index, download entries; ❌ a file inside a published directory cannot be an Outputs entry

Commit `973027b`, 155 tasks, **93.8 min wall** — 70 of them one task waiting for its image:
`VARIANTFILTRATION_FALLBACK` submitted 10:35:15Z, completed 11:45:15Z, `duration` 4 199.8 s,
`realtime` 4.65 s. That is the measured end of the slow pull of the previous entry (the dev-VM
estimate was 91 min; the node did a little better). The image is replaced in the next commit.

Read from the run through the Platform API (`GET /workflow/<id>/reports`, then the content route
`/content/redirect/reports/wsp/<ws>/<run>/<n>/<file>` with the token):

| Check | Result |
|---|---|
| Entries listed | 20: the 15 of earlier runs + `2b` SNV CSV, `2c` cohort VCF, `3b` SV VCF, `4b` uncollapsed CN, and no `4c` |
| `.vcf.gz` entries | listed with mime `application/gzip` and served: `2c` 20 215 bytes / 100 records, `3b` 5 796 bytes / 13 records — the open question of 2026-09-30 is answered |
| Index built on Platform | 579 275 bytes, Tabulator inlined, 0 `unpkg` references; version chip `v1.0.0`; output folder `az://…/yAMP-index-runline-20261001` |
| Run line | run name, start 10:17 UTC, commit `973027b` (GitHub link), Nextflow 25.10.4, **Seqera run `4REMpK9OCBKY4z` linking `https://cloud.seqera.io/orgs/DTU-Biosustain/workspaces/RECON-ALE/watch/4REMpK9OCBKY4z`**, session id — the run id came from `TOWER_WORKFLOW_ID`, the link from `seqera_workspace_url` in the profile |
| Chromosome CSV | published at `mutation_reports/data/cn_matrices/cn_chr_summary_germline.csv` (253 bytes); the index's link to it returns 200 through the preview's content route |

**Entry `4c` was never listed.** `tower.yml` carried
`**/mutation_reports/data/cn_matrices/cn_chr_summary_germline.csv` and the file exists at exactly that
path. Mechanism, read in the source (Nextflow 25.10.4): `PublishDir.apply0` publishes
`dedupPaths(files)`, which drops every path nested in a directory that is itself an output, and
`TowerReports.filePublish` matches the *destination of each publish event* against the patterns. The
chromosome summary leaves `BUILD_CN_MATRIX` inside its `cn_matrices/` directory output, so the only
event is the directory's. The entry is removed again; making the file listable would need it
published as a file of its own (a top-level copy from the module — a new output name).

Not checked from here: clicking the run link *inside* the sandboxed preview (pop-ups inherit the
sandbox; the link is plain `target="_blank"`). In a downloaded copy or the index opened in its own
tab it is an ordinary link.

### 2026-10-01 (evening) — ✅ 4-SAMPLE PILOT on the current recipe: run `1DqSRNsEYo4VCD`, 269/269 tasks, 52 min — the demo output; first cloud run of the biocontainers soft-filter image

Commit `cc3ae24`, Launchpad entry `yAMP-ottilie-test-az` with `-p docker,ottilie_pilot_az`, outdir
`az://aletest/seqera-runs/yAMP-demo-pilot-20261001`. Submitted 12:25:34Z, RUNNING 12:33:54Z (8 min
of cold start), SUCCEEDED 13:23:55Z; wall time 52.0 min, 0 failed, 0 cached, estimated cost $0.80.

**How it was launched — every parameter explicit.** A params file beats the profile, and the
committed box carries the *test* set's input / fasta / snpeff_cache, so the pilot's own box was
generated from its profile and sent through the launch script (nothing registered, file not
committed):

```bash
SEQERA_PROFILES=docker,ottilie_pilot_az PARAMS_FILE=/tmp/pilot_box.yml ./14_register_pipeline.sh --generate
DRY_RUN=1 SEQERA_PROFILES=docker,ottilie_pilot_az PARAMS_FILE=/tmp/pilot_box.yml \
    ./15_launch_run.sh --name yAMP-demo-pilot-20261001 --set outdir=az://aletest/seqera-runs/yAMP-demo-pilot-20261001
# 14 keys: samplesheet_pilot_az.csv, S288C_reference/{S288C_R64.fa,snpeff_cache,S288C_R64.gff3}, …; then without DRY_RUN
```

**The soft-filter step on its new image.** `VARIANTFILTRATION_FALLBACK`: container
`quay.io/biocontainers/gatk4:4.5.0.0--py36hdfd78af_0`, `duration` 29.4 s, `realtime` 5.0 s — against
4 199.8 s on `4REMpK9OCBKY4z` the same day with the Wave image (`6d0714b` is the change).

**Cloud equals the local pilot of 2026-09-09** (`output_ottilie_pilot_2026-09-09/`, produced with the
Wave image, GATK 4.6.2.0, before today's commits), compared on a download of `mutation_reports/`
(`17_download_outdir.sh` → `output_demo_pilot_20261001/`, 94 files):

| Compared | Result |
|---|---|
| `vcf/haplotypecaller/cohort_haplotypecaller_annotated.vcf.gz`, everything below the `##` header | 451 records, 0 differing lines |
| `cn_cohort_{collapsed,full}.csv`, `contig_copy_number.csv`, `sv_cohort_matrix_union{,_pass}.csv` | md5-identical, all five |
| `cn_matrices/{cn_bins_continuous,cn_chr_summary_{call,germline},cn_segments_{call,germline}}.csv` (old output: `cn_matrices/cn_matrices/`) | md5-identical, all five |

**The index** (read through the Platform API, and the downloaded copy opened in headless Chromium
with the network blocked — no request, clean console, every local link resolves): 4 samples;
459 SNV / InDel sites, 399 PASS, 201 differ between samples, 46 of them protein-changing; 5 SV events
called by both callers of 53; 2 aneuploid contigs of 17; 167 of 221 copy-number windows with a
change. Run line: run name, start 12:31 UTC, commit `cc3ae24`, Nextflow 25.10.4, Seqera run
`1DqSRNsEYo4VCD` linking its watch URL, session id. Outputs tab: 28 entries (the 12 entry points and
16 per-sample reports); five per-sample reports exceed 10 MB (15–42 MB: download-only, the 42 MB one
listed by path only — the tab's documented limits).

Task count 269 against 307–310 on the pilot runs of 2026-08/09: those ran the recipe of their day
(hard filter family, the `tabix/` step, no post-trim FastQC or early MultiQC reports); the count was
not reconciled process by process.

### 2026-10-05: ✅ a Launchpad entry's params box can be changed in place (`14_register_pipeline.sh --update`); the entry `yAMP` opens with `qc_only` ticked

**Why.** User decision in the launch-form review: the form should open with `qc_only` ticked.
Three levels were on the table (entry parameters, pipeline default, schema default only); the
entry level was chosen because it changes launches from the entry and nothing else. The pipeline
default, the schema, every profile, the command line and nf-test stay a complete run.

**How the form picks the box's state** (*measured*, `GET /pipelines/<id>/schema`, field `params`,
entry `yAMP_copy` = `229869124167989`): with no `qc_only` key in the entry's params box the form's
value was `false`, the schema default. With `qc_only: true` in the box it is `true`, the schema
default still `false`. Not yet looked at in the browser.

**In-place update works.** `PUT /pipelines/{id}?workspaceId=…` returned 200 with `name`,
`description`, `icon` and a `launch` object holding `computeEnvId` (the id from GET's `computeEnv`
object), `paramsText` (new) and the other launch fields as GET returned them (`pipeline`, `workDir`,
`revision`, `configProfiles`, `nextflowVersion`, the script and secret fields). Read back on
`yAMP_copy`: same pipeline id; revision `launch-form-preview`, profiles, compute environment and the
`25.10.4` engine pin unchanged; the launch object has a new id and creation date. Platform stored
the change as a **new default version** of the entry, `yAMP_preview_launch-1`, next to
`yAMP_preview_launch`, with a new version hash. A second `PUT` whose box differed in comments only
added no further version. The 2026-08-12 table says `PUT` returns 400 "with the full launch object
round-tripped from GET": that object holds `computeEnv`, not `computeEnvId`, the likely reason
(*inferred*; the 400 was not reproduced).

**In the repo** (commit `89c8bcd`): `14_register_pipeline.sh` writes `qc_only: true` into the
generated box (`ENTRY_QC_ONLY`, default `true`; `qc_only` is excluded from the profile diff) and has
the `--update` mode, with the same drift guard and readback as a registration plus a check of the
box's `qc_only`. `15_launch_run.sh` sends that box, so a scripted launch is a QC-only run unless
`--set qc_only=false`; with `--resume` it sends `qc_only: false` unless a `--set qc_only=…` is given
(the box's `true` would end a resumed run after read QC again). Three dry runs: plain launch
`qc_only: true`, `--set qc_only=false` → `false`, `--resume` → `false`.

**Applied to the entry `yAMP` (`166797736834160`, `main`) on 2026-10-05, 15:30 UTC**, after the
push of `89c8bcd`: `./14_register_pipeline.sh --update`, HTTP 200, the script's readback green
(profiles, box, `qc_only` in the box, engine pin `25.10.4`). The dry run before it had listed two
box changes, and both went in: `qc_only` absent → `true`, and `seqera_workspace_url` absent → the
workspace URL. The second one means the entry's stored box predated `973027b` (2026-10-01; its
version dated from 2026-09-08): until this update a launch from the form sent no workspace URL, so
its index page showed the Seqera run id without a link (*inferred* from the box: the parameter is
hidden and has no default), while the scripted launches sent the committed box and had the link
(run `4REMpK9OCBKY4z`). Read back afterwards (`GET /pipelines/<id>/schema` and `/pipelines/<id>`):
same pipeline id; the form's values hold `qc_only: true` and the workspace URL; the schema served
equals `nextflow_schema.json` of `89c8bcd` (sections Input/output, Reference genome, Main options,
Read preprocessing, Alignment, Variant Calling); the default version of the entry is now
`yAMP-ottilie-test-az-2` (was `-1`). Not launched: the first run from the form is the check that a
ticked box gives a QC-only run there.

**Preview set-up removed** the same hour: the entry `yAMP_copy` (`229869124167989`) deleted, the
remote branch `launch-form-preview` deleted. How to set one up again:
`docs/dev-practices/azure_batch_execution.md` §20, last bullet.

**Entry names.** The entries are now named `yAMP` and `yAMP_copy` (the 2026-10-01 evening entry
above still names `yAMP-ottilie-test-az`). `14_register_pipeline.sh` and `15_launch_run.sh` defaulted
to the old name and would not have found the entry; their default is `yAMP` since this date (user
decision). `PIPELINE_NAME` still overrides it, as for the preview copy.

### 2026-10-05 (late afternoon): ✅ QC-first pair from the updated entry, commit `616f67a`: `1VItgFdKPAxaLT` (18 tasks) → `6iO52bvtK9Db7` (155 tasks, 17 cached)

The first launch from `yAMP` after its box gained `qc_only: true` (entry above) and the first
Platform run of the launch-form series (`f8f16b7`…`616f67a`: start-up validation rules, `qc_only`
in Main options, the reordered sections). Both from the command line, nothing typed in the form.

- **Run 1** `1VItgFdKPAxaLT` (`yAMP-qc-first-run1-20261005`):
  `./15_launch_run.sh --name … --set outdir=az://aletest/seqera-runs/yAMP-qc-first-20261005`, no
  `qc_only` override, so the box's `true` applied (the script said so). SUBMITTED 15:44:41 UTC,
  RUNNING 15:53:44 (cold head pool, 9 min), SUCCEEDED 16:03:49; wall 11.55 min, $0.04. Params
  read back: `qc_only: true`, exit 0, commit `616f67a`. 18 tasks in 15 processes, none failed:
  BUILD_INTERVALS, BWAMEM1_INDEX, CNVKIT_ANTITARGET, CNVKIT_REFERENCE, CREATE_INTERVALS_BED, FASTP,
  FASTQC, FASTQC_TRIMMED, GATK4_CREATESEQUENCEDICTIONARY, MULTIQC_READ_QC, PREFLIGHT_REFERENCE,
  PREPARE_GFF3, SAMTOOLS_FAIDX, TABIX_BGZIPTABIX_INTERVAL_COMBINED, TABIX_BGZIPTABIX_INTERVAL_SPLIT
  (the 2026-09-28 list). So on Platform the entry's default gives a QC-only run, and the new
  validation rules accept the real `az://aletest/…` paths.
- **Run 2** `6iO52bvtK9Db7` (`yAMP-qc-first-run2-20261005`): `./15_launch_run.sh --resume
  1VItgFdKPAxaLT --name … --set outdir=<the same>`; the script sent `qc_only: false` by itself.
  SUBMITTED 16:04:44 (55 s after run 1 ended), RUNNING 16:06:45 (warm pool, 2 min), SUCCEEDED
  16:23:53; wall 18.22 min, CPU 3.03 h, $0.26. Params read back: `qc_only: false`, resume true, the
  same session `1ee2c4c9-…`, commit `616f67a`, exit 0. 155 tasks: 138 run + 17 CACHED, 0 failed;
  the cached ones are every run-1 task but `MULTIQC_READ_QC`; 64 of 117 processes carried tasks.
  No UNKNOWN at any point (§15 did not recur).
- **Counts against 2026-09-28** (`464Scp5QNoznbD`: 153 tasks, 17 cached, 115 processes, 61 with
  tasks): +2 tasks, +2 processes, +3 with tasks. The process map diff between the two runs
  (`/workflow/<id>/progress`) names exactly two new processes, `MULTIQC_READ_QC` and
  `MULTIQC_ALIGNMENT_QC` (2026-09-29), which account for the tasks and the map. The third process
  with tasks could not be identified from the API: Platform's record of `464Scp5QNoznbD` holds only
  62 task events and 39 processes with tasks, the UNKNOWN episode of that day (§15); its 153 came
  from the head log and the downloaded outdir. `docs/usage/qc_first_run.md` carries the new counts.
- **Outdir** `az://aletest/seqera-runs/yAMP-qc-first-20261005`: 995 blobs, 206 MB (multiqc 663,
  reports 138, mutation_reports 70, variant_calling 65, annotation 27, pipeline_info 12, …).
  `yAMP-read-QC_multiqc_report.html` written 16:08 (run 2 rewrote run 1's), the alignment-QC report
  16:14, the complete one 16:22, `index.html` 16:23. **Not compared** against the baseline or a
  local e2e; nothing was downloaded.


### 2026-10-23: ✅ the `yAMP` entry follows the repo transfer to `nnf-bright-biofoundry/ALE_Yeast`; ⚠️ `tw pipelines update` drops the engine pin; ⚠️ the GitHub credential no longer matches

The GitHub repository moved from `Aletechdev/ALE_Yeast` to `nnf-bright-biofoundry/ALE_Yeast` (GitHub
redirects the old URL, so the entry kept launching, but `manifest.name` must equal the handle, see
`CLAUDE.md` → Pipeline Identity). Same-day changes, entry id `166797736834160` unchanged:

- **Entry URL** set with `tw pipelines update -i 166797736834160 --version-id 14AaZHjBoe8nA3LBLOxdaT
  --pipeline https://github.com/nnf-bright-biofoundry/ALE_Yeast`. Platform made a new default
  version (`yAMP-ottilie-test-az-3`). **Read back: `launch.nextflowVersion` had become `null`** — the
  CLI's update sends the fields it knows and the engine pin is not one of them. The pin is the only
  one since 2026-08-12 (the CE carries none) and 26.x cannot parse `nextflow.config`, so a launch from
  that version would have failed at start-up. Restored with the same `PUT /pipelines/{id}` the
  `--update` path of `14_register_pipeline.sh` sends (every `launch` field as read back, `computeEnvId`
  from the `computeEnv` object, `nextflowVersion: "25.10.4"`): HTTP 200, version
  `yAMP-ottilie-test-az-4` (`dyUIT4qpwCwCzOPoE3oh8`) is the default; read back `pipeline` = the new
  URL, `revision main`, `nextflowVersion 25.10.4`, profiles `docker,ottilie_test_az`, CE
  `yAMP-ce-nofusion-256`, the committed params box intact. **Rule:** after any `tw pipelines update`,
  read `nextflowVersion` back; `--update` in the script copies the pin *as the entry has it*, so it
  cannot repair a dropped one. The script's default `REPO` is the new URL.
- **`github_ALE_Yeast_finegrained` (`2NhER3hJHchursPHekAV1P`) no longer applies.** Its `baseUrl` is
  still `https://github.com/Aletechdev/ALE_Yeast`, which Platform matches against the entry URL, so
  the form's GitHub API calls now go unauthenticated (the *Drop* case of the roadmap item of
  2026-10-09, in effect); and the token itself names `Aletechdev` as resource owner, so it cannot read
  the repository under its new owner even if re-pointed. The head job's clone is anonymous HTTPS of a
  public repo and is unaffected. **Open:** delete the credential, or mint a fine-grained PAT with
  resource owner `nnf-bright-biofoundry` (the org must allow fine-grained tokens) and register it with
  `--base-url https://github.com/nnf-bright-biofoundry/ALE_Yeast`. Not launched today; the next launch
  from the entry is the check.

### 2026-10-26: ✅ first launch from the entry after the transfer: run `4tiNtBjO5ozg2y` clones and banners `nnf-bright-biofoundry/ALE_Yeast`

The check the 2026-10-23 entry left open. One QC-only launch from `yAMP`, scripted, nothing typed in
the form: `./15_launch_run.sh --name yAMP-newhandle-qc-20261026 --set
outdir=az://aletest/seqera-runs/yAMP-newhandle-qc-20261026`, no `qc_only` override, so the box's
`true` applied. Platform version `yAMP-ottilie-test-az-4` (the one with the restored engine pin).

- **Timeline.** SUBMITTED 10:15:02 UTC, RUNNING 10:26:27 (cold head pool, 11 min), SUCCEEDED
  10:36:33; wall 11.32 min, CPU 0.55 h, $0.04. Head task `completed`, exit 0 at 10:36:43, and the head
  pool was back at 0 nodes a minute later: no hung head job (§15 did not recur). Nextflow 25.10.4.
- **Identity, every place it shows.** Runs list *Project Name* `nnf-bright-biofoundry/ALE_Yeast`
  (every earlier row still reads `Aletechdev/ALE_Yeast`); workflow record `repository
  https://github.com/nnf-bright-biofoundry/ALE_Yeast`, commit `74db1f6`, revision `main`, exit 0.
  Head log (`GET /workflow/{id}/log`): `Pulling nnf-bright-biofoundry/ALE_Yeast ... downloaded from
  https://github.com/nnf-bright-biofoundry/ALE_Yeast.git`, the banner `nnf-bright-biofoundry/ALE_Yeast
  1.0.0`, `projectDir /.nextflow/assets/nnf-bright-biofoundry/ALE_Yeast`, and the completion line
  `[nnf-bright-biofoundry/ALE_Yeast] Pipeline completed successfully`. `versions.yml` Workflow key
  `nnf-bright-biofoundry/ALE_Yeast: v1.0.0-g74db1f6` (the third and, with luck, last move of that line;
  CLAUDE.md → Pipeline Identity). So the clone is anonymous HTTPS of the new URL and needs no
  credential, as the 2026-10-23 entry expected.
- **Content, same as 2026-10-05 run 1.** 18 tasks, 0 failed, 0 cached, in the same 15 processes
  (BUILD_INTERVALS, BWAMEM1_INDEX, CNVKIT_ANTITARGET, CNVKIT_REFERENCE, CREATE_INTERVALS_BED, FASTP ×2,
  FASTQC ×2, FASTQC_TRIMMED ×2, GATK4_CREATESEQUENCEDICTIONARY, MULTIQC_READ_QC, PREFLIGHT_REFERENCE,
  PREPARE_GFF3, SAMTOOLS_FAIDX, TABIX_BGZIPTABIX_INTERVAL_COMBINED, TABIX_BGZIPTABIX_INTERVAL_SPLIT).
  *yAMP input checks*: 6 rows, all OK (Tier-1 recipe 16/16, `--qc_only`, experiment ids, files listed
  once, ploidy/clonal, FASTA vs GFF3 4/4 contigs). Console: the `[yAMP qc_only]` stop line and the
  follow-up block naming `-resume e3e2e896-dffe-4214-ae88-6f611830a1dd`.
- **Outdir** `az://aletest/seqera-runs/yAMP-newhandle-qc-20261026`: 207 blobs, 23.1 MB (multiqc 162,
  reports 31, pipeline_info 7, reference 3, build 2, preprocessing 1, csv 1);
  `yAMP-read-QC_multiqc_report.html` 2.7 MB written 10:36:24. Not resumed into a complete run and
  not compared against a baseline: the question was the URL, and a QC-only run has no deliverable
  to compare. Resume it with `./15_launch_run.sh --resume 4tiNtBjO5ozg2y --name … --set outdir=<same>`
  if a complete run on the new handle is ever wanted.
- **Reading the evidence from this VM.** The user `az login` on the VM had expired (AADSTS70043,
  14-day refresh-token lifetime under conditional access; last sign-in 2026-10-09), so the blob and
  Batch reads were done with the service principal, logged in under a throw-away `AZURE_CONFIG_DIR`
  so the user's session is untouched: `az login --service-principal -u <clientId> -p
  "$AZURE_CLIENT_SECRET" --tenant <tenantId> --allow-no-subscriptions`; the two ids are in the
  Platform credential `azure_SP_cfb_ale_mutations_pipeline` (`GET /credentials/{id}` shows them, `tw
  credentials view` does not). The same SP reads the Batch account (`--account-endpoint
  https://aledev4test.northeurope.batch.azure.com`). Reminder for `az storage` commands: `az://aletest/…`
  is the **container** `aletest` of the storage account **`aledata`**, not an account; an account
  named `aletest` does not resolve (NXDOMAIN).
- **Observed, not transfer-related, deferred.** The banner's citations block links
  `https://github.com/nnf-bright-biofoundry/ALE_Yeast/blob/master/CITATIONS.md` (nf-core template
  text in `nextflow.config` and `utils_nfcore_pipeline/main.nf`; nf-core repos default to `master`).
  This repo's default branch is `main`, so the link 404s. Roadmap item, not a launch problem.

### 2026-10-26 (later): ✅ decision: no GitHub credential; the PAT entry leaves `check_credential_expiry.sh`

Follow-up to the two entries above. Deploy keys are disabled in the `nnf-bright-biofoundry` org, which
changes nothing for Platform (HTTPS only, 2026-08-05 entry), and a replacement fine-grained PAT would
re-create the person-tied yearly rotation for the sole benefit of the launch form's GitHub API rate
limit. The user chose public access as the lowest-maintenance option.

- `bin/check_credential_expiry.sh`: the `GitHub fine-grained PAT` check removed, a comment in its
  place; the script now tracks the Azure SP secret (2027-07-31) and the sister-SP secret (2027-08-14)
  and stays silent. *GitHub PAT* section above rewritten as retired, with the way back.
- `CLAUDE.md` (Cloud execution, the PAT sentence and the SessionStart-hook dates) and the roadmap's
  keep-or-drop item updated to the decision.
- Credential deleted from the workspace by the user the same day; two Azure credentials remain
  (read back), and the token revoked at GitHub. The launch form was opened in a browser the same
  evening and renders normally with no GitHub credential in the workspace (anonymous GitHub API).
  Nothing of the transfer is pending on the Platform side.

