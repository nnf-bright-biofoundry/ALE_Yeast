# Running the pipeline on Azure Batch — execution gotchas

> **Status (2026-08-06): validated end-to-end for BOTH a local head job and a Seqera Platform head job.**
>
> - **Local head job** (2026-08-03): 138 tasks (+32 cached), **540 blobs** published to
>   `az://aletest/ottilie-azurebatch-out/`. This is the **reference baseline**.
> - **Seqera Platform head job** (2026-08-06, run `3C5zYMYY5M32dO`): **170/170 tasks, 0 failed**, and all
>   **9 cohort deliverables byte-identical** to that baseline — the acceptance criterion, met. Every
>   remaining difference falls in a known non-determinism class (§11).
>
> Both run under the **Entra service principal**. `outdir` container placement (§3) is now confirmed for
> a Platform head job too, not just a local one.
>
> ⚠️ Getting there needed **§9 (node OS disk)** and **§10 (head-job restart)** — a Platform head job on a
> single-pool compute environment fails at ~98% completion without them.

Config: [`conf/azure_batch.config`](../../conf/azure_batch.config) (pass with `-c`, deliberately not a
profile, so only opted-in runs are affected) · params: [`conf/params_ottilie_test_blob.yml`](../../conf/params_ottilie_test_blob.yml) ·
launcher: [`bin/test_ottilie_azure_batch.sh`](../../bin/test_ottilie_azure_batch.sh) ·
Azure/SP provisioning: [`deploy/azure/`](../../deploy/azure/).

Everything below was found by *running* it. None of it is visible to the local test suite, and several
items produce errors that point at the wrong thing entirely.

📌 **§16 is a register of claims that were believed and then disproved.** Read it before concluding
that some tool "cannot" do something — several entries here were once confidently written the other way.

---

## Orientation — why this config isn't the five-line example

