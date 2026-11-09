# Compute resources & deployment

How the pipeline is fitted to a machine — the dev VM, another VM, or Seqera cloud. This is the
authoritative reference for the resource config; older docs may still mention the pre-relocation
`bin/nextflow.config` path.

## The three run contexts — at a glance

The pipeline is configured for three execution contexts. **They are not in the same state of
validation** — read the Status row before relying on any of them.

| | **Local** | **Cloud** (Seqera / Azure Batch) | **nf-test** |
|---|---|---|---|
| **Launch** | `bin/test_ottilie.sh`, or `nextflow -c <machine>.config run main.nf -profile …,docker` | Seqera launch form (repo + revision + params) | `nf-test test -c tests/nf-test-ottilie.config` |
| **Resources** | `conf/azured4as.config` (`-profile azureD4as`, dev VM only) **or** `conf/mymachine.config` copied per machine | `conf/base.config` (E4ds_v5, clamp **28 GB**) + the Seqera **compute environment** | `tests/ottilie_nftest_resources.config` (clamp **14 GB**, via nf-test `configFile`) |
| **Executor pool** | dev VM: yes (4 cpu / 14 GB). Template: none — host auto-detect | Azure Batch owns it (no local `executor`) | none — host auto-detect |
| **Per-task tuning** | dev VM only | `base.config` labels | none — `base.config` labels, then clamped |
| **Engine / extras** | `-profile docker` | `-profile docker` + optionally paste `conf/seqera_azure.config` (sets `custom_config_base = null`, docker UID/GID) | `-profile ottilie_test,docker` |
| **Nextflow pin** | ✅ `NXF_VER=25.10.4` in both launch scripts | ❌ **none** — see gap 2 | ❌ none — uses the shell's engine |
| **Status** | ✅ **validated** — ottilie e2e green | ⚠️ **configured, never executed on cloud** | ✅ **validated** — green, determinism proven |

### Cloud gaps to close before trusting a Seqera run

Cloud validation is deliberately **post-v1.0.0**; the docs claim only the proven local path. Three
concrete gaps:

1. **Never actually run on Seqera.** The blob-hosted test data is published and *local-download*
   verified, but remote staging of the two **directory** params (`snpeff_cache`, `chr_dir`) is
   unproven — that is the fiddly part, and the reason a cache-only tarball was published alongside
   the live directory tree.
2. **No Nextflow version pin reaches the cloud.** Seqera sets the engine version at the **compute
   environment** level, so `export NXF_VER=` in a launch script does not apply. The manifest guard
   `nextflowVersion = '!>=24.04.2, <26.0.0'` is only a **secondary** net and does **not** fire on
   26.x: the strict-config parse error happens *before* Nextflow reads the manifest, so you get
   `Cannot read project manifest -- Config parsing failed` rather than a clean version message.
   ⇒ **Run on a Seqera 25.3.x compute environment** (→ Nextflow 25.10.2). Pinning the CE explicitly
   is a tracked post-1.0.0 item. Blocker inventory: [`ale_sarek_upgrade_runbook.md`](ale_sarek_upgrade_runbook.md).
3. **Container registry credential.** `ale-reports` on Docker Hub is public (anonymous pull works),
   but the **ghcr mirror is private** — if you pin ghcr, register a read-only container-registry
   credential in the Seqera workspace. See
   [`generate_index_container.md`](../generate_mutation_report/generate_index_container.md).

Full cloud walkthrough: [`seqera_cloud_deployment_checklist.md`](../seqera_cloud/seqera_cloud_deployment_checklist.md).

## The model: two layers (+ one optional)

Fitting a run to a machine uses two independent mechanisms — **you need both**:

1. **Executor pool** (`executor { cpus; memory }`) — the *total* budget the local scheduler works
   within. Nextflow only runs as many tasks *concurrently* as fit. Stops **over-subscription**
   (starting more tasks than RAM allows → OOM). Local runs only; on cloud the compute environment
   owns this.
2. **`resourceLimits` (the clamp)** (`process.resourceLimits = [...]`) — caps any *single* task's
   request. base.config asks `process_medium = 16 GB`; the clamp lowers it to the ceiling so it can
   actually be scheduled. Stops a **single over-request** (incl. retry escalation `X * task.attempt`
   → 56 GB) from becoming unschedulable.
