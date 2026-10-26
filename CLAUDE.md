# NF_ALE Project Notes

> **Maintenance convention.** This file holds operational summaries + pointers into `docs/`; the
> linked doc is the source of detail. When you change pipeline behavior, update **both** the summary
> here and the linked doc so they stay in sync. Keep inline notes to *stable* facts (tool tiers,
> thresholds, paths); push volatile detail to `docs/`. Pointers must resolve even if the target doc
> isn't yet complete.

## Table of Contents
1. [Pipeline Identity & Naming](#pipeline-identity--naming)
2. [Environment Setup](#environment-setup)
3. [Input Configuration](#input-configuration)
4. [Variant Calling Strategy](#variant-calling-strategy)
5. [Implementation Details](#implementation-details)
6. [Tool-Specific Notes](#tool-specific-notes)
7. [Variant Analysis Dashboard System](#variant-analysis-dashboard-system)
8. [Pipeline Merger Decision - Reminder](#pipeline-merger-decision---reminder)

---

## Pipeline Identity & Naming

Two names, and **the identity must match the repo handle**:

| What | Value | Notes |
|------|-------|-------|
| **Brand** (this version) | **yAMP** — *yeast Automated Mutation Pipeline* | Product name; future majors → AMPv3, … Lives in `manifest.description`, and in the Seqera Launchpad entry name (`yAMP` since 2026-10; before that `yAMP-ottilie-test-az`). |
| **`manifest.name`** = **GitHub repo** | **`nnf-bright-biofoundry/ALE_Yeast`** → https://github.com/nnf-bright-biofoundry/ALE_Yeast | Drives the console banner, MultiQC header, versions `id:`, and the Seqera runs view. Also `manifest.homePage`. |

**Keep `manifest.name` equal to the `org/repo` handle.** Two reasons, both learned the hard way
(2026-08-06):

1. **Seqera shows two different names for one pipeline if they diverge.** The runs view displays
   `manifest.name`, but falls back to the **repo-derived** project name when a run dies before parsing
   `nextflow.config` — so a startup failure appears under a different name than a healthy run. With the
   two equal, every run reads the same in every state.
2. **`nextflow run <name>` resolves against GitHub, not against `manifest.name`.** The earlier
   rationale — that an `org/repo`-form `manifest.name` "keeps `nextflow run <name>` viable if ever
   open-sourced" — was **wrong**: `nextflow run Aletechdev/AMP` would clone `github.com/Aletechdev/AMP`,
   which does not exist. Only the repo handle is runnable.

The brand is **not** carried by `manifest.name` — it lives in `description` and in the Launchpad entry,
so it can evolve per version without touching the identity. If an AMP *family* ever materialises, the
clean move is to **rename the repo**, keeping the two in sync, rather than to diverge them again.

> **Status:** `manifest.name = 'Aletechdev/AMP'` was set 2026-07-27 (v1.0.0 prep) and **changed to
> `Aletechdev/ALE_Yeast` on 2026-08-06** for the reasons above. Each change moved exactly one output
> line — `versions.yml`: `nf-core/sarek: v3.5.1` → `Aletechdev/AMP: v1.0.0` → `Aletechdev/ALE_Yeast: v1.0.0`.
>
> **Repo transferred to `nnf-bright-biofoundry/ALE_Yeast` on 2026-10-23**; `manifest.name`, `homePage`, the
> MultiQC header links and summary-section key (`nnf-bright-biofoundry-ALE_Yeast-summary`), the launch-form
> image URLs and the Launchpad entry followed the same day, and the `versions.yml` line moved once more to
> `nnf-bright-biofoundry/ALE_Yeast: v1.0.0`. GitHub redirects the old URL, so older clones and the two
> `worktree-*` branches keep working, but set `git remote set-url origin` to the new handle. Every output
> produced before that date (all baselines listed below) carries `Aletechdev/ALE_Yeast` in `versions.yml`
> and `multiqc_data/` — a known, expected difference.
>
> ⚠️ The **verified Azure Batch baseline** at `az://aletest/ottilie-azurebatch-out/` was produced under
> `Aletechdev/AMP`, so any future comparison against it shows that `versions.yml` line as a known,
> expected difference. Note also that runs launched from a Git clone append the short commit
> (`v1.0.0-g86c4672`) while local-directory runs do not — that is nf-core provenance, not a regression.
>
> ⚠️ **History was rewritten 2026-08-31** (private-data purge before open-sourcing), so every commit
> SHA changed and a Git-clone run now stamps a *different* short commit than the baseline's
> `g86c4672` — one more known-expected `versions.yml` difference. Old↔new SHA map + purge list:
> [`docs/dev-practices/history_rewrite_2026-08.md`](docs/dev-practices/history_rewrite_2026-08.md).

---

## Environment Setup

User-facing install/run instructions live in [`README.md`](README.md); a bare-machine walkthrough is
[`docs/usage/new_machine_setup.md`](docs/usage/new_machine_setup.md). Only the facts a contributor
needs in-session are repeated here.

- **Toolchain**: `conda activate nf-env` (spec: [`environment.yml`](environment.yml) — nextflow 25.10.4,
  nf-test 0.9.3, nf-core 3.5.1, openjdk 17, python 3.13). Use `python`, **not** `python3`.
- **Nextflow version**: run on **25.10.4** — `environment.yml` and the launchers' `NXF_VER` are
  deliberately the same version, so an unpinned shell inside `nf-env` runs the engine everything else
  assumes. Keep them in sync. `NXF_VER` still wins wherever it is set (it self-fetches that engine
  regardless of what conda installed). **26.x cannot parse `nextflow.config`** —
  see [`ale_sarek_upgrade_runbook.md`](docs/dev-practices/ale_sarek_upgrade_runbook.md).
- **What counts as validated (before any commit that can change outputs).** A change under
  `conf/modules/`, `subworkflows/`, `modules/`, `workflows/`, a task script in `bin/`, a report asset under
  `docs/igvreports/` that a `report_*` param in `nextflow.config` hands to a report process (renderer, templates,
  filter config), or a default in `nextflow.config` must run the e2e **contract test** —
  `nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test` (NXF_VER=25.10.4, ~25 min) —
  and every snapshot difference must be explained and re-recorded (`--update-snapshot`) **in the same
  commit** as the code. A launcher run (`bin/test_ottilie.sh`) or a pilot run shows the change's *value*
  but has no snapshot, so it cannot fail; it is evidence, not validation. Say in the commit message which
  of the three ran. Enforced at commit time by [`bin/check_snapshot_staged.sh`](bin/check_snapshot_staged.sh)
  (a Claude Code hook on `git commit`; installable as a git `commit-msg` hook) — it demands the staged
  `.snap` or a `Snapshot: unchanged (…)` trailer, plus `Module test: <name> green` for paths that have a
  unit test, plus `Gate test: qc_gate (a) green` (`tests/qc_gate.sh a`, minutes) for anything under
  `workflows/` or `subworkflows/` — the `--qc_only` starvation gate has no other symptom when broken. Learned 2026-09-02: the SOR_FS commit (`4c45fb8`) was "validated" by launcher + pilot
  only and left the snapshot stale for two days. Loop and rationale:
  [`testing_best_practices.md` §12](docs/dev-practices/testing_best_practices.md#12-what-counts-as-validated--the-contract-test-rule).
- **What counts as reviewed (before any commit).** Run the `commit-review` skill
  ([`.claude/skills/commit-review/SKILL.md`](.claude/skills/commit-review/SKILL.md)): the docs a commit
  must move are derived from *what is staged* — a new module / config / task script / test, a snapshot
  name delta, a changed count, new user-facing behaviour — never from a plan's doc list. Its mechanical
  half, [`bin/check_doc_drift.sh`](bin/check_doc_drift.sh), runs inside the commit gate on every commit:
  the three ADDED inventories in `SAREK_MODIFICATIONS.md`, the gate's test map and the docs index must
  equal the tree. The gate also demands an `output_comparison.md` §2.10 row (or a `Baseline diff:`
  trailer) when the staged snapshot adds or removes output names. Learned 2026-09-28: the
  reference-preflight commit updated every doc its plan named and left five derived copies stale, two
  of them since August.
  [`testing_best_practices.md` §12 → Docs that copy the tree](docs/dev-practices/testing_best_practices.md#12-what-counts-as-validated--the-contract-test-rule).
- **What counts as validated for a *number*** (benchmark tables, concordance rates, the figures that
  end up quoted as fact): commit the analysis script **before** publishing results from it, have every
  published number name the script and run directory that produced it, and label a claim by its
  evidence — *measured* / *inferred* / *assumed* — never upgrading it silently. Learned 2026-09-04:
  "2 real clone-specific rows" was really "2 rows not on my artifact list", and survived two commits
  before a read-level check disproved it. Two further rules added 2026-09-07: **a corrected number has
  copies** — grep for the old value *and its prose phrasings*, since a correction applied to the tables
  left three docs contradicting themselves for three days; and **provenance includes the parameters** —
  the whole SV benchmark is untrimmed-read data because its CRAMs predate `948163c`, so *a default
  change is a provenance event for every number already published*.
  [`testing_best_practices.md` §13](docs/dev-practices/testing_best_practices.md#13-benchmark-claims--provenance-evidence-labels-script-before-numbers).
- **Shared repo state goes in `PLAN_next_checklist.md`, not session memory** — several sessions run in
  parallel and their memories cannot stay consistent about what is committed, pushed or running.
  [`testing_best_practices.md` §14](docs/dev-practices/testing_best_practices.md#14-cross-session-state-lives-in-one-file).
- **Resources**: `-profile azureD4as` is **on dev VM only** (4 vCPU / 16 GB). On any other machine
  copy [`conf/mymachine.config`](conf/mymachine.config) and pass it with `-c` — never reuse
  `azureD4as`. Model + precedence rules: [`compute_resources.md`](docs/dev-practices/compute_resources.md).
- **Apple Silicon is NOT supported** — tools stall/hang under ARM (MultiQC, Mutect2) plus
  filesystem-optimization problems. The `arm,docker` profile is retained for reference only.

### Cloud execution — Azure Batch

Opt-in only: `-c conf/azure_batch.config` (deliberately **not** a profile) plus
`-params-file conf/params_ottilie_test_blob.yml`; launcher `bin/test_ottilie_azure_batch.sh`. Azure service
principal + RBAC provisioning lives in [`deploy/azure/`](deploy/azure/) (per-resource grants only, never
resource-group-wide).

**Status: validated end-to-end for BOTH head-job locations** —
- **Reference baseline (2026-09-08, current recipe — trimming on, no HC hard filter):** Seqera Platform head job, run `2W0uOsPYt03NAL`, 159/159 tasks, 26 min, commit `bc31fd2` → **`az://aletest/seqera-runs/yAMP-out-test-recut-20260908`**. Compared against the local e2e output of the same code: all 14 cohort tables byte-identical, 42/42 VCFs record-identical, both CRAMs read-identical (`RUNBOOK.md` 2026-09-08 entry; classes in `output_comparison.md`).
- **QC-first pair from the updated entry (2026-10-05):** `1VItgFdKPAxaLT` (18 tasks, the entry's `qc_only: true`) → *Resume* `6iO52bvtK9Db7` (155 tasks, 17 cached, 18 min), commit `616f67a`, outdir `az://aletest/seqera-runs/yAMP-qc-first-20261005`; first Platform run of the new schema and of the entry default; outputs present, not compared (`RUNBOOK.md` 2026-10-05, second entry).
- **QC-first pair (2026-09-28):** Platform run `5m9NorL3JmkHFq` (`--qc_only`, 18 tasks / 15 processes) → *Resume* `464Scp5QNoznbD` (17/153 cached; deliverables identical to the local e2e of `e761f66`: 530 names, 145 md5, 42/42 VCFs). Scripts `deploy/azure/seqera-sp/15_launch_run.sh` / `16_watch_run.sh` / `17_download_outdir.sh`; recipe in `docs/usage/qc_first_run.md` → *On Seqera Platform*. Platform showed UNKNOWN while the run completed (`azure_batch_execution.md` §15, second occurrence — decide from the head log and the outdir).
- **4-sample pilot on the current recipe (2026-10-01):** Platform run `1DqSRNsEYo4VCD`, 269/269 tasks, 52 min, commit `cc3ae24` → `az://aletest/seqera-runs/yAMP-demo-pilot-20261001` (profile `ottilie_pilot_az`; launched with a box generated from that profile — the committed box carries the test set's paths). Cohort VCF record-identical (451) and all 10 cohort tables md5-identical to the local pilot of 2026-09-09; first cloud run of the `biocontainers/gatk4` soft-filter image (29 s; 70 min with the old image the same day). `RUNBOOK.md` 2026-10-01 (evening).
- **Superseded baselines:** local head job 2026-08-03 (`az://aletest/ottilie-azurebatch-out/`, 540 blobs, untrimmed + hard filter) and the 2026-08-06 Platform run that reproduced it. Still valid for comparing *older* outputs; see `output_comparison.md` §2.10.
- **Seqera Platform head job** (2026-08-06): 170/170 tasks, **all 9 cohort deliverables byte-identical** to that baseline. Launchpad entry `yAMP-ottilie-tes` in `DTU-Biosustain/RECON-ALE`.

⚠️ **A Platform head job needs a `--dual-pool` CE with an enlarged worker boot disk.** On a single-pool
compute environment it fails at ~98% completion, with **zero failed tasks** — the node's OS disk fills
with Docker images, which kills the head job, and Platform's ephemeral launch config is single-use so
the restarted head job cannot recover. Both halves are required: the disk stops the failure, dual-pool
stops it being fatal. Full detail, plus the better `/mnt` relocation fix:
[`azure_batch_execution.md` §9–§10](docs/dev-practices/azure_batch_execution.md).

📋 **The Outputs tab fills during the run** (measured 2026-09-29, run `5CiOiON5oJuETn`): the Tower
plugin syncs matching publishes about once a minute, so a report published before the end of a run is
readable mid-run. Detail: `azure_batch_execution.md` → Outputs tab.

💰 **Nothing is always on.** The CE's two pools (`tower-pool-<ce-id>-{head,worker}`) autoscale to 0
between runs and cost nothing there; the portal's dashed "Dedicated Core Count (Avg)" line is a sparse
metric artefact, not a node. Three-command idle audit + residual risks (hung head job has no wall-clock
limit): [`azure_batch_execution.md` §8.1](docs/dev-practices/azure_batch_execution.md#81-idle-state-cost-audit--is-anything-always-on).

⏳ **A run that stays `RUNNING` with the task counter stopped and nothing failing** is most likely a
task still pulling its container image: a Batch task `running` for minutes with **no `.command.log`**
in its directory. Seen twice on 2026-10-01 on `VARIANTFILTRATION_FALLBACK` — the only process on the
2 GB `gatk4_gcnvkernel` Wave image, whose big layer was served at 0.36 MB/s (≈ 90 min; 2 min two days
earlier). **Measure the registry before cancelling** — the first run was cancelled on a wrong "hung
pull" inference. That step now runs on the `biocontainers/gatk4:4.5.0.0` image of the other GATK steps
(4th patched nf-core module); the pattern can recur with any large image. Recipe:
[`azure_batch_execution.md` §18](docs/dev-practices/azure_batch_execution.md#18-a-task-that-is-running-but-has-not-started--its-container-image-is-still-being-pulled-2026-10-01).

📁 **A path picked with the launch form's Browse button must be edited before launching.** Platform's
file browser inserts Azure paths as `az://<account>.<container>/…`; Nextflow reads `az://<container>/…`
only, so the run stops at start-up with a bare `Status code 400, InvalidResourceName` (run
`5syUy3CSjd3kyO`, 2026-10-01). Delete `<account>.`. Not a setting of ours and not credential-dependent:
nextflow#4683, open since 2024. The launch form carries the warning (two section descriptions and the
`input` field, `conf/schema_overlay.yml`) **and cannot do more** (measured 2026-10-04): it checks
only a field's own `pattern`, and its file browser greys out *Select* on every file that fails that
same pattern, so a rule against the account name disables Browse for every Azure file; `allOf` /
`anyOf` / `oneOf` / `not` on a parameter are ignored by the form. The rule therefore sits in an
`allOf` subschema that only start-up validation reads: a readable error for `fasta`, `snpeff_cache`
and `report_gff3`, while `input` and `outdir` still stop with the bare 400.
[`azure_batch_execution.md` §19](docs/dev-practices/azure_batch_execution.md#19-a-path-picked-in-platforms-file-browser-stops-the-run-at-start-up-2026-10-01) ·
what the form reads from the schema, and how to preview a schema change on a branch:
[§20](docs/dev-practices/azure_batch_execution.md#20-what-the-launch-form-checks-from-the-schema-and-what-it-ignores-2026-10-04).

⚠️ **Seqera clones from GitHub over HTTPS only** — an SSH deploy key cannot be used for a pipeline
repository, so a *private* repository needs a GitHub App or PAT credential. The repo has been public
since 2026-09-04 and **since 2026-10-26 the workspace holds no GitHub credential**: Platform clones the
public repo anonymously (verified by run `4tiNtBjO5ozg2y`); a credential would only raise the launch
form's GitHub API rate limit. If the form ever fails on that limit, the way back (a token owned by the
`nnf-bright-biofoundry` org, or a GitHub App) is in
[`deploy/azure/seqera-sp/RUNBOOK.md`](deploy/azure/seqera-sp/RUNBOOK.md) → *GitHub PAT*.

⏰ **Credential expiry is watched by a SessionStart hook** — `.claude/settings.json` runs
[`bin/check_credential_expiry.sh`](bin/check_credential_expiry.sh) at the start of every Claude Code
session. It stays silent until a tracked credential is within its warning window (Azure SP secret
**2027-07-31**, sister-SP secret **2027-08-14**, both 60-day lead; no GitHub token since 2026-10-26;
plus any pending one-off rotations).
**When a warning appears, treat it as the session's first priority.** After any rotation, update the
script's dates and [`deploy/azure/seqera-sp/RUNBOOK.md`](deploy/azure/seqera-sp/RUNBOOK.md).

🔑 **Secrets live in `~/.config/ale-seqera/sp.env`** (mode 600, outside the repo; written once per
machine by [`deploy/azure/seqera-sp/10_store_secret.sh`](deploy/azure/seqera-sp/10_store_secret.sh)):
the Azure SP secret and the Seqera token (`TOWER_ACCESS_TOKEN`, duplicated as `SEQERA_ACCESS_TOKEN`).
On the dev VM `~/.bashrc` exports **only the token** into every shell, so `tw` and `seqera` work
without setup; `source deploy/azure/seqera-sp/00_vars.sh` loads both secrets plus the Azure
identifiers for Batch runs. Setup on a new machine:
[`new_machine_setup.md` §9](docs/usage/new_machine_setup.md#9-optional-seqera-platform-and-azure-batch-credentials).

**Before changing any Azure setting, read the orientation section** —
[`azure_batch_execution.md` → why this config isn't the five-line example](docs/dev-practices/azure_batch_execution.md#orientation--why-this-config-isnt-the-five-line-example).
Only 4 settings differ from the stock tutorial config (auth, `vmType`, image pin, `workDir`
placement); 3 are forced by the account or by the service-principal auth, not chosen. The
non-obvious rules, each learned by running it — full detail in the same doc:

- **With an Entra/SP credential, `workDir` must be in the same blob *container* as the inputs** — same
  storage account is not enough. Nextflow mints **one** container-scoped SAS (`sr=c`) for the work-dir
  container and reuses it for every blob URL, so a Batch node cannot read another container even in the
  same account; the task exits 1 with empty stderr. **This tracks the CREDENTIAL, not local-vs-cloud** —
  a shared-key credential gives nodes account-wide access and has no such rule (verified: the
  `aledev4test_e4ds_v4` CE runs `workDir` and inputs in different containers). Granting the SP more RBAC
  does **not** help: it already holds `Storage Blob Data Contributor` on the whole account; the limit is
  what Nextflow *delegates*, not what the SP *may* do — **no SP-side bypass exists; the only lever is
  switching to a shared-key credential**, which works (verified 2026-08-04) but hands every node
  account-wide access. **Fusion does not lift it either** (verified
  2026-08-13 — same rejected SAS through the FUSE path, though the 403 is at least visible in
  `.command.err`/`.fusion.log` there). **`outdir` is exempt** — `publishDir` runs in the head process
  using the full credential (verified locally and, for `pipeline_info/` publishes, under Platform).
- **Every declared input path must exist.** `file('SENTINEL')` for a missing file works locally
  (symlink) but fails on a remote work dir, which must physically copy. Use `checkIfExists: true`.
  `projectDir` assets are fine — nf-core relies on them too.
- **Pin the newest `verified` `ubuntu-hpc` LTS**, named by node *agent* SKU (`batch.node.ubuntu 24.04`),
  not image sku. Nextflow's default (22.04) has aged out service-wide — re-pin at each LTS. Stay on
  `ubuntu-hpc`: the only verified family with a container runtime.
- **Pool ids are content-addressed** (`nf-pool-<hash>-<vmType>` over the `pools` block), so
  `deletePoolsOnCompletion` breaks `-resume`. Idle pools cost nothing; keep them.
- **Bare `-resume` resumes the *last* run in `.nextflow/history`** — any `-preview` or unrelated test in
  the same directory hijacks the chain. Pass an explicit session id.
- **Optional file params must be passed as `[]`**, never `null` (`file(null)` throws while the DAG is
  built) and never a placeholder filename (fails to stage on a remote work dir). This bit
  `report_gff3`, which aborted with a bogus "sample-sheet only contains tumor-samples" error until it
  was made properly optional (2026-08-04). The dangling `ifEmpty` that produces that misdirection is
  still there for *other* early aborts — [`troubleshooting.md`](docs/dev-practices/troubleshooting.md).

---

## Input Configuration

### Key Files and Locations

- **Test data (ottilie)** — the release test set: 2 samples (parent + evolved), 4 chromosomes; truth =
  4 SNVs + a chr I duplication. Lives under `data/ottilie/` (gitignored). Profile:
  [`conf/test/ottilie_test.config`](conf/test/ottilie_test.config) → run
  `nextflow run main.nf -profile ottilie_test,azureD4as,docker`. Generate locally with
  `docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/generate_test_data.sh`; on a fresh machine
  fetch from the public blob (no creds) with `download_test_data.sh`. Full lineage/prep:
  [`docs/benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md`](docs/benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md).
- **Launchers**: `bin/test_ottilie.sh` (minimal 2-sample test) · `bin/test_ottilie_blob.sh` (same test, `ottilie_test_ci` profile — inputs streamed from the public blob, **no local `data/ottilie/`**; `snpeff_cache` is a directory param and can't come from an https URL, so the script untars the published `snpeff_cache.tar.gz` locally first) · `docs/benchmarking/ottilie_xenobiotic_ale/03_pipeline/run_ottilie_pilot.sh` (full-depth **4-sample** run, same S288C data). The 2-sample test set is a **chromosome subset** (chr I/IV/VII/XV) of **2 of** the pilot's 4 `--save_mapped` CRAMs, extracted by `generate_test_data.sh` — not a read-subsample. Both use `-profile azureD4as,docker`.
- **Resources config**: [`conf/azured4as.config`](conf/azured4as.config) (the `azureD4as` local-VM profile;
  use `-profile azureD4as`, no `-c` needed). See [`docs/dev-practices/compute_resources.md`](docs/dev-practices/compute_resources.md).
- **SnpEff cache generation**: `docs/prepare_input/process_GeneBank/process_genbank_auto.sh` (GenBank in) or
  `docs/prepare_input/build_snpeff_cache.sh` (FASTA + GFF3 in) — user page
  [`docs/usage/prepare_reference.md`](docs/usage/prepare_reference.md). `gen_cache.sh` retired 2026-09-08
  (hard-coded dev paths). snpEff **5.1** only; flat `<db>/` layout; `snpeff_cache` has **no default**.
- **Fork base**: nf-core/sarek 3.5.1 — the fork tree lives at the **repo root** (`main.nf`, `conf/`,
  `workflows/`, `modules/`, `subworkflows/`); consult the upstream 3.5.1 docs for base behavior.
  For diffing against pristine 3.5.1, fetch it per `docs/dev-practices/SAREK_MODIFICATIONS.md` (`nf-core pipelines
  download sarek --revision 3.5.1`, or single files from `raw.githubusercontent.com/nf-core/sarek/3.5.1/<path>`);
  no worktree of it is kept.
- **Production/example data (CENPK, dicarboxylic acids)** — real-experiment dataset, not the test set:
  `https://aledata.blob.core.windows.net/aledata/Yeast/dicarboxylic_acids_all_clones/REDACTED-CUSTOMER-ID/ANP_Dev_2025Q3/data/`

### Sample Table Format

Canonical column reference, conventions, and non-Tier-1 notes:
[`docs/usage/input_samplesheet.md`](docs/usage/input_samplesheet.md). A worked example is in
[`README.md`](README.md). The **ALE-specific invariants** worth knowing without opening either:

- **All samples are normal (`status = 0`), and the column is optional.** The schema default is `0`, so
  the recommended sheet leaves it out (2026-10-06; verified to parse and build the same DAG as the test
  sheet). `0` is what puts HaplotypeCaller in joint-germline mode. Tumor/`1` is unused; tumor-only mode
  is a deferred fork idea ([`docs/archive/sarek_fork_ideas.md`](docs/archive/sarek_fork_ideas.md)).
- **`experiment`** maps to Sarek's `patient` and groups samples for joint calling.
- **`ploidy`** and **`clonal_or_population`** are ALE additions — ploidy feeds
  `--sample-ploidy`/FreeBayes/TIDDIT/Control-FREEC; clonal-vs-population drives the joint HC
  hard-filter AF thresholds.
- **`sex`** is inert on a Tier-1 run and optional: only Control-FREEC/ASCAT read it, and the schema
  fills `NA` when the column is missing. Those two Tier-2 tools error on `NA`, so only they need the
  column (`XX` for yeast). A default of `XX` stays an open Tier-2 convenience item.

---

## Variant Calling Strategy

### Tier-1 tools — v1.0.0 deliverable (validated by the ottilie contract test)

- **SNV/INDEL — GATK HaplotypeCaller**: joint (cohort) + individual germline calling; joint-germline is the ALE default.
- **CNV — CNVKit**: `fold_change`-based CN matrices — see the [CNVKit section](#cnvkit-tier-1-cnv-deliverable).
- **SV — Manta + TIDDIT**: merged via SVDB (`convertInversion` → breakend-pair collapse → across samples → across callers, `--priority manta,tiddit`) into cohort VCFs + matrices — mechanics in [`sv_merge.md`](docs/variant-calling/sv_merge.md), evidence in `04_validate/sv_merge_bench/`. `--joint_manta` (**default `true`** since `37867a5`)
  runs one Manta call per `experiment` with every sample genotyped at every candidate — upstream-shaped
  (`joint_mutect2` idiom), see [`SAREK_MODIFICATIONS.md`](docs/dev-practices/SAREK_MODIFICATIONS.md).
  `--manta_high_sensitivity` (default off) disables Manta's depth filters (`--exome`) and breakend-hub
  edge cap — the human-repeat heuristics that hide engineered multi-copy junctions and Ty/LTR
  insertions; audit + how to re-run: [`pilot_results_v2/NOTES.md`](docs/benchmarking/ottilie_xenobiotic_ale/04_validate/pilot_results_v2/NOTES.md).
  `--wes` is a pipeline-wide data-type flag (CNVKit method, mosdepth, HC GenomicsDB, Control-FREEC…) — never use it for this.
- **Annotation — SnpEff**: custom cache built per genome ([`docs/usage/prepare_reference.md`](docs/usage/prepare_reference.md)).

### Tier-2 tools — functional, not release-validated for ALE

- **GATK Mutect2** (somatic; runs without `--germline-resource`/`--panel-of-normals` on the custom
  genome — see [`mutect2_custom_genome_resources.md`](docs/variant-calling/mutect2/mutect2_custom_genome_resources.md)) and **FreeBayes**
  (germline mode only; somatic disabled — too noisy) — SNV/INDEL, exactly as upstream sarek runs them.
  The fork's AF-based post-filters for both were **removed 2026-09-09** (never part of the Tier-1
  recipe; archived at tag `tier2-tools-archive`, index [`docs/archive/tier2/README.md`](docs/archive/tier2/README.md)).
- **Control-FREEC** (exactly as upstream sarek: somatic / tumor-only, `cf_*` params — the fork's germline single-sample mode was removed 2026-09-09, see the [Control-FREEC section](#control-freec-tier-2-cnv)) · **breseq** (bacterial, not released).

**Ploidy Support:**
- Passed to: HaplotypeCaller (`--sample-ploidy`), `FreeBayes`, `Tiddit` (Control-FREEC reads upstream's `cf_ploidy` again since 2026-09-09)
- **Manta**: has **no** ploidy parameter — it's an SV breakpoint caller (no genotype-by-ploidy), so it's excluded by design, not an omission.
- **Note**: `bcftools mpileup` still uses ploidy=1 in `conf/modules/ngscheckmate.config`
- **CNVKit**: does **not** take `--ploidy` (reverted May 2026 → defaults to 2; CN scale is always `cn=2` baseline regardless). Use `fold_change`/log2 for true signal — see the [CNVKit section](#cnvkit-tier-1-cnv-deliverable) and [`docs/variant-calling/cnvkit/cnvkit_ploidy_behavior.md`](docs/variant-calling/cnvkit/cnvkit_ploidy_behavior.md).

---

## Implementation Details

### Tier-2 somatic AF filters (Mutect2 / FreeBayes) — REMOVED 2026-09-09

The fork's AF-based post-filters (`vcf_filter_freebayes`, `vcf_filter_mutect2`, their configs, the
`freebayes_*` params and the `TABIX_TABIX` index step that fed them) are gone: they never served the
Tier-1 recipe and every removed file shrinks the next sarek rebase. Code at tag `tier2-tools-archive`;
what they did and how to get them back: [`docs/archive/tier2/README.md`](docs/archive/tier2/README.md).
Still in place because they are caller-level, not filters: FreeBayes-somatic disabled
(`bam_variant_calling_somatic_all`), the FilterMutectCalls channel-join fix
(`bam_variant_calling_somatic_mutect2`), the FreeBayes `--ploidy` passthrough.
**HaplotypeCaller is the Tier-1 SNV/INDEL deliverable.**

### Bug Fixes

#### ✅ `processVersionsFromYAML()` on cloud paths

`subworkflows/nf-core/utils_nfcore_pipeline/main.nf` reads the versions YAML content explicitly
(`Path` → text) and drops empty documents, avoiding a SnakeYAML method-resolution ambiguity and
cloud-path (`az://`) failures. Found while building the now-removed VCF filters; kept because it is
general robustness of the versions manifest, not filter-specific.

---

## Tool-Specific Notes

### Start-up preflight (`[yAMP preflight]`)

Since 2026-09-23 the pipeline checks the ALE-specific facts at DAG build — errors for a missing
experiment id (a `patient` header parses as empty, see `docs/usage/input_samplesheet.md`) and for
duplicate input files; warnings for drift from the Tier-1 recipe and for mixed ploidy / clonal flag
within an experiment. Zero lines on the ottilie profile is a tested invariant
(`tests/preflight.nf.test`). User page: [`docs/usage/preflight_checks.md`](docs/usage/preflight_checks.md);
code in `subworkflows/local/utils_nfcore_sarek_pipeline/main.nf`. Since 2026-09-28 a **task-level**
check, `PREFLIGHT_REFERENCE` (`bin/preflight_reference.sh` in the gawk container; `conf/modules/preflight.config`
terminates the run on error), reads the reference files themselves before alignment: FASTA vs
`report_gff3` contig names — error when none is shared; GFF3 contigs the FASTA lacks are noted in the
OK row, not warned about (the test set is a chromosome subset of a fully annotated genome).
Verdicts in a MultiQC table + `reports/preflight/`; a console line only on ERROR, so the
zero-lines rule holds (`tests/preflight_reference.nf.test`, 4 cases). One check by decision; the others are roadmap rows.
Since 2026-09-29 **every** check's verdict (OK/WARN; an ERROR stops the run before any report) is a
row of one *yAMP input checks* table at the top of all three MultiQC reports — the DAG-build rows
(`preflightTable()`) share the reference script's MultiQC id and header; keep the two identical.

### QC-first run (`--qc_only`)

Since 2026-09-24: run 1 = the normal command + `--qc_only` stops after read QC (preflight, FastQC raw,
fastp, FastQC on the fastp output, MultiQC, plus reference prep and the reference preflight task — 18 tasks / ~5 min on the test set),
exits 0 and prints the follow-up; run 2 = the same command without the flag + `-resume <session id>`
(every QC task cached; Platform: *Resume* with `qc_only` cleared). **The Launchpad entry opens with
`qc_only` ticked** (user decision 2026-10-05): `qc_only: true` sits in the entry's params box
(`deploy/azure/seqera-sp/14_register_pipeline.sh`, `ENTRY_QC_ONLY`), not in `nextflow.config` or the
schema, so command-line runs, nf-test and every profile stay a complete run; `15_launch_run.sh`
sends that box, so a scripted launch is QC-only unless `--set qc_only=false`, and `--resume` sets
`false` itself. **Three MultiQC reports** (since
2026-09-29), each published as its stage ends: `yAMP-read-QC_multiqc_report.html` (the QC-only run's
report), `yAMP-alignment-QC_multiqc_report.html`, and the complete one — titled *complete-QC* but
keeping `multiqc_report.html` / `multiqc_data/` (the index and baselines key on them). The early two
are starved, not wrapped, where their stage does not run; under `--qc_only` so are the other two.
Errors:
`--step` ≠ `mapping`, `multiqc` skipped, `cleanup = true`. breseq is not run. **The gate is one
starvation point before alignment in `workflows/sarek/main.nf`** — anything downstream that can fire
on empty input (`toList`/`ifEmpty`/value channel/plain file) breaks it silently, so `tests/qc_gate.sh a`
(minutes, exact process allow-list) is a commit-gate trailer for `workflows/`/`subworkflows/` changes
and part (b) (`-resume` equals a one-shot run) is the resume contract. User page:
[`docs/usage/qc_first_run.md`](docs/usage/qc_first_run.md); rule:
[`SAREK_MODIFICATIONS.md`](docs/dev-practices/SAREK_MODIFICATIONS.md) → `workflows/sarek/main.nf`.

### Read preprocessing — BQSR skipped

BQSR (BaseRecalibrator — a read-recalibration **preprocessing** step, before any variant calling) is
skipped: the custom yeast reference has no `--known-sites` VCFs, which BQSR requires. This is a
**required manual opt-out, not automatic** — every ALE config sets `skip_tools = 'baserecalibrator'`
(`conf/test/ottilie_test.config` + the run scripts), and **dropping it aborts the run**. The missing
known-sites resource *starves* the BaseRecalibrator channel, surfacing as a Nextflow join error (not a
GATK error). The same starvation gates VQSR (which has the soft-filter fallback — see the HaplotypeCaller
section below) and FilterVariantTranches. Full mechanism:
[`haplotypecaller_workflow_analysis.md` → known-sites starvation](docs/variant-calling/haplotypecaller/haplotypecaller_workflow_analysis.md#4-the-known-sites-starvation-pattern-custom-genomes).

### Read preprocessing — fastp trimming on by default (adapter + 3′ tail)

**Default since 2026-09-04: adapter trimming + 3′ tail quality trimming** (`--trim_adapter
--trim_quality_3prime tail`, fastp's read filter on). FastQC reports on the raw FASTQs **and, since
2026-09-23, on the fastp output** (`FASTQC_TRIMMED_QC`, `subworkflows/local/fastqc_trimmed/`; shards
concatenated per mate when `split_fastq > 0`; `reports/fastqc/<id>/trimmed/`; two FastQC sections in
MultiQC sharing General Stats rows — `read_preprocessing.md` → Post-trim QC). For reads
exactly as sequenced set `--trim_adapter false` and unset `trim_quality_3prime`; FASTP's gate is
`trim_adapter || trim_fastq || trim_quality_3prime || trim_quality_5prime || split_fastq > 0`
(`workflows/sarek/main.nf`). ⚠️ The **Azure baseline and earlier Seqera comparisons were produced
with no preprocessing**. ✅ **Baseline re-cut 2026-09-08** (`az://aletest/seqera-runs/yAMP-out-test-recut-20260908`,
trimming on + no HC hard filter, cloud reproduces local — see Cloud execution above); older outputs are
compared per `output_comparison.md` §2.10. ✅ The 4-sample pilot's sensitivity was **re-measured on the
current recipe on 2026-09-09: 41/42 unchanged** (PASS-only 40/42, CNV 1/1; SV matrix 426 → 385 rows) —
`04_validate/pilot_results_v3/NOTES.md`.

The steps, in run order (user page:
[`docs/usage/read_preprocessing.md`](docs/usage/read_preprocessing.md)): step 0 UMI consensus (hidden,
no ALE library has UMIs) → fastp step 1 **adapter trimming** `--trim_adapter` (auto-detected;
`--adapter_sequence` names it, e.g. Nextera `CTGTCTCTTATACACATCT`; `trim_fastq` is the deprecated
upstream alias) → step 2 **fixed-count clipping** (upstream `clip_*`, before the cut) → step 3 **quality trimming per
end** `--trim_quality_3prime tail|right` / `--trim_quality_5prime` (a **variable** number of bases by
quality, window/threshold 4/Q20) → step 4 **read filtering** `filter_quality` (fastp's read-level filter, **on** as upstream,
drops 0.7–4.2 % of test-set pairs) + `length_required`. Poly-G: fastp's read-name auto-detection applies at
`trim_nextseq = 0` (upstream parity); a non-zero value forces it. On the test set the default recipe touches 11 % of the evolved clone's reads (adapter) and removes
≤ 2 % of bases (tail trim). Design, measurements, validation:
[`fastq_preprocessing_audit.md`](docs/dev-practices/fastq_preprocessing_audit.md) §2; module test
`tests/fastp_preprocessing.nf.test`.


### GATK HaplotypeCaller (joint germline)

The Tier-1 SNV/INDEL caller. Two ALE-specific customizations on the joint-germline path:

#### Soft-filter fallback (VQSR unavailable)

VQSR is unavailable for the custom yeast genome (no known-sites resources). As a fallback, GATK
`VARIANTFILTRATION_FALLBACK` **soft-filters** the joint VCF — it populates the FILTER column
(`PASS` or named tags like `QD_filter`) but **does not remove variants**. Output:
`HaplotypeCaller_joint_calling_soft_filtered.vcf.gz`. Extract PASS-only downstream with
`bcftools view -f PASS`. Thresholds are GATK's stock values with one ALE deviation: the SNP
strand-bias filter is FS-gated (`SOR_FS_filter`, 2026-09; plain `SOR > 3.0` tagged real mutations
with zero Fisher-strand bias at deep clonal coverage — Tier 2, 86 samples / 343 truth mutations).
Details, filter thresholds, and trigger conditions:
[`docs/variant-calling/haplotypecaller/SOFT_FILTER_HAPLOTYPECALLER_JOINT.md`](docs/variant-calling/haplotypecaller/SOFT_FILTER_HAPLOTYPECALLER_JOINT.md).

#### Split joint VCF into individual sample VCFs

The `SPLIT_JOINT_VCF` subworkflow extracts per-sample VCFs from the joint calling output using
channel-based metadata propagation (no string parsing). Enable with
`--joint_germline --split_haplotypecaller_joint_vcf`. Output:
`variant_calling/haplotypecaller/individual_from_joint/<sample>/<sample>.haplotypecaller.from_joint_calling.vcf.gz`
(+ `.tbi`). Full architecture, channel flow, and manual bcftools recipe:
[`docs/variant-calling/haplotypecaller/SPLIT_JOINT_VCF_PIPELINE.md`](docs/variant-calling/haplotypecaller/SPLIT_JOINT_VCF_PIPELINE.md).
The same subworkflow splits the **joint Manta** VCF (`--joint_manta`) back to
`variant_calling/manta/<sample>/<sample>.manta.diploid_sv.vcf.gz` — hom-ref rows dropped with
`--min-ac 1:nref` (Manta genotypes diploid-model whatever `ploidy` says) and per-sample `FORMAT/FT`
promoted to `FILTER` (`MinGQ`). All per-caller split rules are keyed on `meta.variantcaller` in
[`conf/modules/split_joint_vcf.config`](conf/modules/split_joint_vcf.config).

### CNVKit (Tier-1 CNV deliverable)

CNVKit is the **Tier-1 CNV deliverable**. No explicit `--ploidy` is passed (that was reverted
May 2026 — CNVKit defaults to 2); CN matrices use `fold_change = 2^log2` (ploidy-agnostic depth
ratio). **Caveat**: CNVKit's integer `cn` always uses `cn=2` as baseline regardless of ploidy,
so use `fold_change`/`log2` for the true signal. **Second caveat**: `cnvkit.py fix` drops every bin
outside 0.30–0.70 GC (hard-coded, no override) — the whole mitochondrial contig (~17 % GC) is
therefore absent from ALL CNVKit output; read Mito from the TIDDIT contig copy-number table instead
([`cnvkit_gc_bin_mask.md`](docs/variant-calling/cnvkit/cnvkit_gc_bin_mask.md)). Details:
[`docs/variant-calling/cnvkit/`](docs/variant-calling/cnvkit/).

### VCFtools Compatibility

#### ⚠️ Conditional Skipping

VCFtools **conditionally skipped** due to compatibility issues:

**1. Ploidy > 2**
- Error: "Polyploidy found, and not supported by vcftools"
- Works: ploidy 1-2, Fails: ploidy ≥ 3

**2. Mutect2 Phased Genotypes**
- Issue: Mutect2 outputs phased (0|0, 0|1) instead of unphased (0/0, 0/1)
- Impact: VCFtools expects standard format

**3. Joint Calling Segmentation Fault**
- Issue: VCFtools 0.1.16 crashes on joint_variant_calling.vcf.gz (exit 139)
- Root cause: Memory corruption with GATK joint calling format

**Configuration** (`conf/modules/modules.config`):
```yaml
ext.when = { !(params.skip_tools.contains('vcftools')) &&
             (meta.ploidy == null || meta.ploidy <= 2) &&
             (meta.variantcaller != 'mutect2') &&
             !(meta.id ==~ /.*joint_variant_calling.*/) }
```

**VCFtools runs for**:
- ✅ FreeBayes individual (ploidy ≤ 2)
- ✅ HaplotypeCaller individual
- ❌ Mutect2 (all)
- ❌ Joint variant calling
- ❌ Ploidy > 2

### Control-FREEC (Tier-2 CNV)

**Tier-2 (functional, not release-validated for ALE) — upstream behaviour only since 2026-09-09.**
Not the Tier-1 CNV deliverable because: no SNP database → no BAF (copy number from read depth only);
no standard VCF output → no SnpEff annotation; `ASSESS_SIGNIFICANCE` fails for haploid (ploidy=1)
samples; and it crashed on 4 of 86 tier-2 samples with `std::length_error`. **CNVKit is the Tier-1
CNV deliverable instead.** The fork's single-sample germline mode (April 2026: `meta.ploidy` instead
of `cf_ploidy`, a `FREEC_GERMLINE` config block, the ploidy-1 skip, a `BAF`-optional module patch) was
**removed** and every Control-FREEC file reverted to pristine sarek 3.5.1 — Control-FREEC now runs only
in sarek's somatic/tumor-only modes, which an all-germline ALE samplesheet never triggers. Code at tag
`tier2-tools-archive`; design record
[`docs/archive/tier2/controlfreec_germline_changes.md`](docs/archive/tier2/controlfreec_germline_changes.md).

## Variant Analysis Dashboard System

**Superseded.** The original `bin/` dashboard scripts (`create_research_dashboard.py`,
`summarize_variants.py`, `organize_results.sh`, `quick_variant_check.sh`, `create_variant_dashboard.py`)
were removed during the v1.0.0 code cleanup. Their role — cross-sample / multi-tool variant tables, cohort matrices, and gene /
tool-comparison views — is now delivered by the **`MUTATION_REPORT` subworkflow + `GENERATE_INDEX`**
(igv-reports HTML dashboard backed by `cn_cohort_matrix.csv` / `sv_cohort_matrix_*.csv` /
`cn_segments_*.csv` / `contig_copy_number.csv` — the last from TIDDIT's per-contig coverage table,
plus the prepared cohort VCF read in pure Python for the *SNV / InDel events* table: every PASS site, opening on the
ones that differ between samples, protein-changing first, with an *All PASS sites* view for the shared strain background
(since 2026-10-07), capped at 1,000 rows with the differing rows first and the full counts printed; a carried site where
every other sample has *no reads* is not "differing" — on the test strain those are cassette junctions HaplotypeCaller
assembled in one sample only (measured 2026-10-07, CHANGELOG entry of that date); the report container has no bcftools —
whole-contig only, and the **only** place the mitochondrial contig is quantified: CNVKit's hard-coded
0.30–0.70 GC mask drops every Mito bin). `index.html` names the run that produced it (run name, commit, session id, Seqera run id from
`TOWER_WORKFLOW_ID`; a link only when the optional hidden `seqera_workspace_url` is set — a run cannot
learn its own page address) and needs no network: Tabulator 6.3.0 is inlined from
`docs/igvreports/templates/vendor/` (the cohort and per-sample IGV pages still use CDNs). Since 2026-10-06 the
index is the redesigned light-only page (template contract: [`docs/igvreports/templates/README.md`](docs/igvreports/templates/README.md));
its Samples table grades QC pass / warn / fail with the hidden `report_qc_*` params (coverage, breadth at 20×, mapped %,
duplicates %, plus a relative check at 0.33 of the cohort median coverage), and Mito is counted like any contig.
See [`docs/igvreports/`](docs/igvreports/) and
[`subworkflows/local/mutation_report/`](subworkflows/local/mutation_report/main.nf). The original design
writeup (kept for future mutation-report work) is archived at
[`docs/archive/variant_dashboard_system.md`](docs/archive/variant_dashboard_system.md).

## Pipeline Merger Decision - Reminder
### Two Pipeline Architectures
#### AMP v1 (Legacy ALE Pipeline)

Input: Individual CSV files per sample
Annotation: GenBank (.gb) files
Tools: breseq + GATK + CNVnator
Target: Bacterial ALE experiments (haploid)
Deployment: Azure Batch → migrating to Nextflow

#### Customer Sarek Pipeline

Input: Population CSV table
Annotation: SnpEff cache + FASTQ
Tools: Standard Sarek workflow (GATK-based)
Target: Eukaryotic ALE experiments
Deployment: Nextflow
Decision Required

#### ⚠️ INVESTIGATE BEFORE PROCEEDING:

Merger Feasibility: Can GenBank and SnpEff annotation systems coexist?
Tool Integration: How to incorporate breseq into Sarek architecture?
Input Standardization: Worth converging to population CSV format?
Maintenance Trade-offs: One complex pipeline vs two focused pipelines?