Every Azure Batch tutorial, including Seqera's own
[Nextflow and Azure Batch (part 1)](https://seqera.io/blog/nextflow-and-azure-batch-part-1-of-2/),
shows a config that fits on a screen:

```groovy
process { executor = 'azurebatch' }
azure {
    storage { accountName = "…"; accountKey = "<key>" }
    batch {
        location = 'eastus'; accountName = '…'; accountKey = '<key>'
        autoPoolMode = true
        allowPoolCreation = true
        pools { auto { autoScale = true; vmCount = 1; maxVmCount = 10 } }
    }
}
// work dir passed on the CLI:  -w az://nextflow-scratch/work
```

[`conf/azure_batch.config`](../../conf/azure_batch.config) has the **same skeleton** — the executor
line, `autoPoolMode`, `allowPoolCreation`, and the `pools.auto` autoscale block are byte-for-byte the
same idea. It looks bigger mostly because it carries its reasoning inline. Only **four** settings
actually diverge, and three of them are forced rather than chosen:

| Setting | Tutorial | Here | Why it differs |
|---|---|---|---|
| **Auth** | `accountKey` for storage + batch | Entra service principal (`azure.activeDirectory`), read from env vars | **Chosen.** Shared account keys are all-or-nothing, can't be scoped, and must not sit in the repo. The SP holds two *data-plane* roles on **one** Batch account and **one** storage account (`deploy/azure/`). This is the root cause of gotcha §3 below. |
| **`vmType`** | omitted → default `Standard_D4_v3` | `Standard_E4ds_v4` | **Forced by quota.** On `aledev4test` only Ev4/Dv3/Dv4-family SKUs have vCPU quota (350); anything else fails `AccountVMSeriesCoreQuotaReached`. The 32 GB (vs 16 GB on `D4s_v3`) also suits the GATK steps. |
| **`publisher`/`offer`/`sku`** | omitted → rely on the default image | pinned, `sku = 'batch.node.ubuntu 24.04'` | **Pin the current verified LTS.** Nextflow only accepts images Batch marks `verified`; its built-in default (22.04) has aged out and now matches nothing. Expect to bump this at each LTS. See §4. |
| **`workDir`** | `-w` on the CLI, any container | in the config, **same container as the inputs** | **Consequence of the auth choice.** SP auth makes Nextflow mint one container-scoped SAS. Under the tutorial's account-key auth this constraint does not exist. See §3. |

Two things that look like divergences but are not:

- **`deletePoolsOnCompletion = false`** is Nextflow's own default. It is written out explicitly only
  because the reason to keep it matters (§2) and because an env var can flip it for one-shot runs.
- **`maxVmCount = 4`** (vs 10) is just test-scale sizing, not a technical constraint.

⚠️ **The tutorial is also older than the engine we run.** It states the default pool image is
`microsoft-azure-batch / ubuntu-server-container / 20-04-lts`. On Nextflow 25.10.4 the observed
default is `microsoft-dsvm / ubuntu-hpc / batch.node.ubuntu 22.04` (§4). So "just take the defaults"
is advice from a different Nextflow. Treat the blog as correct on *shape*, not on *values*.

**The one-line summary:** the extra complexity buys least-privilege auth and nothing else. Swap the
SP for account keys and this config collapses to roughly the tutorial's size — along with the
work-dir constraint. That trade is deliberate; see [`deploy/azure/seqera-sp/RUNBOOK.md`](../../deploy/azure/seqera-sp/RUNBOOK.md).

---

## 1. `-resume` silently resumes the WRONG session

**Symptom.** `-resume` reruns everything: `Cached process` count is 0.

**Cause.** Bare `-resume` resumes **the most recent run in `.nextflow/history`**, whatever that was.
Any other `nextflow run` in the same directory — including a `-preview` sanity check or an unrelated
local profile test — becomes "most recent" and its (empty) cache is what gets inherited. The real run's
cache is untouched but never consulted.

**Fix.** Resume an explicit session id:

```bash
tail -5 .nextflow/history          # columns: time, duration, run name, status, revision, SESSION ID
nextflow run ... -resume 7bd76ec1-9112-4937-a672-d0022eff396c
```

**Prevention — `-work-dir` does NOT help.** It isolates the *work directory*, but `.nextflow/history`
lives in the **launch** directory, so the run is still recorded and still becomes "most recent". This
was tried and failed. Either:

```bash
# (a) launch the check from a different directory — history is per-launchDir
mkdir -p /tmp/nf-check && cd /tmp/nf-check && nextflow run /path/to/repo/main.nf -profile ottilie_test,docker -preview

# (b) or simply always resume by explicit session id (the reliable habit)
nextflow run ... -resume <session-id>
```

**(b) is the habit worth forming** — it is correct regardless of what else has run, whereas (a) depends
on remembering to isolate *every* incidental run.

`-resume` also requires the **same `workDir`**. Changing `workDir` invalidates every cached task, since
task caching is keyed on work-dir paths.

---

## 2. Pool names are content-addressed — and that breaks `deletePoolsOnCompletion`

Nextflow names auto-pools `nf-pool-<hash>-<vmType>`, where the hash is a `CacheHelper` digest of
`AzVmPoolSpec` = `vmType` + the whole `AzPoolOpts` (the `azure.batch.pools.<name>` block) + metadata.
Same pool config → same id → the pool is reused across runs; change `vmType`, `sku`, `publisher`,
`offer`, autoscale or node counts → new hash → a fresh pool. Same principle as task work-dir hashing:
you can never silently execute on a pool built to a different spec than you asked for.

Options on `azure.batch.*` (as opposed to `azure.batch.pools.*`) are **not** in the hash —
`deletePoolsOnCompletion` can be flipped without minting a new pool.

**Symptom.** On `-resume`: `Azure Batch pool 'nf-pool-<hash>-<vmType>' not in active state`.

**Cause.** `deletePoolsOnCompletion = true` destroyed the pool at the end of the previous run. Because
the id is derived rather than random, the resumed run asks for that exact pool and finds it in
`deleting` state.

**Fix.** Keep pools between runs (the repo default). Idle pools cost nothing — autoscale drains them to
0 nodes and billing is per-VM, not per-pool. Set `AZURE_DELETE_POOLS=true` for one-shot production runs.
Occasional cleanup:

```bash
az batch pool list --query "[?starts_with(id,'nf-pool')].id" -o tsv | xargs -r -n1 az batch pool delete --yes --pool-id
```

---

## 3. With an Entra/SP credential, the work dir must be in the SAME CONTAINER as the inputs

> **This rule tracks the CREDENTIAL, not local-vs-cloud.** A **shared-key** credential gives Batch
> nodes account-wide access and has no such restriction — verified 2026-08-04: the Seqera CE
> `aledev4test_e4ds_v4` (credential `rgALE_batch_aledev4test`; CE since deleted 2026-08-13) ran
> `workDir = az://debugging` against inputs in `aletest` and worked. A *cloud* run on the **Entra**
> credential hits this rule exactly as a local one does.
>
> **⛔ No bypass exists under the SP credential — every candidate has been tested:**
>
> | Candidate bypass | Verdict |
> |---|---|
> | More RBAC on the SP | ✗ — the SP already holds `Storage Blob Data Contributor` account-wide and can read both containers itself. Nodes never authenticate as the SP; they get one delegated container-scoped token. The limit is what Nextflow *delegates*, not what the SP *may* do — Owner on the subscription would change nothing. |
> | Fusion (per-container tokens?) | ✗ — verified 2026-08-13 (run `3AJ4JRNkb7D2dG`): same single SAS through the FUSE path, rejected 403. See below. |
> | **Switch credential type: shared key** | ✓ works (2026-08-04, above) — **the only lever**, and it is a *trade*, not a free fix: every Batch node gets account-wide blob access, which is the blast radius the Entra SP path was chosen to avoid. |
>
> So under the SP: keep inputs and `workDir` in one container — it is a requirement, not a tuning knob.

**Symptom.** A task exits 1 with **empty stderr**. The real message appears only in `.command.log` in
blob: `Unable to download path: https://<account>.blob.core.windows.net/<container>/...`

**Cause.** With Entra/service-principal auth, Nextflow mints **exactly one** container-scoped
user-delegation SAS (`sr=c`) for the work-dir container and reuses it for *every* blob URL in the task
script. Verified: the generated `.command.run` contains a single `sig=` value. A node therefore has no
credential for any other container — **same storage account is not sufficient**.

**Fix.** Put `workDir` in the container holding the inputs (here: inputs under `az://aletest/ottilie/v1/`,
so `workDir = az://aletest/nf-work`). Same storage account either way, so no extra RBAC grant is needed.

**`outdir` is exempt** and may live in another container: `publishDir` runs in the **head process**
using the SP credentials, which have account-wide blob access — not the node's container-scoped SAS.
Verified: 195 blobs published to `az://debugging/ottilie-azurebatch-out/` while `workDir` was
`az://aletest/nf-work`.

### ✅ Confirmed under a Seqera Platform head job (2026-08-07)

Previously this rule was verified only with a **local** head job, leaving open whether Platform — which
runs the head process on a Batch node — behaves the same. **It does.** Run `48kJmc9QY6Q3h9`
(`ottilie-xcontainer-01`) was launched deliberately to falsify it: identical to a known-good run except
`--work-dir az://debugging/nf-work-xcontainer`, with inputs left in `aletest`.

**Result: 0 tasks succeeded, 6 failed**, dying in `PREPARE_GENOME` about 6 minutes in. Every failed
process is one that reads an input from `aletest` — `SAMTOOLS_FAIDX`, `GATK4_CREATESEQUENCEDICTIONARY`,
`BWAMEM1_INDEX` (the fasta), `PREPARE_GFF3`, `FASTQC`. The evidence, from the task's blob work dir:

```
.command.log:  Unable to download path:
               https://aledata.blob.core.windows.net/aletest/ottilie/v1/S288C_reference_test/S288C_R64_test.fa
.command.err:  (0 bytes)
```

⚠️ **Note where the message is.** `.command.err` was empty — the Seqera UI and `tw` both surface
stderr, so this failure looks like *no error at all* from the console. **Always read `.command.log`
from the blob work dir**:

```bash
az storage blob download -c <workdir-container> --name "<path>/<hash>/.command.log" \
  --file /tmp/x.log --account-name <acct> --auth-mode login
```

| Constraint | Status |
|---|---|
| inputs ↔ `workDir` same container | ✅ **Confirmed for local and Platform head jobs, AND under Fusion.** Not a convention — a requirement. |
| `outdir` may be in another container | ✅ **Confirmed under Platform for `publishDir` writes (2026-08-13)** — run `3AJ4JRNkb7D2dG` published `pipeline_info/` into `aletest` while `workDir` was in `debugging`; verified locally earlier (195 blobs to `az://debugging/…`). Task-output publishing uses the same head-side mechanism, but a *successful* cross-container run cannot exist to demonstrate it end-to-end — the rule above kills the tasks first. |

### ✅ Fusion does NOT lift this (2026-08-13)

Answered by repeating the predicted-failure launch above on a Fusion CE (run `3AJ4JRNkb7D2dG`,
`yAMP-ce-fusion-256` — dual-pool + 256 GB per §9–§10, so `DiskFull` could not confound): **failed
identically**, 0/6, the same six `aletest`-reading tasks, ~5 min in. Fusion consumes the same single
container-scoped user-delegation SAS and presents it against the other container; the server rejects
it, and Fusion says so plainly. **The rule is a property of the credential delegation, indifferent to
the data path (azcopy staging or FUSE mount). Do not design around Fusion lifting it.**

⚠️ The failure *signature* differs under Fusion — and is friendlier: `.command.err` is **non-empty**
(the tool's own `Permission denied`), and `.fusion.log` in the task work dir holds the underlying
`403 AuthenticationFailed` complete with the SAS scope mismatch and the line *"Fusion authenticated
successfully but lacks permission to access this resource."* The empty-stderr trap above is
non-Fusion-specific.

Terminology, since the distinction is the whole point: `aledata` is the **storage account**;
`aletest` and `debugging` are **containers** within it. `az://<container>/<path>` — the account comes
from `azure.storage.accountName`. The constraint is **inputs ↔ workDir must share a container**, not
"everything in one container".

---

## 4. Pin the current *verified* `ubuntu-hpc` LTS — and re-pin when it ages out

**Rule.** Always run the newest `ubuntu-hpc` image that Batch marks **`verified`**, named by its
**node agent SKU ID** (`batch.node.ubuntu 24.04`), not its image sku (`2404`).

Two independent reasons the pin exists:

- **`verified` is what Nextflow will accept.** It filters candidates to verified images, so an
  unverified one is unusable through nf-azure regardless of whether Azure would run it.
- **`ubuntu-hpc` is the only verified family with `DockerCompatible`.** `canonical/*` and
  `almalinux/*` are verified but ship no container runtime — they fail *every task* instead of
  failing pool creation, which is the far worse failure.

**Symptom when the pin is missing or stale.** `Cannot find a matching VM image with
publisher=microsoft-dsvm; offer=ubuntu-hpc; OS type=linux; verification type=verified`

Nextflow's own defaults (`microsoft-dsvm` / `ubuntu-hpc` / `batch.node.ubuntu 22.04`) are already
stale: 22.04 has reached end of Batch node-agent support and is now `unverified`, so the default
matches nothing. **This is Microsoft's image lifecycle, not an account setting** — verified as
identical across four Batch accounts in two regions, so a new account or region inherits the same
requirement. Expect to bump the pin at each LTS transition.

⚠️ `sku = '2404'` (the *image* sku) is silently ignored and the 22.04 default is used instead. Only
the agent SKU ID works.

**Re-check when a run fails on image matching, or at the next LTS:**

```bash
az batch account login -g <rg> -n <account>
az batch pool supported-images list -o json | jq -r '.[] | select(.verificationType=="verified" and .osType=="linux")
  | "\(.imageReference.publisher) \(.imageReference.offer) \(.imageReference.sku) \(.nodeAgentSkuId) \(.capabilities)"'
```

---

## 5. A remote work dir requires every input file to actually EXIST

**Symptom.** `Can't stage file /path/to/SENTINEL -- file does not exist`

**Cause.** `file('SOME_SENTINEL')` for a non-existent path works on the **local** executor — Nextflow
symlinks it, and `ln -s` to a missing target succeeds. With a remote work dir Nextflow must *copy* every
input, so `FilePorter` throws. This hit `NO_DEPTH_BG` / `NO_LOG2_BG`, the placeholders
`IGVREPORTS_SV_CNV` uses when a caller has no CNVKit coverage tracks (it keys off the file *name*, never
the contents).

**Fix.** Don't declare a file at all — pass **`[]`**, the Nextflow idiom for an absent optional path.
[`subworkflows/local/mutation_report/main.nf`](../../subworkflows/local/mutation_report/main.nf) sets
`no_depth_bg = []` / `no_log2_bg = []`; the module sees a falsy value and drops the track. `[]` has
nothing to stage, so the failure cannot recur.

> Shipping real empty `assets/NO_DEPTH_BG` / `NO_LOG2_BG` files was the first attempt and was
> **abandoned** — it keeps a meaningless file in the repo and still stages bytes to every cloud task.
> Those assets do not exist; don't reintroduce them. Full recipe, including the `tuple path(a), path(b)`
> case, in [`troubleshooting.md`](troubleshooting.md) → "Making an optional file param actually optional".

**Generalisation.** `projectDir`-based assets are fine on Azure Batch — Nextflow stages them like any
local file, and upstream nf-core already relies on this (`$projectDir/assets/multiqc_config.yml`,
`schema_input.json`, the email templates). The rule is not "avoid `projectDir`" but **"every declared
input path must exist, and should say so with `checkIfExists: true`."**

---

## 6. A null optional param reports itself as a samplesheet error — ✅ fixed for `report_gff3`

**Symptom.**

> `The sample-sheet only contains tumor-samples, but the following tools, which were requested by the option "tools", expect at least one normal-sample : haplotypecaller`

**The samplesheet is fine.** `generate_reports` defaults to `true`; with `report_gff3` unset,
`file(params.report_gff3)` threw while the DAG was being built, and a dangling `ifEmpty` on the
samplesheet channel then fired this unrelated message. Bisect: params-file as-is → FAIL;
`+ report_gff3` → PASS; `+ generate_reports false` → PASS.

**Fixed 2026-08-04.** `report_gff3` is now genuinely optional — reports build without the gene track.
Verified end-to-end with `report_gff3` unset: 30 reports, `PREPARE_GFF3` skipped, `--tracks` dropped
from the cohort report (it was that report's only track), cohort variant table intact.

⚠️ **The misdirection itself is NOT fixed.** The dangling `ifEmpty` at
`subworkflows/local/samplesheet_to_channel/main.nf:159-168` still reports *any* early DAG abort as a
sample-status error. It is inherited from nf-core/sarek 3.5.1 and present in the pristine fork base, so
changing it is a deliberate divergence decision. Recipe for optional params, and how to find the real
error: [`troubleshooting.md`](troubleshooting.md).

---

## 7. `--foo null` on the CLI is the STRING `"null"`

`--genome null` sets `params.genome = 'null'`, which is **truthy**. A real null can only be expressed in
a config or `-params-file`. This is one reason the launcher uses `-params-file` rather than a pile of
`--flags` — the other being that the same file feeds both the local Batch run and a Seqera launch, so
they cannot drift.

---

## 8. Checking cost

[`deploy/azure/seqera-sp/11_check_cost.sh`](../../deploy/azure/seqera-sp/11_check_cost.sh) reports actual
spend by meter and day. **Cost data lags 8–24h** (sometimes 48h) — a run finished today shows `0.00`,
meaning *not billed yet*, not free.

Azure Batch itself is free; you pay for pool VMs, their managed disks (~25% on top of compute), and
storage transactions. `northeurope` list prices:

| SKU | Dedicated | Low priority | Spot |
|---|---|---|---|
| `Standard_E4ds_v4` | $0.320/hr | **$0.064/hr** | $0.086/hr |
| `Standard_D4s_v3` | $0.214/hr | $0.043/hr | $0.040/hr |

Low priority is ~5× cheaper and well suited to resumable test runs. For scale reference, real ALE
production jobs on the `ale` Batch account cost roughly **$30–40 each**. Cost Management returns **DKK**
while the retail price API returns **USD** — do not mix them (~6.9 DKK/USD).

### 8.1 Idle-state cost audit — "is anything always on?"

Audited 2026-09-11 on `yAMP-ce-nofusion-256`, the only CE: **nothing runs between pipeline runs.** The
account's steady-state cost is storage only. Three independent checks, each of which must agree; run
them whenever the question comes up, after any run that ends in a non-terminal state, and after
creating a CE.

```bash
# 1. Platform side — autoScale must be True on BOTH pools (the 2026-08-07 leak was this field)
deploy/azure/seqera-sp/12_verify_compute_env.sh yAMP-ce-nofusion-256

# 2. Azure side — both pools at 0 nodes, autoscale on, no active jobs
az batch account login -g rg-ALEdb -n aledev4test
az batch pool list --query "[].[id,currentDedicatedNodes,currentLowPriorityNodes,enableAutoScale]" -o tsv
az batch job  list --query "[?state=='active'].id" -o tsv        # must print nothing

# 3. Billing — charges only on run days (lags up to 48 h, so today is always missing)
DAYS=30 deploy/azure/seqera-sp/11_check_cost.sh
```

2026-09-11 result: `True True`; `…-head 0 0 True`, `…-worker 0 0 True`, no active jobs; 33 DKK over
30 days, all of it on the four run days (08-12/13, 09-02, 09-08), zero on the other 26.

**The two pools are the CE's own.** `tower-pool-<ce-id>-head` (`D2s_v3`) and `tower-pool-<ce-id>-worker`
(`E4ds_v4`) are forged when the dual-pool CE is created and persist between runs by design (§2). At
0 nodes they cost nothing — the VM, managed-disk, load-balancer and public-IP meters all appear only on
run days, so no disk or network resource is left behind when the nodes drain.

⚠️ **The portal's "Dedicated Core Count (Avg)" chart lies while idle.** Batch emits `CoreCount` only
while nodes exist — a pool at 0 produces *no sample*, not a sample of 0. Azure Monitor draws the gaps
between sparse points as a **dashed line**, and the legend's "Avg" is the mean of the samples that
exist, so a 30-day chart with four run days shows ~12 cores "average" for ~3 hours of actual runtime.
Read it as Max at 1-hour granularity instead, or query it:

```bash
RID=$(az batch account show -g rg-ALEdb -n aledev4test --query id -o tsv)
az monitor metrics list --resource "$RID" --metric CoreCount --aggregation Maximum \
    --interval PT1H --offset 7d --query "value[0].timeseries[0].data[?maximum>\`0\`]" -o table
```

**Residual risks, in order of likelihood — none of them is a continuous cost:**

| Risk | Bound | What to do |
|---|---|---|
| **Hung head job** (§15) — no wall-clock limit applies to the head task | one `D2s_v3` (~0.6 DKK/h) until someone cancels | after any run that shows `UNKNOWN`, or `RUNNING` long after outputs landed: check 2 above, then `tw runs cancel` |
| **Stuck worker job** | `jobMaxWallClockTime = 7d` (CE template) × up to 4 `E4ds_v4`; a single wedged task ends sooner, at its own `time` directive (Batch `maxWallClockTime`, `PT4H` measured 2026-10-01) | bounded by Batch; the autoscale formula drains nodes as soon as tasks stop, so it needs a genuinely wedged task. What looks like one is usually a task still pulling its image: the run `RUNNING` with nothing failing, seen twice on 2026-10-01 with a 2 GB layer served at 0.36 MB/s (§18: recognise it, measure the registry, wait rather than cancel) |
| **Work-dir growth** — nothing cleans `az://aletest/nf-work` | storage only (≥ 5 000 blobs / ~1.2 GB on 2026-09-11) | purge manually after a large pilot or every few months; **not** while a run may `-resume` into it |

---

## 9. Batch nodes fill their **OS disk** with Docker images — not with task data

**Symptom.** Nodes go `unusable` with:

```
code: DiskFull
"The VM disk is full. Delete jobs, tasks, or files on the node to free up space and then reboot the node."
```

Downstream this looks like something else entirely: the workflow is marked `FAILED` with **zero failed
tasks** (see §10), so nothing points at the disk.

**Why.** An Azure Batch Linux node has two disks, and they do different jobs:

| Disk | Mount | On `Standard_E4ds_v4` | Holds | Billed |
|---|---|---|---|---|
| **OS / boot** | `/` | **default size unknown** — near 65 GB, never measured (see below) | the OS and **`/var/lib/docker`** (image layers, overlay2) | yes, managed disk |
| **Temp / ephemeral** | `/mnt` | **150 GB** local NVMe | `/mnt/batch/tasks` — Nextflow task dirs, staged inputs | no, included with the VM |

Task scratch is on the *big* disk already. **Docker is on the small one**, and this pipeline pulls
10–15 tool images (GATK, snpEff, CNVkit, Manta, TIDDIT, igv-reports, MultiQC, FastQC, bwa/samtools),
which exhausts the default root disk.

**Evidence it is Docker, not task data:** an unusable node had **0.07 GB across 205 files** in its Batch
task directories. Confirm with:

```bash
az batch node file list --pool-id <pool> --node-id <node> --recursive \
  --query "[].properties.contentLength" -o tsv | paste -sd+ | bc
```

⚠️ **Concurrency is NOT the cause.** An early hypothesis blamed two runs sharing a pool; the next
failure was a **solo** run. Concurrency only reaches the limit sooner.

### Two fixes — pick per situation

**(a) Enlarge the OS disk — what we run today.** One flag, Batch Forge keeps managing the pools:

```bash
tw compute-envs add azure-batch forge ... --worker-boot-disk-size 256 --head-boot-disk-size 64
```

Verify it applied — Batch reports `osDisk.diskSizeGb`, and a CE without the flag shows `null`:

```bash
az batch pool list --query "[].{id:id,diskGB:virtualMachineConfiguration.osDisk.diskSizeGb}" -o table
```

**(b) Move Docker to the ephemeral disk — better, but needs a manual pool.** Uses the 150 GB of local
NVMe you already pay for with the VM, and it is faster for image-layer extraction. As a Batch **pool
start task**:

```bash
systemctl stop docker && mkdir -p /mnt/docker && rsync -aP /var/lib/docker/ /mnt/docker &&
sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/dockerd --data-root=/mnt/docker|" /lib/systemd/system/docker.service &&
systemctl daemon-reexec && systemctl start docker
```

⚠️ **`preRunScript` cannot do this.** Platform's pre-run script executes in the nf-launch script inside
the **head job**, not as a start task on every worker node. A start task requires a pre-created pool
plus `tw compute-envs add azure-batch manual --compute-pool-name/--worker-pool` — which means taking
autoscale, the verified image pin (§4), node lifecycle and `azcopy` back from Forge.

**Trade-off:** (a) costs a managed disk per node and leaves the free NVMe idle; (b) is free and faster
but hands you the pool lifecycle. (a) also tolerates an image set larger than 150 GB, which (b) cannot.

### ✅ Measured 2026-08-07 — peak OS-disk usage is ~65 GB

Sampled with [`conf/disk_probe.config`](../../conf/disk_probe.config) (opt-in `-c`/`--config`, logs
`df` at the start of every task) across 21 nodes of run `XFwlgZnKvUvpu`:

| | |
|---|---|
| disk size | **246.9 G** (the 256 GB `--worker-boot-disk-size`) |
| **peak used** | **65.2 G — 26%** |
| range | 56.7 G – 65.2 G |
| free at peak | 182 G |

What this does and does not establish:

1. ✅ **256 GB is ample** — ~3.8× the observed peak, 182 G free. 128 GB would also fit; the difference
   is about $0.05/hr across four workers, so there is no reason to trim it.
2. ✅ **The `/mnt` relocation fix is viable** — 65 GB fits well inside the 150 GB ephemeral NVMe, which
   was the untested assumption underneath it.
3. ❓ **The default disk size is still UNKNOWN.** An earlier draft of this section asserted "Azure's
   default is ~30 GB"; that was an **assumption, not a measurement**, and `az vm image show` will not
   return `osDiskImage.sizeInGb` for this image. All that is actually known is that the default was
   *large enough* to run 122/138 and 169/170 tasks before filling — so it sits somewhere near the
   65 GB peak. **A 64 GB default would fit the observed failure timing exactly** (survives most of the
   run, crosses the line at the end), but that is inference.

⚠️ **These numbers are a MULTI-RUN accumulation, not a single run.** The sampled nodes were allocated
**67 minutes before** this run's first task and had already executed a complete 170-task pipeline —
`totalTasksRun` per node was 57/94/80/109, i.e. ~340 tasks across two runs. Consequences:

- Every container image was **already cached** when sampling began, so the first-task reading
  (53.8 G) is **not a baseline** and cannot be used to separate the base OS image from this
  pipeline's images. An earlier draft did exactly that and was wrong.
- The ~11 GB of growth *during* the run is therefore **not** image pulls — more likely container
  writable layers, logs and temp.
- The 65 GB figure is the **more conservative** number for sizing a long-lived pool, since it reflects
  accumulation across runs. Autoscale draining to 0 destroys the nodes and resets it.

**To get a true baseline**, the pool must be cold: let autoscale drain it to 0 (or forge a fresh CE),
then read the *genuine* first task. That gives base OS + one image, and growth from there is this
pipeline's real footprint. ✅ **Done 2026-08-13 — see the cold-pool baseline below.**

⚠️ **`beforeScript` runs INSIDE the container**, not on the node (`hostname` returns a container id,
`/` shows as `overlay`). The reading is still valid because overlay2's `df` reports the **backing**
filesystem — 246.9 G matches the OS disk — but the mechanism is not what it appears.

⚠️ **Under Fusion the work-dir `df` is meaningless**: Fusion presents a synthetic filesystem
(`fusion 8.0P 4.0P 4.0P 50% /fusion`). Only the `root:` line is usable on a Fusion CE.

⚠️ **The probe's `mnt :` line is useless too** — a Docker task container has no `/mnt` bind, so
in-container `df /mnt` falls back to `/` and duplicates the `root:` line (measured 2026-08-13).
The host's ephemeral disk is visible only through the `work:` line, because the task sandbox
(`/mnt/batch/tasks`) actually lives on it.

### ✅ Measured 2026-08-13 — COLD-pool baseline: base ≈ 45 G, pipeline adds ≈ 15 G

Run `18wEWW90THA2Ek` (`ottilie-pilot-coldprobe-01`): the **full-depth 4-sample ottilie pilot**
(~11× the test set's input data) on a freshly forged CE (`yAMP-ce-coldprobe-256`, since deleted), so
every node was genuinely cold. 310/310 tasks, 0 failed; all 310 `.command.log`s harvested, not a sample.

| | |
|---|---|
| **cold base** (first task on each fresh node, 13:28Z) | **45.4–45.5 G** of 246.9 G |
| **peak** (end of run) | **60.0 G — 24%** |
| growth over the run | ≈ 14.6 G, stepping up as each new process type first pulls its image |
| task work-dir disk (`/dev/sdb1`, 146.6 G ephemeral) | **max 2.7 G** |

What this settles:

1. **The warm figure's split.** Of the 65.2 G warm peak, ~45 G is the **base OS image** — the
   `ubuntu-hpc 2404` stack costs that much before a single pipeline image is pulled. This
   pipeline's images + container writable layers add only **~15 G**.
2. **Images dominate; `/` usage does not scale with input data.** Running ~11× the data produced a
   *lower* single-run peak (60.0 G cold) than the test set's two-run warm accumulation (65.2 G),
   and the growth curve steps at process-phase boundaries (image pulls), not with data volume.
3. **Sizing: 128 GB would be comfortably sufficient** (>2× the observed peak); 256 GB is 4×.
   And the "~64 GB default" inference in the 2026-08-07 entry gets stronger: base 45 G + images
   15 G ≈ 60 G — exactly the shape of a default-sized disk surviving most of a run and filling
   near the end.
4. **The `/mnt` relocation fix has more headroom than assumed** — only Docker's ~15 G would move
   (the 45 G base is the OS image itself, not `/var/lib/docker`), and task scratch peaked at
   2.7 G, so the 150 G ephemeral disk is ample for both.
5. ❓ **Whether Fusion's cache competes for `/mnt` is still open** — this was a non-Fusion run, and
   the probe cannot see the host's `/mnt` from inside a container anyway (see the ⚠️ above).
   **Interim monitoring:** attach `--config conf/disk_probe.config` to routine **Fusion dev runs**.
   The `root:` line is still valid under Fusion, so if Fusion's cache lands on the OS disk it shows
   up as `/` usage well above the ~60 G non-Fusion ceiling; a flat `root:` means the cache lives
   somewhere the probe cannot see (host `/mnt` or memory), which needs a node-level measurement
   (pool start task or a native, non-container Batch task running `df`). ⚠️ Only on runs where
   losing `-resume`/cache reuse is acceptable — the probe perturbs task hashes — and never on a run
   whose outputs you intend to byte-compare against a no-probe baseline run's task cache.

```bash
az batch node reboot --pool-id <pool> --node-id <node> --node-reboot-option terminate
```

⚠️ `az batch node delete` is **rejected while autoscale is enabled** (`Remove VMs not allowed when
AutoScale is enabled`). ⚠️ And a rebooted node can report `state: running, errors: null` and return to
`unusable` minutes later — **never declare a pool healthy from a single sample.**

---

## 10. A Seqera Platform head job **cannot survive a restart** — isolate it with `--dual-pool`

**Symptom.** The workflow is `FAILED` with **zero failed tasks** (seen at 122/138 and 169/170), and:

```
ERROR ~ Unable to access config file 'https://api.cloud.seqera.io/ephemeral/…'
        -- Cause: Server returned HTTP response code: 403
```

**Why.** Platform passes launch parameters to the head job through an **ephemeral, single-use URL**.
When the head job's node dies — §9 — Batch reschedules the head task, the replacement re-fetches that
URL, and gets **403**. A recoverable node failure becomes a total run loss near completion.

Tell-tale: the surviving Batch task ran for ~14 seconds with `retryCount: 0`, while the workflow had
been running for 20+ minutes. That short-lived task is the *replacement*, not the original.

```bash
az batch task list --job-id nf-workflow-<runId> \
  --query "[].{state:state,retries:executionInfo.retryCount,exit:executionInfo.exitCode,
               start:executionInfo.startTime,end:executionInfo.endTime}" -o json
```

**Fix: `--dual-pool`.** The head job gets its own pool, so a worker-side disk failure can no longer kill
it. It is also *cheaper* — the head sits on a `Standard_D2s_v3` instead of an `E4ds_v4`.

⚠️ **Dual pool requires explicit per-pool VM counts.** `--vm-count` is single-pool only; omitting the
per-pool flags fails with `Missing VM count parameter for head pool`, despite the help text claiming the
head count defaults to 1.

### 🚨 A dual-pool CE defaults to NO autoscale — create it with `13_create_compute_env.sh`

**Measured cost of getting this wrong: ~$66/day.** `tw compute-envs add azure-batch forge --dual-pool`
**omits `autoScale` from the request** unless you force it, so Platform stores null and Azure builds
**`enableAutoScale: False`** — fixed size, running 24/7 whether or not anything is queued. Reproduced
deliberately on 2026-08-07 with a throwaway CE, so it is repeatable CLI behaviour, not a one-off. Ten
nodes (8× `E4ds_v4` + 2× `D2s_v3`) ran idle for hours before it was noticed: ~$2.75/hr compute plus
~$324/month of managed disks. Upstream: [seqeralabs/tower-cli#658](https://github.com/seqeralabs/tower-cli/issues/658),
fix in [#659](https://github.com/seqeralabs/tower-cli/pull/659) — **unmerged as of 2026-08-11**, and
0.38.0 is the latest release, so there is no version to upgrade to.

The `--help` offers **only flags to DISABLE** autoscaling — `--no-auto-scale`, `--head-no-auto-scale`,
`--worker-no-auto-scale` — which reads as "enabled by default". For **single-pool** that is true
(`autoScale: true`, pools sit at 0 nodes). For **dual-pool** it is not, and nothing warns you.

**Use [`13_create_compute_env.sh`](../../deploy/azure/seqera-sp/13_create_compute_env.sh)** — it
`tw compute-envs import`s a readback of a known-good CE, which carries `autoScale: true` verbatim, then
runs the verifier. Both the web UI and the import route set the field correctly, so this is a CLI
**default**, not a Platform limitation.

> ⚠️ **Correction (2026-08-11).** This section previously said `tw` *cannot* set autoscale and that the
> **web UI** was therefore required. Both halves were too strong. `add ... forge` **can** set it via
> explicit `--head-no-auto-scale=false --worker-no-auto-scale=false` (undocumented in `--help`, verified
> by payload inspection), and the UI is no longer needed. Keep using the script anyway: `add ... forge`
> has **no flags at all** for `jobMaxWallClockTime`, `deleteJobsOnCompletion`, `deleteTasksOnCompletion`
> or `terminateJobsOnCompletion`, so a flag-built CE silently takes Platform defaults for the four
> job-lifecycle settings our CEs pin (`7d` / `never`). Fixing autoscale that way would trade a loud bug
> for a quiet one.

⚠️ **Compute environments are IMMUTABLE.** A fixed-size CE cannot be patched; the only fix is delete
and recreate. **Verify the readback before running anything:**

```bash
curl -s -H "Authorization: Bearer $TOWER_ACCESS_TOKEN" \
  "$API/compute-envs/<ce-id>?workspaceId=<ws>" | python -c "
import sys,json; f=json.load(sys.stdin)['computeEnv']['config']['forge']
print(f['headPool']['autoScale'], f['workerPool']['autoScale'])"     # must print: True True

az batch pool list --query "[].{cur:currentDedicatedNodes,auto:enableAutoScale}" -o table
```

If it is already wrong, stop the billing first — `az batch pool resize --pool-id <pool>
--target-dedicated-nodes 0` — then delete the CE, which disposes the pools *and* their managed disks.

⚠️ **A new pool always shows 1 node for ~5 minutes; that is not a fault.** The Forge autoscale formula
hardcodes the first interval: `$TargetDedicatedNodes = lifespan < interval ? 1 : targetPoolSize`. So
`1 + 1` right after creation proves nothing — **`0 + 0` fifteen minutes later** is what proves
autoscale works. Confirmed unrelated to Wave/Fusion: a duplicate CE with both disabled behaves
identically.

⚠️ **`--worker-vm-count` is a CEILING under autoscale, not an allocation.** The autoscaling CE
provisioned 1 + 1 and scales toward 4 as tasks queue; the fixed-size one went straight to 1 + 4 and
stayed there.

⚠️ **Dual pool starts slower** — measured **4 min** (single-pool) vs **~17 min** for the head pool to
provision. The head job waits on its *own* VM allocation rather than using whichever shared node came up
first; worker nodes sit `idle` meanwhile. Cold-start only. `--head-no-auto-scale` keeps a head node warm
at the cost of a `D2s_v3` running continuously.

> **`--dual-pool` alone is not sufficient** — it does not stop workers filling up, it only stops that
> from killing the run. §9 is the load-bearing fix; §10 is the safety net. Use both.

**Also transient, and unrelated:** `Unable to access config file … Connection timed out` with
`start: None` and no Nextflow version reported. That is the head job failing to reach Seqera's API at
startup — network-level, before any path is resolved. Retry.

The same failure has a second face that reads like a mistake in your parameters (2026-10-01, run
`GJbeDu3B5XZqX`): `Cannot parse params file: https://api.cloud.seqera.io/ephemeral/<id>.yaml`, again
with no start time, no commit and no Nextflow version on the run. Nothing was parsed: the head log
(`GET /workflow/<id>/download?fileName=nf-<id>.log`) shows `java.net.ConnectException: Connection
timed out` under `CmdRun.readYamlFile`, 2 min 13 s after the repository was cloned — and 2 min 27 s
after the *same host* had served the SCM config to the same process. The identical params were
accepted on the relaunch minutes later. Read the head log before touching the params; then retry.

---

## 11. Platform-vs-local output differences that are NOT regressions

> Generalised, with normalisation recipes for each class and the 3-tier comparison method:
> [`output_comparison.md`](output_comparison.md). This section is the Azure-specific summary.

Comparing a Platform run against the local-head-job baseline, 464 of 529 common files were byte-size
identical and **all 9 cohort deliverables were byte-identical by md5**. The rest classify as:

| Difference | Cause |
|---|---|
| MultiQC plot renders (pdf/png/svg), `multiqc_data` | render non-determinism — already in `tests/.nftignore` |
| igv-reports HTML | `sessionDictionary` is a base64 gzip blob, non-deterministic |
| `.vcf.gz` / `.tbi` ±1–7 bytes | bgzf/gzip framing, `##fileDate`, `##source` |
| CRAM ±1 byte | header metadata |
| `csv/markduplicates_no_table.csv`, `csv/variantcalled.csv` | these **embed the absolute output path**, so a longer `outdir` string changes the byte count |
| `versions.yml` | a run from a **Git clone** appends the short commit (`v1.0.0-g86c4672`); a local-directory run does not |
| `pipeline_info/*` file *count* | timestamped per execution — the baseline has two sets because it was run twice |
| `multiqc_data/snpeff_effects.txt`, `snpeff_variant_effects_region.txt` | MultiQC lists the effect categories of the **last SnpEff report parsed**, and file order differs between ext4 and the Batch node — a MultiQC bug (`output_comparison.md` §2.11), shared cells identical |
| CRAM read-level | identical — but the cloud CRAM's `UR:` is a Batch path, so `samtools view` needs `-T <fasta>` or it decodes nothing and silently hashes empty output |

Re-verified 2026-09-08/09 on the recipe re-cut (run `2W0uOsPYt03NAL`, `RUNBOOK.md`): 477 common files,
240 byte-identical incl. all 14 cohort tables, 42/42 VCFs record-identical, both CRAMs read-identical;
everything else in the classes above.

⚠️ **`contentMd5` is NOT populated on published blobs** (0/534) — Azure stores it only when the uploader
supplies it, and Nextflow's publish path does not. So the "compare blob `Content-MD5` against local md5"
shortcut **does not work**. Compare `contentLength` first, then download and hash the files that matter:

```bash
az storage blob list -c <container> --prefix <run>/ --account-name <acct> --auth-mode login \
  --num-results 10000 --query "[].{n:name,s:properties.contentLength}" -o json
```

⚠️ `##TIDDITcmd` embeds the thread count, so TIDDIT VCFs can never be byte-identical across runs with
different vCPU allocations. Strip that line before comparing.

---

## 12. `NXF_VER` beats the launch UI's "Nextflow version" selector

A run submitted with **26.04** chosen in the launch form's Advanced settings still executed **25.10.4** —
the compute environment's `NXF_VER` environment variable won, silently. `NXF_VER` selects the engine the
launcher self-fetches, and that wins wherever it is set.

Consequence: **you cannot test another engine version from the UI while the CE pins one.** Use a CE
without the env var, or a launch-time `--pre-run` that re-exports it.

`-e NXF_VER=…` is the right delivery mechanism — `tw`'s help states env vars are added to the **Nextflow
head job process** by default, which is exactly where the pin is needed. Confirmed stored as
`{"name":"NXF_VER","value":"25.10.4","head":true,"compute":false}`, and confirmed in effect: the run
reported Nextflow 25.10.4. Nothing on a compute node ever reads it — task wrappers invoke `.command.sh`
via plain bash inside `docker run`, forwarding only `NXF_TASK_WORKDIR` and `NXF_DEBUG`.

---

## 13. A Seqera launch INJECTS some schema defaults, silently overriding your profile

**Symptom.** A Launchpad run using `-profile docker,ottilie_test_az` died with:

```
ERROR ~ No such file or directory: s3://annotation-cache/snpeff_cache/R64-1-1.105
```

…even though the profile sets `snpeff_cache` to an `az://` path, and Platform's own resolved config
for that run *shows* the `az://` value.

**Cause.** Platform submits a params file alongside the launch, and **`-params-file` beats config**, so
anything in it overrides the profile. That params file is not just what you typed in the *Pipeline
parameters* box — the launch form **adds some `nextflow_schema.json` defaults of its own**. For run
`2eiGBEA0NXagap` the box held two lines but four params were submitted:

```
step                'mapping'                                 ← from the box
outdir              'az://aletest/seqera-runs/2026-08-12-01'  ← from the box
snpeff_cache        's3://annotation-cache/snpeff_cache/'     ← INJECTED, schema default
custom_config_base  'https://raw.githubusercontent.com/…'     ← INJECTED, schema default
```

⚠️ **It is not every schema default.** `split_fastq` (default `50000000`) and `genome` (default
`GATK.GRCh38`) were **not** injected, and the profile's values (`0`, `null`) survived. So the rule is
narrower than "schema defaults always win" — which is exactly what makes it dangerous: most profile
params work, and the one that doesn't fails deep into the run.

**Fix.** Any param that has a `default:` in `nextflow_schema.json` **and** matters to the run must be
set in the *Pipeline parameters* box, not only in the profile. There your value replaces the schema
default before the form submits anything. Everything without a schema default is safe in the profile —
`input`, `fasta`, `genbank`, `chr_dir`, `snpeff_db`, `tools`, `joint_germline`, `igenomes_ignore` all
came through untouched on the same run.

⚠️ **`snpeff_cache` is the one that bites here, and it differs per dataset** —
`S288C_reference_test/snpeff_cache` for the contract test, `S288C_reference/snpeff_cache` for the
full-depth pilot. So a single Launchpad entry serving both profiles needs that field edited at launch
time, alongside `outdir`.

✅ **Since 2026-09-07 `snpeff_cache` has NO schema default** — `nextflow.config` sets `null` and the
overlay deletes the upstream `default` (`property_removals` in `conf/schema_overlay.yml`), so the
param has left the injection class: a profile-only value now survives a Launchpad launch. The params
box still carries it because it differs per dataset, not because it must. A launch with no cache at
all now fails at DAG build with `Please specify --snpeff_cache …` (guard in `samplesheet_to_channel`)
instead of in `SNPEFF_SNPEFF` hours later. The rule above still holds for every other param with a
schema default (`joint_manta`, `split_fastq`, `genome`, `generate_reports`, …).

✅ **Since 2026-09-08 `custom_config_base` has NO schema default either** — the same overlay rule.
`nextflow.config` had set it `null` since the nf-core download days, so a local run never fetched
nf-core's institutional configs; but the injected URL made a Platform run `includeConfig`
`nfcore_custom.config` + `pipeline/sarek.config` from GitHub at runtime — a latent local-vs-Seqera
difference that no comparison had caught because those configs happen to be inert for this
pipeline. Setting the URL explicitly still works. With both gone, every schema default now agrees
with `nextflow.config` (49 checked), so the remaining injection class is all no-ops *unless a
profile diverges from the default* — the `joint_manta` case below.

⚠️ **Hiding a param does not protect it from injection** — `custom_config_base` was `hidden: true`
in the stock schema and was injected anyway. So the 2026-09 launch-form trim (the
`conf/schema_overlay.yml` allowlist) changes nothing about this rule: box coverage is the only
guard. The trim did add one member to the §13 class, though: **`joint_manta` now carries a schema
`default: true`** (2026-09-01). Today an injection would be a no-op (pipeline default, profile and
schema all agree on `true`) — but a future launch that sets `joint_manta = false` in a *profile
only* may be silently overridden back to `true`; turn it off in the params box / launch form
instead.

**How to diagnose this class of failure** — compare what was *submitted* against what the config
*resolved to*; they are different objects and only the first wins:

```bash
# what the launch actually submitted (the authority)
curl -s -H "Authorization: Bearer $TOWER_ACCESS_TOKEN" \
  "$API/workflow/<runId>/launch?workspaceId=<ws>" | python -c "
import json,sys; print(json.loads(json.load(sys.stdin)['launch']['paramsText']))"

# what the pipeline config resolved to (informative, but overridden)
curl -s -H "Authorization: Bearer $TOWER_ACCESS_TOKEN" \
  "$API/workflow/<runId>?workspaceId=<ws>" | python -c "
import json,sys; print(json.load(sys.stdin)['workflow']['configText'])" | grep snpeff
```

---

## 14. 🔬 A Launchpad entry pins a BRANCH NAME — its version hash is blind to your repo

**"Launched from `yAMP-ottilie-test-az`" is not a reproducible statement.** The entry stores
`revision: main` — a *name*. Nextflow resolves it to a commit when the run starts, so the same entry,
unchanged, executes different code as `main` moves.

**Measured 2026-08-12.** `main` advanced from `bd4e49a` to `b2c069a` — six commits, including two new
config profiles, a config refactor and a new script — and the pipeline's version hash was **byte-identical
before and after**:

```
before push (bd4e49a)   JHY5OjA0ZjA5MTBkZmI…FiZGVmOTVlNzg4MTg3
after  push (b2c069a)   JHY5OjA0ZjA5MTBkZmI…FiZGVmOTVlNzg4MTg3
```

The hash is content-addressed over the **stored entry** — repo URL, revision *name*, compute env,
profiles, `paramsText`, description — and over nothing else. It answers *"how is this Launchpad entry
configured"*, never *"what code ran"*. A Platform "pipeline version" is likewise a property of the
entry, not of the pipeline source: `yAMP-ottilie-test-az-1` stayed version 1 across all of it.

⚠️ **So do not cite a pipeline name, version name, or version hash as provenance.** Three things that
*are* reliable, in order of preference:

1. **`--commit-id <sha>` at registration** — pins the entry to one commit. Do this for an entry whose
   results you intend to cite as a baseline; leave it unpinned for routine dev entries.
2. **The run's own `commitId`**, resolved at launch and recorded on the run:
   ```bash
   curl -s -H "Authorization: Bearer $TOWER_ACCESS_TOKEN" \
     "$API/workflow/<runId>?workspaceId=<ws>" | python -c "
   import json,sys; w=json.load(sys.stdin)['workflow']; print(w['revision'], w['commitId'])"
   ```
   Run `2eiGBEA0NXagap` recorded `main bd4e49a3b3eacc88373367c6795b93ca1102448b` — the head at that
   moment, which the entry itself never mentioned.
3. **`versions.yml` in the published outdir.** A run launched from a Git clone appends the short commit
   to the pipeline version (`Aletechdev/ALE_Yeast: v1.0.0-g86c4672`), so the outputs carry their own
   provenance in-band. See [`CLAUDE.md`](../../CLAUDE.md) → Pipeline Identity.

⚠️ **The inverse trap:** because the hash does not move, an unchanged hash is **not** evidence that
nothing changed. Re-registering with identical content also reproduces the hash under a *new* pipeline
id — observed three times on 2026-08-12. Compare `commitId`s, never hashes.

⚠️ **Corollary (2026-09-02): a `main`-tracking entry has NO version history in the Platform UI.**
The pipeline view shows one entry with one revision name; pushing to `main` silently retargets every
future launch and leaves no list of "versions" to browse or re-launch — the only per-version record
is each *run's* `commitId` (route 2 above). If picking among versions ever matters — launching v1.0.0
vs v1.1.0, or re-running an old release — the mechanism is **git tags**: the launch form's revision
field resolves branch *and tag* names from the repo, so cutting a tag per release makes versions
selectable at launch with no extra registration; a citable baseline entry should additionally be
registered pinned to the tag (route 1 above). Tracking `main` on the dev/test entry is the deliberate
trade: always-current, never versioned.

---

## 15. 🚨 Platform's run status can be wrong in BOTH directions — and nothing reaps a hung head job

**Observed 2026-08-13, run `1XuapND2cN2oCO`.** Platform showed **`UNKNOWN`**, frozen at 132 succeeded /
9 running. The run had in fact **finished successfully**: the head job's own log ends with
`[Aletechdev/ALE_Yeast] Pipeline completed successfully`, 534 blobs were published, and all nine
cohort deliverables were byte-identical to the `2026-08-06-04` baseline.

**What actually happened.** The head job completed the pipeline and then **hung instead of exiting** —
most likely blocked in the Tower plugin posting its terminal status, which fits the heartbeats stopping
at the same moment (`lastUpdated` froze at 11:47:31Z, the last log line was 11:48:13Z, and the Batch
task was still `running` 40 minutes later). Platform never received the completion event, so it fell
back to `UNKNOWN`.

⚠️ **Cancelling then makes the record wrong the other way.** `tw runs cancel` does reach Azure — the
head task ended `exitCode 137` (SIGKILL) and the pools drained within 5 minutes — but Platform now
records the run as **`CANCELLED`**, for a run whose outputs are complete and verified. So:

| Platform says | Can actually mean |
|---|---|
| `UNKNOWN` | finished successfully but could not report it |
| `CANCELLED` | finished successfully, then someone killed the hung process |
| `RUNNING` | finished; the head job simply has not exited |

**Never treat Platform status as the outcome.** Two sources that are authoritative:

```bash
# 1. the head job's own log — the only place "Pipeline completed successfully" appears
az batch task file download --job-id nf-workflow-<runId> --task-id nf-workflow-<runId> \
    --file-path stdout.txt --destination /tmp/head.txt && tail -3 /tmp/head.txt

# 2. what actually landed (see also output_comparison.md — contentMd5 is NOT populated)
az storage blob list -c aletest --account-name aledata --auth-mode login \
    --prefix "seqera-runs/<outdir>" --query "length(@)" -o tsv
```

⚠️ **Worker nodes going `leavingpool` is not a symptom.** They drain because the work finished — during
this incident that reading looked like a stall and it was the opposite.

🚨 **`jobMaxWallClockTime` does NOT apply to the head job.** `ce_import_template.json` sets `"7d"`, but
Azure reported `P10675199DT2H48M5.4775807S` — .NET `TimeSpan.MaxValue`, i.e. **no limit** — on
`nf-workflow-1XuapND2cN2oCO`. So a hung head job holds its node **indefinitely**; nothing reaps it. The
head pool cannot scale to 0 while a task is `running`, so the node bills until someone notices. Check
after any run that ends in a non-terminal state:

```bash
az batch pool list --query "[?contains(id,'<ce-id>')].[id,currentDedicatedNodes]" -o tsv
```

---

**Second occurrence, 2026-09-28, run `464Scp5QNoznbD`** (the QC-first pair's Resume). The Tower client
logged HTTP retries at 18:51–18:52 (`HTTP/1.1 header parser received no bytes`); Platform showed
`UNKNOWN` from 19:00 while the workflow kept completing tasks and publishing files; the head log ends
`Pipeline completed successfully` at 19:07:37 (136 succeeded, 17 cached, 0 failed) and then stops
after `saving trace file` — the head process hung posting its terminal status, Batch task still
`running` an hour later. Outputs verified identical to the local e2e of the same commit (RUNBOOK
2026-09-28). Two additions to the playbook: `16_watch_run.sh` treats `UNKNOWN` as a grace period
and prints the two authoritative commands; and **`az batch task file download` refuses an existing
destination** (`ERROR: File … already exists`, exit 2 — measured; a poll loop that discards stderr
never sees it), so delete the file before re-downloading, or the "fresh" log is the old one
(13 minutes stale during this incident, which is how a completed workflow looked still busy).

## 16. Corrections — claims that were believed, then disproved

**Read this before re-deriving anything.** Each line is a conclusion that was written down as fact and
later shown to be wrong. They are kept because the wrong answer is reachable from the same evidence
that produced it the first time — deleting them invites a second trip. One line each; the dated detail
is in [`RUNBOOK.md`](../../deploy/azure/seqera-sp/RUNBOOK.md).

| Claimed | Actually | Why it was believed |
|---|---|---|
| `tw` cannot create Entra credentials — only shared-key | `tw credentials add **azure-entra**` does it, present since 0.26.0 | only `credentials add azure` was inspected; the Entra form is a separate subcommand |
| `tw` cannot enable autoscale on a dual-pool CE — use the web UI | `compute-envs import` carries `autoScale`, and `add ... forge` takes explicit `--head-no-auto-scale=false` | only `add ... forge`'s flag list was inspected, then generalised to the whole CLI (2026-08-11) |
| Two runs sharing a pool caused `DiskFull` | a **solo** run exceeds the default disk on its own | the first two failures happened to overlap; concurrency was the visible difference |
| Azure's default Batch OS disk is ~30 GB, so 65 GB overruns it 2× | **unknown** — only bounded near 65 GB by when runs actually failed | plausible round number, never measured; `az vm image show` does not report it for this image |
| Seqera's Outputs tab serves each report in isolation, so an HTML index's relative links are dead there | relative links to **pages** resolve in the preview, and CDN scripts (igv.js, Tabulator) load — the `mutation_reports/index.html` dashboard navigates like a local copy; **downloads** started inside the preview are blocked, because the viewer is an iframe sandboxed without `allow-downloads` (RUNBOOK 2026-09-30) | reasoned from "one file per row"; never clicked (2026-09-11); the download half found by the user (2026-09-30) |
| A task `running` for 29 minutes with no `.command.log` has a hung image pull — cancel the run | the pull was **slow**, not hung: the image's 1 977 MB layer came at 0.36 MB/s (measured from the dev VM on the second occurrence), about 91 minutes in all; the cancelled run would have finished by itself | inferred from "nothing stands between task taken and command started" without measuring the registry; the node could not be read and that was taken as the end of the evidence (2026-10-01, §18) |
| Peak OS-disk use of 65.2 G is a per-run baseline | measured on **warm** nodes (~340 prior tasks), so it is a multi-run high-water mark | the probe was read as if the pool were cold |
| `az://` staged an empty directory — use a tarball instead | all 7 files were present; `find` does not descend a symlink, and Nextflow stages directories as symlinks | the probe reported absence without proving it could detect presence (`find -L` shows them) |
| `beforeScript` runs on the node | it runs **inside the container** | the config's own comment said so; `hostname` returns the container id |
| The org refuses/queues fine-grained PAT requests | approval took **about one day** | an untested assumption that made the classic-PAT stopgap look necessary |
| Upgrading `tw` 0.26 → 0.38 "does not help here" | 0.38 was needed for later work | judged against one immediate blocker only |
| An `org/repo`-form `manifest.name` keeps `nextflow run <name>` viable | `nextflow run` resolves against GitHub, so only the real repo handle runs | see [`CLAUDE.md`](../../CLAUDE.md) → Pipeline Identity |

⚠️ **Four of these ten share one shape** (rows 1, 2, 6 and 9): a subcommand, flag list, or probe was
inspected, the result was correct *about that surface*, and the conclusion was then stated about the
whole tool. When writing "X cannot do Y", name the surface actually checked. Three more (rows 4, 8, 10)
are plain assumptions written in the voice of findings — if it was not run, say so.

---

## 17. The QC-first pair on Platform — launch, resume, watch, download (2026-09-28)

Scripted so that a run is reproducible and recorded, not typed into a form (all in
`deploy/azure/seqera-sp/`): `15_launch_run.sh` launches the Launchpad entry with parameter overrides
or resumes a finished run (`--resume <run id>` = Platform's *Resume*: same session, work dir, CE,
profiles and commit; params replaced), `16_watch_run.sh` prints status transitions until the run ends
and then its task stats, `17_download_outdir.sh` fetches an outdir for a local comparison. Facts
established on the first pair (runs `5m9NorL3JmkHFq` → `464Scp5QNoznbD`, RUNBOOK 2026-09-28):

- **`tw launch --params-file` replaces the entry's params box; it does not merge.** The script
  therefore always sends the committed box plus the overrides. A relaunch pins the original run's
  commit (`-r <sha>` on its command line) even though the entry tracks `main`.
- **Cold start is the head pool.** Both pools' autoscale formulas evaluate every 5 minutes and halve
  the node count whenever nothing is pending; the head pool (D2s_v3, max 1 node) is deallocated within
  ~5 min of a run ending, the worker pool (E4ds_v4, max 4) within ~15. Run 1 waited 10.5 min for a
  head node; run 2, submitted a minute after run 1 ended, was running 2 min later. The head node has
  **two task slots** (`taskSlotsPerNode = 2`), so two head jobs run side by side — run 3 started while
  run 2 was still running — and a QC-only run launched ~15 min ahead keeps both pools warm for a
  launch that must start fast (a demo); a third head job would queue.
- **The Outputs tab lists only files matching `tower.yml`**, and a QC-only run publishes none of the
  dashboard entry points; its report has its own pattern since `702a4c0` (verified through
  `GET /workflow/<id>/reports`: one entry on run `1DtqOzNj59CITv`, none on run 1). Since 2026-09-29
  that pattern is the read-QC report's (*6a*), which every run writes.
- **Downloads inside a previewed report are blocked** — the viewer is `<iframe sandbox="allow-scripts
  allow-popups allow-forms">`, no `allow-downloads`, so a page link opens but a CSV/VCF link does nothing
  (verified 2026-09-30, RUNBOOK). Every downloadable file is therefore its own `tower.yml` entry, served by
  the tab's Download button. The content host's cookie is scoped to the report's folder: relative links
  within `mutation_reports/` work, `../multiqc/` returns 401.
- **The Outputs tab fills while the run is going** (measured 2026-09-29, run `5CiOiON5oJuETn`;
  timeline and numbers in `deploy/azure/seqera-sp/RUNBOOK.md`, same date). The Tower plugin appends
  each publish that matches `tower.yml` to `nf-<id>-reports.tsv` and, when the launch dir is not the
  work dir (Platform), copies that file to the work dir at most once a minute during the run
  (`TowerReports.groovy`, nf-tower 1.17.5 = Nextflow 25.10.4); Platform lists what it finds there.
  So an entry appears within about a minute of its publish while the run is RUNNING; a file published
  in the run's last minute may appear only with SUCCEEDED — it depends on where the one-minute timer
  is (it did on `5CiOiON5oJuETn`, not on `Wxgvs037pXLV8`). Check it on any run by polling
  `GET /workflow/<id>/reports`. How early the read-QC and alignment-QC MultiQC reports are listed:
  RUNBOOK 2026-09-29, run `Wxgvs037pXLV8`.
- **The process list is the whole DAG** — 115 processes for a QC-only and a full run alike, 15 vs 61
  with tasks; the Tasks tab is what ran.
- **The az CLI user login expires under the tenant's 14-day sign-in policy** (it did mid-comparison);
  `17_download_outdir.sh` reads with the pipeline's own service principal through azcopy — client and
  tenant id from the workspace's Azure credential record via the Platform API, secret from
  `~/.config/ale-seqera/sp.env` — and touches no CLI login state. Downloads drop the
  `.azure_blob_dir` marker blobs (85 of the baseline's 569).
- **Resume equals a one-shot run on Platform, measured:** 17/153 tasks cached (all of run 1 but
  MultiQC), the local e2e's task list, and deliverables identical to the local e2e output of the same
  commit (530 names, 145 md5, 42/42 VCFs). Against the 2026-09-08 baseline every name difference is a
  dated `output_comparison.md` §2.10 row plus run 1's own QC-only report folder.

## 18. A task that is RUNNING but has not started — its container image is still being pulled (2026-10-01)

**Symptom.** The run stays `RUNNING`, the task counter stops, nothing fails and nothing is logged.
One process reads `0/1` in `tw runs view --processes`; every other number is final. Platform, the
head log and the Batch node all look healthy.

**What was measured** (run `4xHktQIoVD1t3Z`, 2-sample test set, commit `f6f2f94`; timeline in
`deploy/azure/seqera-sp/RUNBOOK.md`, same date):

- 126 of 155 tasks succeeded, 0 failed, 1 running: `VARIANTFILTRATION_FALLBACK`. Its Batch task was
  in state `running` from 09:26:32Z until it was cancelled at 09:56:03Z — 29.5 minutes. The same task
  took 140 s and 149 s of wall time on runs `Wxgvs037pXLV8` and `5CiOiON5oJuETn` (5 s and 8 s of
  actual work; the rest is the image pull).
- The task's directory on the node held `wd/.command.sh` and `wd/.command.run` and **no
  `wd/.command.log`**. The task's command line is `bash .command.run 2>&1 | tee .command.log`, and
  `tee` creates its file before anything else happens — so the command never started. Batch reports
  a container task as `running` from the moment the node takes it, image pull included.
- The task's image (`community.wave.seqera.io/library/gatk4_gcnvkernel:…`) is used by this one
  process only, so it was the first pull of that image on the node. The node itself was healthy:
  21 of its 22 tasks had succeeded, the previous one seconds earlier, `errors: null`. The registry
  answered from the dev VM (token challenge in 0.1 s).
- Batch's own limits on the task: `maxWallClockTime PT4H` (the process's `time` directive) and
  `maxTaskRetryCount 0`.

**The cause, measured on the second occurrence the same day** (run `4REMpK9OCBKY4z`, same process,
a different node, `running` since 10:35:16Z): the pull was not hung, it was slow. The image is one
2 013 MB manifest of 14 layers, 1 977 MB of it in a single layer. Fetched from the dev VM with curl
(registry token, then the blob URL, which redirects to `community-cr-prod.seqera.io`, a Cloudflare
front):

| What | Speed |
|---|---|
| that 1 977 MB layer, 300 s from the start | 109 MB received — **0.36 MB/s** |
| the same layer, 30 s from the start / 30 s from the 1 GB offset | 0.31 MB/s / 0.41 MB/s |
| the 30 MB layer of the same image, same host | 71 MB/s |
| control, an unrelated 39 MB download | 54 MB/s |

At 0.36 MB/s the layer takes about 91 minutes, against about 2 minutes for the whole pull on
2026-09-29. So one large blob on the registry's backend was being served some 40 times slower than
two days earlier, while small blobs on the same host were fast. Why is not known (Seqera's status
page read "All Systems Operational"). **The first run was cancelled at 29.5 minutes on the inference
that the pull had hung — wrong: it would have finished after roughly 90.** Listed in §16.

Why this process and no other: it was the only one on this image. The 20 other GATK modules of the
3.5.1 tree run `biocontainers/gatk4:4.5.0.0` from quay.io; `gatk4/variantfiltration` was taken from a
later nf-core release and pins the Wave community image `gatk4_gcnvkernel` (GATK 4.6.2.0). Every cold
node that receives this task therefore pulls 2 GB that nothing else on it uses.

**How to recognise it — three reads, no change to anything:**

```bash
tw runs view -i <run> -w <workspace> --processes         # one process at 0/1, the counter no longer moving
az batch job list --query "[?state=='active'].id" -o tsv  # then, for the job named after that process:
az batch task list --job-id <job> --query "[?state!='completed'].{id:id,start:executionInfo.startTime}"
az batch task file list --job-id <job> --task-id <task> --recursive --query "[].name" -o tsv
#   only wd/.command.sh + wd/.command.run, and a start time many minutes old  ->  this pattern
#   wd/.command.log present                                                    ->  the tool itself is running: read the log
az batch task show --job-id <job> --task-id <task> --query containerSettings.imageName -o tsv   # which image
```

Then measure the registry before deciding anything — the pool nodes have no inbound endpoint (private
IP only), so the node's Docker cannot be read, but the registry can be, from any machine:

```bash
R=community.wave.seqera.io; I=library/<image>; TAG=<tag>
TOK=$(curl -s "https://cerbero.seqera.io/auth/token?service=$R&scope=repository:$I:pull" | python -c 'import json,sys; print(json.load(sys.stdin)["token"])')
curl -s -H "Authorization: Bearer $TOK" -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
     https://$R/v2/$I/manifests/$TAG | python -c 'import json,sys; [print(l["digest"], l["size"]) for l in json.load(sys.stdin)["layers"]]'
curl -s -L -m 120 -o /dev/null -H "Authorization: Bearer $TOK" -w '%{size_download} bytes, %{speed_download} B/s\n' \
     https://$R/v2/$I/blobs/<digest of the largest layer>
```

Image size divided by that speed is when the task will start.

A baseline for "many minutes": the same process on an earlier run, from
`GET /workflow/<run>/tasks?workspaceId=<id>&search=<process>` (`duration` vs `realtime`; the
difference is staging plus pull). On the test set no task waits more than about three minutes.

**What to do.** If the arithmetic says the pull ends inside the task's `time` (4 h here), **wait** — a
relaunch starts the same pull again on a new node, as the second run showed. Cancel only when it
cannot finish in time or the registry returns errors: `tw runs cancel -i <run> -w <workspace>` (the
task ended one second later, `TaskEnded`; the head task nine seconds later, exit 137; Platform showed
`CANCELLED`), and `15_launch_run.sh --resume <run>` reuses every completed task. A cancelled run's
node is gone with it, so nothing of the partial pull is kept.

**Fixed for this process the same day:** `VARIANTFILTRATION_FALLBACK` now runs on
`biocontainers/gatk4:4.5.0.0`, the image the other GATK steps already pull, so a cold node pulls
nothing extra for it (`SAREK_MODIFICATIONS.md` → `modules/nf-core/` PATCHED; soft-filtered records
identical on the test set and the 4-sample pilot). The pattern itself stays possible for any large
image on a slow registry — the recipe above is how to tell.

## 19. A path picked in Platform's file browser stops the run at start-up (2026-10-01)

**Symptom.** The run fails minutes after launch with `Status code 400, InvalidResourceName` and
nothing else: 0 tasks, and no start date, commit or Nextflow version on the run page.

**What was measured** (run `5syUy3CSjd3kyO`, 2-sample test set, commit `51356a5`):

- The run's `input` was `az://aledata.aletest/ottilie/v1/samplesheet_test_az.csv`. The Launchpad
  entry's value, and that of every earlier run, is `az://aletest/ottilie/v1/samplesheet_test_az.csv`.
- The Nextflow log ends in `BlobStorageException: Status code 400, InvalidResourceName`, thrown from
  `nextflow.validation.SchemaEvaluator` through `Files.exists`: nf-schema's file-exists check on a
  path parameter, before the workflow starts. The message does not name the path.
- The workspace's three Data Explorer entries are registered as `az://aledata.aletest`,
  `az://aledata.data` and `az://aledata.output` (`GET /data-links`), each attached to both the Entra
  and the shared-key credential.

**The cause.** Platform's Data Explorer writes an Azure container as `az://<account>.<container>`,
because one workspace can hold credentials for several storage accounts. Nextflow has no account in
its paths: a run has one storage account (from the credential) and reads `az://<container>/…`. The
launch form's Browse button inserts Data Explorer's form unchanged (seen in the form by the user, not
reproduced from the API), so Nextflow asks Azure for a container named `aledata.aletest`, and a dot
is not legal in a container name.

**Not a setting of ours.** The credential type does not change it (*inferred*: the same entries
carry both credentials; not run under the shared key). Known upstream since January 2024:
[nextflow#4683](https://github.com/nextflow-io/nextflow/issues/4683) is open, the fix that stripped
the account name ([#4692](https://github.com/nextflow-io/nextflow/pull/4692)) was closed unmerged on
2026-07-10, and the alternative, reading the account from the path, belongs to
[#4445](https://github.com/nextflow-io/nextflow/issues/4445) (multiple storage accounts, open).
Seqera's docs show both forms on separate pages and do not mention the mismatch.

**Fixed on the Platform side (2026-10-06).** Seqera changed the launch form's picker, not Nextflow.
The Seqera Enterprise v26.2 changelog (dated 2026-10-02) reads: *"Fixed a path picked from an Azure
data link in the launch form, for the output directory or a path parameter, including the storage
account (`az://<account>.<container>/…`), which Nextflow cannot resolve. The picker now inserts
`az://<container>/…`, and on an Azure compute environment it disables data links whose credentials
differ from the compute environment's."* Seqera Cloud shipped it in v27.1.0_cycle75 (2026-10-06;
that changelog names only the output directory). Data Explorer still registers the containers as
`az://aledata.<container>` (`GET /data-links`, read 2026-10-28); the conversion happens in the form.
Nextflow is unchanged: #4683 is still open (its last comment, ours of 2026-10-02, has no reply) and
a hand-typed or copied account-prefixed path still fails exactly as below.

**What to do.** Write `az://<container>/…`. Until the fix the recipe was: after picking a file or
folder with the browser, delete `<account>.`; this applied to every path field (`input`, `outdir`,
`fasta`, `snpeff_cache`, `report_gff3`). From 2026-10-02 to 2026-10-28 the launch form said so in the
descriptions of the *Input/output options* and *Reference genome options* sections and under the
`input` field (`conf/schema_overlay.yml`); those warnings were removed once the picker was fixed. The
form could not do more than warn: the one schema rule it checks is also the file browser's filter,
so a rule against the account name disables the browser for every Azure file (§20).

**At start-up (since 2026-10-04).** The five path parameters carry the rule where only parameter
validation reads it: an `allOf` subschema with the pattern `^(?!az://[^/]*\.)` and an `errorMessage`
(`conf/schema_overlay.yml` → `nextflow_schema.json`). A dot is not legal in an Azure container name,
so no valid path is rejected. What the rule changes, *measured* in `-preview` start-ups under the
service-principal credential on 2026-10-04, on the change that introduced it:

| Account-prefixed value in | The run stops with |
|---|---|
| `fasta`, `snpeff_cache` | `* --fasta (az://aledata.aletest/…): "az://aledata.aletest/…" does not match regular expression [^(?!az://[^/]*\.)] (Azure paths read az://<container>/..., without the storage account name: remove '<account>.' from a path picked with the Browse button.)` (the message's tail reads "(the account comes from the compute environment's credential)" since 2026-10-28; the rule is unchanged) |
| `report_gff3` | the same message under `--report_gff3`; *measured* 2026-10-05, a `-preview` start-up of the same kind (the paired start-up with the valid path passed) |
| `input` | the bare `Status code 400, InvalidResourceName`, as before. nf-schema's samplesheet check (`SchemaEvaluator`) asks Azure whether the file exists, and the exception leaves validation before any error is listed |
| `outdir` | the bare 400, as before. The nf-prov plugin (`ProvHelper.checkFileOverwrite`) reads the output path when the session starts, before the pipeline script |

Valid `az://<container>/…` paths pass (same runs), and so do the local paths of the `ottilie_test`
profile and the `https://` paths of `ottilie_test_ci`. `s3://` and `gs://` paths are not touched:
their bucket names may hold dots.

## 20. What the launch form checks from the schema, and what it ignores (2026-10-04)

**Why it was looked at.** §19: the aim was a field that turns red when the browser has inserted an
account-prefixed Azure path. The form cannot do that. The attempt also showed how the form reads
`nextflow_schema.json` in four other respects.

**How it was tested.** A Launchpad entry pins its revision (§14), so a schema that is not on `main`
is seen through a copy of the entry whose revision is a branch. The entry `yAMP` was copied in the
UI, the copy was pointed at a preview branch, and three schema variants were pushed to that branch
in turn. `GET /pipelines/<pipeline id>/schema?workspaceId=<workspace id>` returns the schema Platform
serves for an entry, so each push was read back before the form was opened. That endpoint ignores a
`revision` query parameter: it always answers for the entry's own revision. Everything in the middle
column below was seen in the browser by the user; nothing was launched.

| In the schema | What the form does | Evidence |
|---|---|---|
| `pattern` on a parameter | A typed value that fails it turns the field red, with a warning | *measured*: variant 1, the rule inside `pattern` |
| the same `pattern`, in the file browser | The *Data Explorer* tab tests each file against it in its own notation, `az://<account>.<container>/…`, prints "The selected file must match the pattern specified in the pipeline schema" with the regex, and greys out *Select* on every file that fails | *measured*: variant 1, every file under `az://aledata.aletest` unselectable |
| `allOf`, `anyOf`, `oneOf`, `not` on a parameter | Nothing: no red field. The field keeps its look and its Browse button | *measured*: variant 2 (`allOf` on five fields) and variant 3 (one keyword per field: `allOf`, `anyOf` and `oneOf` with a `type`, `anyOf` without one, `not`), an account-prefixed path in all five fields |
| `errorMessage` | Not established for the form. At start-up nf-schema 2.2.1 appends it in parentheses to an error raised in the same (sub)schema | start-up *measured* (§19) |
| Markdown in a section's `description` | Rendered: code spans show as code | *measured* |
| Markdown in a parameter's `description`, the line under a field | Printed as typed: the backticks show | *measured*: 18 of the 32 visible fields had them |
| a section's `help_text` | Printed under the section's description, always on screen | *measured*: *Input/output options* |

Whether a red field also blocks the *Launch* button was not checked. Seqera's documentation says the
form "blocks the launch if validation fails".

**What follows.**

- **A browsed Azure path cannot be flagged in the form.** The only rule the form checks is the
  field's `pattern`, the browser uses the same `pattern` as its file filter, and both test the same
  account-prefixed string. A rule that turns the field red therefore also disables *Select*.
  Decision (user, 2026-10-04): no rule in the form, the browser stays usable, the warning texts
  stay, and the rule sits in an `allOf` subschema for start-up (§19).
- **`pattern` is the browser's file filter.** It is what makes `input` offer only `.csv` files.
  `report_gff3` has a pattern since 2026-10-04 (`^\S+\.gff3?$`); its effect in the browser has not
  been looked at yet.
- **Keep Markdown out of the line under a field.** `strip_description_backticks` in
  `conf/schema_overlay.yml` removes backticks from the description of every visible parameter. Help
  texts were left alone: how the form shows them was not looked at.
- **A section's `help_text` is not a tooltip.** Upstream's iGenomes paragraph was on screen in
  *Reference genome options* for that reason. It moved to the help text of the hidden `genome`
  parameter (`group_removals` in the overlay). The one line of *Input/output options* ("Specify
  input samplesheet, step and output folder.") repeated the section description and was dropped with
  the same key on 2026-10-05; no section with a visible field carries a `help_text` since.
- **To look at a schema change before it is on `main`:** push it to a branch, copy the Launchpad
  entry, set the copy's revision to the branch, read the schema back with the call above, open the
  form. Delete the copy and the branch afterwards.