3. *(Optional)* **per-task tuning** (`withLabel`/`withName { memory }`) — trims requests to observed
   peaks so more tasks pack in. Pure throughput; not correctness. The fragile, machine-specific bit.

Mnemonic: **pool** = don't run too many at once; **clamp** = don't let one ask for more than exists;
**tuning** = pack more in for speed.

## Where the config lives

| File | Role | Applies to |
|------|------|-----------|
| `conf/base.config` | Per-tool requests (labels + names) **and** the default `resourceLimits` — sized for **Azure Batch E4ds_v5 (4 vCPU / 32 GB)**, the cloud pool. | everywhere (the base) |
| `conf/azured4as.config` → `-profile azureD4as` | Local **dev-VM** override: executor pool + `resourceLimits` **14 GB** (16 GB VM − 2 GB headroom) + per-task tuning. | local dev VM only |
| `conf/mymachine.config` | **Template** to copy for any other machine — clamp only, params-free. A `-c` file, **not** a registered profile. | any local machine |
| `conf/seqera_azure.config` | Seqera supplement (disables institutional-config fetch; docker safety net). Pasted into the Seqera "Nextflow config" field. **Not** a profile. | cloud |

Profiles are registered in the main `nextflow.config` `profiles {}` block (e.g.
`azureD4as { includeConfig 'conf/azured4as.config' }`), so `-profile azureD4as` works with **no `-c`**.

## Ensuring a machine can run it through

Two things must hold — one guaranteed, one empirical:

- **Requests fit (guaranteed):** `resourceLimits ≤ machine` ⟹ no task can ever *request* more than
  exists ⟹ always schedulable. Automatic.
- **Actual usage fits (empirical):** the heaviest task's real peak must be ≤ the ceiling. Measure it
  from `pipeline_info/execution_report_*.html` → **peak_rss** per task. The tuning comments in
  `conf/azured4as.config` are exactly these measurements (BWA-MEM 5.0 GB, MARKDUPLICATES 7.1 GB, …);
  for the yeast data all peaks are <8 GB, so 14 GB is comfortable.

Safety nets already in place: `errorStrategy='retry'` with `memory = { X * task.attempt }` (OOM →
retry with more, clamped to the ceiling), and 8 GB swap on the dev VM.

**Hard limit:** if a task's *actual* peak > the ceiling (real human WGS), clamping just OOMs — no
config fixes insufficient RAM. That's the signal to use a bigger machine / cloud. This VM is sized
for the yeast test data.

## Config precedence — what overrides what

Two separate precedence chains matter here. Rows marked ✅ were verified on this repo with
Nextflow 25.10.4; the rest is Nextflow's documented order.

### 1. Where a setting comes from (highest wins)

| # | Source | Notes |
|---|--------|-------|
| 1 | CLI `--param value` | ✅ beats everything below. Pipeline **params only** — not process directives. |
| 2 | `-params-file` | params only. |
| 3 | **`-c my.config`** | ✅ **outranks `-profile`.** Loaded after the project config, so a params-bearing `-c` will silently clobber a profile's `input`/`tools`. Keep resource `-c` files **params-free**. |
| 4 | `nextflow.config` in the launch dir | |
| 5 | `nextflow.config` in the project dir — **this is where `profiles {}` lives** | Within `-profile a,b`, **later profiles win** on conflicts. |
| 6 | `$HOME/.nextflow/config` | |
| 7 | Directives written in the process body (`main.nf`, modules) | See the twist below. |

### 2. How a process directive is resolved (independent of the above)

Not everything that sets `memory` behaves the same way — verified with a probe process declaring
`memory 16.GB` / `cpus 8` in its body:

| Mechanism | Effect on a script-body directive | Result |
|-----------|-----------------------------------|--------|
| `process { withName: 'X' { memory = '1.GB' } }` | **overrides** it | ✅ resolved to 1 GB |
| `process { resourceLimits = [...] }` | **clamps** it (applied last, to whatever was requested) | ✅ 16 GB → 4 GB |
| `process { memory = '1.GB' }` (unqualified) | only a **default** — the script directive wins | ✅ stayed 16 GB → unschedulable |
| `withName: 'X'` when the task is an alias `Y` of `X` (`include { X as Y }`) | **reaches `Y` too**, unless a selector naming `Y` (or its full path) sets the same directive | ✅ `MULTIQC_READ_QC` ran with `MULTIQC`'s 4 CPUs / 12 GB until it got its own block (2026-09-29) |

**Aliases.** Nextflow resolves `withName` in three passes — the process's original name, then its
alias, then its fully-qualified name — each overriding the one before, directive by directive
(`ProcessConfigBuilder.applyConfig`, Nextflow 25.10.4). Upstream relies on it: `withName: 'GATK4_MUTECT2'`
configures both `MUTECT2` and `MUTECT2_PAIRED`, and each resource block in `conf/base.config` sizes
every alias of its tool alike (31 of the pipeline's 129 aliases take their CPU/memory that way; three
take output settings, all upstream Tier-2 — audit 2026-09-29). So an alias whose needs differ must get
its own block for each directive that differs: the early MultiQC reports have one in
`conf/base.config` (1 CPU / 6 GB — MultiQC is single-threaded, and a 4-CPU request waited for a whole
free slot while the callers ran) and one in `conf/modules/modules.config` (their titles). The same
rule for output settings: `testing_best_practices.md` §5.

**This is why the clamp is the portable knob.** `resourceLimits` is applied *after* every other
mechanism, including the retry escalation `{ 16.GB * task.attempt }`, so it caps requests no matter
where they came from. An unqualified `process { memory }` does not.

### 3. Can it be passed on the command line? **No — `resourceLimits` needs a `-c` file.**

`nextflow run` does accept `-process.<key>=<value>`, but it is unusable here:

- **It cannot express a map.** `-process.resourceLimits='[cpus:2,memory:4.GB]'` is parsed as a
  **String**, and the run then dies with
  `No signature of method: java.lang.String.get() ... values: [memory]` (verified).
- **Even for scalars it only sets a default**, i.e. row 3 of the table above — a module's own
  `memory` directive still wins (verified).

There is also **no `--max_cpus` / `--max_memory` param** in this pipeline: `base.config` hard-codes
`resourceLimits`. Making it param-driven is a deliberate post-1.0.0 item (see the bottom of this page).

So: **a small `-c` file is the supported way to fit the pipeline to a machine.** It's three lines.

## Porting to another machine

**Do not use `-profile azureD4as` on anything but the 16 GB dev VM** — it hard-codes that machine's
ceilings and per-task tuning. Either of the two options below; **`base.config` (the cloud default) is
never touched** in either.

### Option A — clamp-only `-c` (recommended; nothing to author or register)

The **only** thing a new machine strictly needs is the clamp. A ready-to-copy template ships as
[`conf/mymachine.config`](../../conf/mymachine.config) — commented, with the optional executor-pool
and per-task-tuning blocks left commented out. It is deliberately **not** registered in
`nextflow.config`'s `profiles {}` block, so it only loads when you pass it:

```bash
cp conf/mymachine.config conf/$(hostname).config     # then edit cpus + memory
nextflow -c conf/$(hostname).config run main.nf -profile ottilie_test,docker \
    --outdir ./output_ottilie_test --generate_reports
```

Stripped of comments, the load-bearing part is six lines:

```groovy
process {
    resourceLimits = [ cpus: 8, memory: '28.GB', time: '72.h' ]   // vCPUs, RAM − ~2 GB headroom
}
executor {
    cpus = 16                                                      // twice the clamp: a budget, not hardware
}
```

- **Set the CPU budget, leave the memory budget.** `executor.cpus` is what the local scheduler's
  counters start from; twice the clamp means a task that asks for the cap never needs every CPU the
  scheduler believes it has, which is the stall of 2026-11-09 (one lost unit, budget 3 of 4, a 4-CPU
  task stranded). Memory stays at Nextflow's default, the host's RAM, which is what bounds real
  concurrency. (The nf-test path runs the same way; see below.)
- **A params-free `-c` does not clobber profiles.** Verified: with the config above,
  `-profile ottilie_test` keeps its `input`/`tools`/`fasta`. Only add params to a `-c` if you intend
  them to outrank the profile — `-c` wins over `-profile`.
- Same resolved `resourceLimits` and CPU budget as the full `azureD4as` profile, without its memory
  pool or per-task tuning.

### Option B — a named profile (for a machine you'll use repeatedly)

1. Copy `conf/azured4as.config` → `conf/<machine>.config`.
2. Change the two ceilings to the new machine (RAM − ~2 GB headroom, and vCPUs):
   ```groovy
   executor { name='local'; cpus=<2 × vcpus>; memory='<RAM-2>.GB' }   // cpus: a budget above the clamp
   process  { resourceLimits = [ cpus:<vcpus>, memory:'<RAM-2>.GB', time:'72.h' ] }
   ```
   Drop or re-measure the per-task tuning (`withLabel`/`withName`) — `resourceLimits` alone keeps it
   *correct*; the tuning only affects VM throughput and is specific to the old machine's peaks.
3. Register the profile in `nextflow.config`: `<machine> { includeConfig 'conf/<machine>.config' }`.
4. Run `-profile ottilie_test,<machine>,docker`.

> ⚠️ **If you set an `executor` pool by hand, keep `executor.memory / process.memory ≥ 2.`** A pool
> only slightly larger than a single task's request fits exactly one task and can **deadlock** the
> local scheduler ("No more task to compute"). Full symptoms and diagnosis:
> [`docs/usage/nextflow_local_executor_deadlock.md`](../usage/nextflow_local_executor_deadlock.md).
> Option A does **not** sidestep this (an earlier version of this note said it did): with no pool the
> budget is the host, and a task clamped to the host's CPU count still needs all of it. The contract
> test stalled exactly so on 2026-11-09, with one CPU lost from the scheduler's budget; the remedy is a
> CPU budget above the per-task cap (`executor { cpus = <2 × cap> }`), as the nf-test file now sets.

| Machine | resourceLimits memory | cpus |
|---------|-----------------------|------|
| D4as_v5 (16 GB) — `azureD4as` | `14.GB` | 4 |
| D8as_v5 (32 GB) | `28.GB` | 8 |
| Big box (256 GB) | `240.GB` | 32 |

## Seqera cloud — why it's different (and more involved)

> ⚠️ Read **"Cloud gaps to close before trusting a Seqera run"** at the top of this page first — this
> path is configured but has **not** been executed on cloud yet.

On cloud you **do not** use `azureD4as` (its `executor='local'` would pin everything to the head
node). Resources come from **`base.config` + the Seqera compute environment**:

- **Compute environment / Batch Forge** provisions the Azure Batch pool. Batch Forge uses a **single
  VM type per pool** — every task runs on that machine type (default target: **E4ds_v5**, which is why
  `base.config` is sized for it). Pick a bigger machine type for WGS; `resourceLimits` in base.config
  should match (or exceed) that machine so tasks aren't needlessly clamped.
- **`resourceLimits` vs the pool:** on cloud, `resourceLimits` still clamps per-task requests to the
  chosen machine type; the *pool* (concurrency) is Batch's, not a local `executor` block.
- **Container registry credentials:** the report image `ale-reports` is public Docker Hub (anonymous
  pull works), but the **ghcr mirror is private** — register a read-only container-registry credential
  in the Seqera workspace if you pin ghcr. See
  [`generate_index_container.md`](../generate_mutation_report/generate_index_container.md).
- **`conf/seqera_azure.config`:** paste into the Seqera "Nextflow config file" field if the plain
  `docker` profile isn't enough — it disables the nf-core institutional-config fetch (absent in this
  repo) and adds a docker UID/GID safety net.
- **Nextflow version:** run on **25.10.x**; 26.04+ fails to parse `nextflow.config` (see the CHANGELOG
  known-limitations). Seqera's functionality matrix still supports 25.10.x.

For the full cloud step-by-step (compute environment setup, Batch Forge, launch), see
[`docs/seqera_cloud/seqera_cloud_deployment_checklist.md`](../seqera_cloud/seqera_cloud_deployment_checklist.md)
and [`docs/seqera_cloud/azure_batch_recommendations.md`](../seqera_cloud/azure_batch_recommendations.md).

## nf-test resources — clamp, CPU budget, trimmed memory

Running the suite through **nf-test** is a fourth context, and it fits the machine differently from a
`nextflow run`. The ALE tests launch with `-c tests/nf-test-ottilie.config`, which sets
`profile "ottilie_test,docker"` — **deliberately without `azureD4as`**. Their resources come from one
file, `tests/ottilie_nftest_resources.config` (the nf-test config's `configFile`; `tests/qc_gate.sh` and
`tests/nf_coverage.sh` pass the same file with `-c`). It carries three things:

- **The clamp:** `resourceLimits = [cpus:4, memory:'14.GB', time:'24.h']`.
- **A CPU budget above the clamp:** `executor { cpus = 8 }`. A number for the local scheduler, not a
  hardware count: a task that asks for the cap (4) then never needs every CPU the scheduler believes it
  has. Memory keeps Nextflow's default budget, the host's physical memory, which is what bounds real
  concurrency.
- **Memory requests trimmed to measured peaks** (`withLabel` 4 / 4 / 4 / 6 GB for single / low / medium /
  high; by name `GATK4_MARKDUPLICATES` 8 GB, `BWAMEM1_MEM` 6 GB, `CNVKIT_BATCH`, `MULTIQC` and
  `GATK4_CREATESEQUENCEDICTIONARY` 4 GB). The label and the first two name values are those of
  `conf/azured4as.config`; the largest request (8 GB) is about half of the memory budget.

Until 2026-11-09 the file carried the clamp only, and a `process_medium` task asked for the whole
machine (4 CPUs, 14 GB after the clamp). That evening a contract-test run stalled with four such tasks
queued and nothing running, after the scheduler's CPU budget had dropped to 3 of 4: evidence, labels
and the general rule in
[`nextflow_local_executor_deadlock.md`](../usage/nextflow_local_executor_deadlock.md) → *Second
occurrence*. Neither added setting changes what a task receives: `task.cpus`, the thread count handed to
the tools, is untouched, and the contract-test snapshot did not move.

Why a separate file instead of reusing `azureD4as`? nf-test injects its `configFile` as a
**`-c`**, and `-c` outranks profiles. The default `nf-test.config` points `configFile` at
`conf/test.config`, which carries upstream sarek's params (`input`, `genome`, `tools='strelka'`) and
would clobber the `ottilie_test` profile. The fix was a **params-free** `configFile`; `azureD4as` also
brings full-run machinery the test doesn't want (its pool, retries, time limits). This is the precedent
that **Option A** above — the `conf/mymachine.config` template — generalises.

**Two consequences worth knowing:**

- ⚠️ **The test suite never exercises `conf/azured4as.config`.** A regression in that profile — the
  one `bin/test_ottilie.sh` and every dev-VM run depends on — would **not** be caught by `nf-test`.
  Coverage gap, not a bug; validate profile edits with an actual `bin/test_ottilie.sh` run.
- The memory values are a second copy of the `azureD4as` ones. They are sized on the 2-sample test set;
  a larger test set needs them re-measured from its trace (`peak_rss`), as that profile's were.
- Minor drift: the test clamp allows `time: '24.h'` while `azureD4as` allows `'72.h'`. Unintentional
  rather than a decision — harmless for the 2-sample run, but align them if a test ever times out.

**Porting a test run to another machine:** same idea as porting a VM profile, but edit the clamp and
the CPU budget (twice the clamp's `cpus`) in `tests/ottilie_nftest_resources.config` (the
[porting table](#porting-to-another-machine) applies directly). For a CI box that differs from the dev
VM, add a second `tests/ottilie_nftest_resources_ci.config` and a matching
`tests/nf-test-ottilie-ci.config` whose `configFile` points at it — keeping the dev-VM config untouched.

## Summary — the three orthogonal axes

A run = **dataset** × **resources** × **engine**, each an independent profile:

- **dataset:** `ottilie_test` (or your input params)
- **resources:** `azureD4as` (this dev VM only) / a clamp-only `-c` / a new per-machine profile /
  cloud compute environment
- **engine:** `docker` / `singularity` / `conda`

e.g. `-profile ottilie_test,azureD4as,docker` on the dev VM, or
`-c mymachine.config -profile ottilie_test,docker` anywhere else. Porting = swap the **resources**
axis only.

## Post-1.0.0 follow-up (deferred, deliberate)

Make the ceiling a single param (`--max_cpus` / `--max_memory`) that `base.config`'s `resourceLimits`
reads, so porting is two CLI numbers instead of a profile. Deferred because it edits the shared
`base.config` the cloud release depends on, and the nf-test (which uses its own `resourceLimits`)
wouldn't catch a regression — it needs its own cloud + VM validation cycle.
