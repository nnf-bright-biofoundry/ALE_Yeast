# Testing Best Practices for Forked nf-core/Sarek Pipeline

## Overview

This document outlines a testing strategy for the ALE_nextflow fork of nf-core/Sarek 3.5.1 before releasing.

§1–§9 are that original plan, written before v1.0.0 and kept for the record. The rules in force are §10–§14 (what exists, the target coverage layers, what counts as validated, benchmark provenance, cross-session state). The entry point to the testing documents is [`testing_and_coverage_overview.md`](testing_and_coverage_overview.md) → *Documents*.

---

## 1. Tiered Testing Strategy

*Pre-1.0.0 plan, kept for the record; the rules in force are §10–§14 and the overview.*

### Unit Tests (per-module)
- **nf-test**: The nf-core standard for module-level testing. Each module in `modules/nf-core/` can have a `tests/` directory with `main.nf.test` files.
- Test individual processes with minimal inputs (e.g., does `BCFTOOLS_FILTER` produce expected output format?)
- Use **nf-test snapshots** to catch regressions in output structure

### Integration Tests (subworkflow-level)
- Test custom subworkflows end-to-end: `split_joint_vcf`, `vcf_filter_haplotypecaller_joint` (the Mutect2/FreeBayes AF filters were removed 2026-09-09)
- Verify channel wiring — especially custom joins (e.g., the FilterMutectCalls fix, channel-based metadata propagation)

### System/Pipeline Tests (full workflow)
- Run the full pipeline with a **small test dataset** (subset of yeast data)
- Validate all expected output files exist and are non-empty

---

## 2. Test Data

*Pre-1.0.0 plan, kept for the record; the rules in force are §10–§14 and the overview.*

- **Minimal test profile**: Create a `test` profile in `nextflow.config` with:
  - Downsampled FASTQs (e.g., 10K–100K reads per sample)
  - Small reference (single chromosome or region)
  - Custom SnpEff cache
- **Deterministic inputs**: Pin exact test data versions (store on Azure Blob or use nf-core test-datasets pattern)
- Include edge cases: haploid samples, multi-lane samples, samples that trigger the VCFtools skip logic

---

## 3. What to Validate

*Pre-1.0.0 plan, kept for the record; the rules in force are §10–§14 and the overview.*

| Layer | Check |
|-------|-------|
| **Process exit codes** | All processes exit 0 |
| **Output existence** | Expected VCFs, indices, CSVs all present |
| **VCF integrity** | `bcftools stats` on outputs, validate headers |
| **Variant counts** | Regression check — counts shouldn't wildly change between releases |
| **Filter logic** | Known variants pass/fail as expected (truth set) |
| **Metadata propagation** | Ploidy, status, sex survive through channels |
| **Conditional logic** | VCFtools skipped for Mutect2/ploidy>2, ASSESS_SIGNIFICANCE skipped for ploidy=1 |
| **Report structure** | Assert on stable identifiers — a MultiQC section's `<h2 id="…">` — never on presentation: the 1.25.1 → 1.35 bump (2026-09-24) changed the heading's CSS class and kept every id |

---

## 4. CI/CD Approach

*Pre-1.0.0 plan, kept for the record; the rules in force are §10–§14 and the overview.*

```bash
# Minimal CI test (GitHub Actions or Azure DevOps)
nextflow run main.nf \
  -profile test,docker \
  --outdir results_test \
  --tools 'haplotypecaller,freebayes,mutect2,snpeff' \
  --joint_germline \
  --split_haplotypecaller_joint_vcf \
  -resume
```

- Run on every PR to `main`
- Use `-resume` with cached work dirs for speed
- Fail on: non-zero exit, missing outputs, `bcftools view` errors on VCFs

---

## 5. nf-core Conventions to Follow

*Pre-1.0.0 plan, kept for the record; the rules in force are §10–§14 and the overview.*

- **`nf-test`** (replaces pytest-workflow): install via `nf-core tools`
- **Linting**: `nf-core pipelines lint` — won't pass 100% on a fork but catches structural issues
- **`nextflow_schema.json`**: Validate custom params (`--split_haplotypecaller_joint_vcf`, ploidy column) are documented
- **`CHANGELOG.md`**: Track what diverges from upstream Sarek 3.5.1
- **Adding an alias** (`include { X as Y }`): every `withName: 'X'` block applies to `Y` as well —
  resources in `conf/base.config`, `ext.args` / `ext.prefix` / `publishDir` in `conf/modules/` —
  unless a block for `Y` sets the same directive. Give `Y` its own block for each directive it must
  not share, or it silently takes `X`'s arguments and can publish under `X`'s file names (a collision
  a name-only snapshot entry cannot show — §10 → publish collisions). Measured on the MultiQC aliases
  (2026-09-29); mechanism: [`compute_resources.md`](compute_resources.md) → *Aliases*.

---

## 6. Regression/Truth Set Testing

*Pre-1.0.0 plan, kept for the record; the rules in force are §10–§14 and the overview.*

For ALE use case specifically:

1. **Create a truth set**: Run the pipeline on test data, manually review outputs, freeze as "known good"
2. **Compare on each release**:
   ```bash
   bcftools isec -p comparison/ truth_set.vcf.gz new_run.vcf.gz
   # Check for unexpected gains/losses
   ```
3. Track variant counts per sample/tool in a simple CSV — diff against previous release

---

## 7. Pre-Release Checklist

*Pre-1.0.0 plan, kept for the record; the rules in force are §10–§14 and the overview.*

- [ ] All test profiles pass (`test`, `test_full` if available)
- [ ] `nf-core pipelines lint` has no critical errors
- [ ] Custom modules have nf-test coverage
- [ ] CHANGELOG documents all changes from upstream
- [ ] Docker/container images pinned to specific versions
- [ ] `nextflow_schema.json` updated for new params
- [ ] README documents fork-specific features and divergences
- [ ] Run full dataset at least once before tagging a release

---

## 8. Quick Start: Setting Up nf-test

*Pre-1.0.0 plan, kept for the record; the rules in force are §10–§14 and the overview.*

```bash
# Install nf-test
conda install -c bioconda nf-test

# Initialize tests for a custom module
cd nf-core-sarek_3.5.1/3_5_1
nf-test init

# Generate test for custom filter module
nf-test generate process \
  modules/local/vcf_filter_mutect2/bcftools/filter_somatic/main.nf

# Run all tests
nf-test test
```

---

## 9. Priority Items for This Fork

*Pre-1.0.0 plan, kept for the record; the rules in force are §10–§14 and the overview.*

The highest-value testing items are:

1. **Minimal test profile with yeast data** — catches configuration issues
2. **Regression variant counts** — ensures filter logic hasn't drifted
3. **nf-test on custom subworkflows** — filter logic, split joint VCF, channel joins

These cover the most likely breakage points when updating or refactoring.

---

## 10. Existing Test Infrastructure

See also:
- [`output_comparison.md`](output_comparison.md) — **which pipeline outputs are actually deterministic.**
  The classes of run-to-run noise (embedded timestamps, gzip framing, absolute paths, MultiQC renders,
  igv-reports base64 blobs) with a normalisation recipe for each. **This is the *why* behind every entry
  in [`tests/.nftignore`](../../tests/.nftignore)** — read it before adding or removing one, and before
  deciding whether a file may be snapshotted byte-for-byte.
- `bin/test_ottilie.sh` — ALE end-to-end test launcher (ottilie 2-sample dataset)
- `bin/CENPK_run_sarek_351_all.sh` — production execution script (reference for params)

### nf-test file categories (what we own vs. what stays untouched)

Three categories of `*.nf.test` files exist in the repo; only the first is ours to curate:

| Category | Location | Tests | Policy |
|----------|----------|-------|--------|
| **ALE suite (ours)** | `tests/*.nf.test` | the fork's own tests, at *any* nf-test layer: ten files as of 2026-10-16 (2 process, 4 subworkflow, 4 pipeline; the §11 layer table names them) | **maintained.** All of ours live here regardless of layer — including component-level ones — see [Why our component tests live in `tests/`](#why-our-component-tests-live-in-tests-not-co-located) below |
| **Upstream pipeline-level** | `tests/*.nf.test` (inherited) | whole-pipeline scenarios on human test data | triaged out — see the next section |
| **Upstream component-level** | `modules/nf-core/*/tests/`, `subworkflows/*/tests/` | one module/subworkflow in isolation | **leave untouched** — co-located with upstream code; deleting them creates a rebase patch per upgrade, and they don't fail from our fork changes |

### What a name-only entry cannot tell you: publish collisions

Files excluded from content hashing via `.nftignore` (bgzipped VCFs, igv-report HTML, …) are still
guarded by **name** in `stable_name` — but a name check is satisfied by *any* file of that name.
Learned 2026-08-27: `PREPARE_VCF` named its output `<sample>.prepared.vcf.gz` and ran once per caller
per sample, so four tasks (HC, CNVKit, Manta, TIDDIT) each published a different file to the same
`mutation_reports/prepare/<sample>.prepared.vcf.gz`; whichever finished last won. Every recorded run
passed, because HaplotypeCaller happened to finish last each time and the snapshot only knew the name.
(Fixed by not publishing the intermediate at all — `conf/modules/mutation_report.config`.)

Rules that follow:

- **A `publishDir` target must be unique across every task that publishes to it.** If a process
  runs once per (sample × caller), its output name — or its `publishDir` path / `saveAs` — must
  carry both. Nextflow does **not** warn about publish overwrites; the last copy silently wins.
- This is a *publish* problem, not a channel problem. Inside the DAG every task has its own work
  dir, and channels carry paths, so same-named outputs from different tasks never touch each other
  — with one exception: when several same-named files are **staged into one downstream task**
  (`.collect()`, `.groupTuple()`, a multi-path input). Nextflow then logs
  `input file name collision` and only one survives. `grep -i collision .nextflow.log` after any
  change that collects files is a cheap guard; the e2e logs currently show none.
- When you add a name-only file to the tree, ask "how many tasks produce this name?" If the answer
  is more than one, the snapshot cannot protect it — hash something that can (a deterministic
  derivative, a record count, the `tableJson` blob) or make the name unique.

### Updating the snapshot after an intentional pipeline change

`tests/ottilie_e2e.nf.test.snap` (~790 lines of JSON) is the recorded expectation for the e2e run:
the published file tree (`stable_name`), content hashes for the files not excluded by
`tests/.nftignore` (`stable_path`), and the joint-VCF `variantsMD5`. Any change to pipeline output —
a new published file, a renamed directory, different variant records — makes the test fail by design.

**First, decide which kind of failure it is.** The snapshot cannot tell you; only you can:

| The diff shows | Meaning |
|---|---|
| Exactly the files/values your change should have touched | Intentional → re-record |
| Anything else moving too | **Stop.** A regression, or non-determinism the `.nftignore` doesn't cover |

Re-recording is the *last* step, never the first response to a red test.

```bash
# 1. See what moved (run normally; do NOT pass --update-snapshot yet)
NXF_VER=25.10.4 nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test

# 2. Only once every difference is explained, re-record
NXF_VER=25.10.4 nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test \
    --update-snapshot

# 3. Review the diff as source code, then commit test + snapshot together
git diff tests/ottilie_e2e.nf.test.snap
```

`--update-snapshot` re-records **every** snapshot that fails in that run, so a genuine regression
sitting alongside your intended change is silently blessed. Reviewing `git diff` on the `.snap` is the
only thing standing between you and a permanently wrong expectation. A worked example of a good diff:
each `manifest.name` change moved exactly one line (`versions.yml`: `nf-core/sarek: v3.5.1` →
`Aletechdev/AMP: v1.0.0` → `Aletechdev/ALE_Yeast: v1.0.0`) — see the status note in
[`../../CLAUDE.md`](../../CLAUDE.md).

⚠️ A run launched **from a Git clone** (Seqera Platform, `nextflow run <org/repo>`) appends the short
commit to that same line — `Aletechdev/ALE_Yeast: v1.0.0-g86c4672` — while a run from a local working
directory does not. That is nf-core provenance, not a regression, but it means `versions.yml` can never
be byte-compared across those two launch modes.

**Keep the engine pinned when re-recording.** The snapshot stores the toolchain that produced it:

```json
"meta": { "nf-test": "0.9.3", "nextflow": "25.10.4" }
```

Re-recording under a different Nextflow or nf-test bakes that into the committed expectation. Use the
same `NXF_VER=25.10.4` prefix as every other invocation ([`../usage/new_machine_setup.md`](../usage/new_machine_setup.md) § 7).

> `meta` is **provenance, not an assertion** — nf-test does not compare it, so running on a different
> engine than the one recorded does not by itself fail the test. Verified 2026-07-30: the suite passes
> on Nextflow 25.10.2 against this snapshot recorded on 25.10.4, so output is stable across the
> 25.10.x patch line. Don't "fix" a version mismatch here by re-recording — that discards the real
> expectation to sync a field nothing checks.

**Other flags worth knowing:**

- `--ci` — fails instead of auto-storing when a snapshot is *missing*. Use in CI so a deleted or
  absent snapshot can never silently pass as a freshly recorded one.
- `--wipe-snapshot` — drops obsolete entries (after renaming or deleting a test case).

> Output that changes run-to-run belongs in `tests/.nftignore`, not in a re-recorded snapshot. The
> file already excludes timestamped/non-deterministic artifacts (igv-reports HTML with its
> non-deterministic `sessionDictionary`, SnpEff summaries carrying a date stamp, samtools stats
> embedding the CRAM path). If a re-record keeps producing a fresh diff on an unchanged pipeline, the
> fix is an `.nftignore` pattern — each one there was verified with a controlled probe, per the
> comments in that file.

### Why our component tests live in `tests/`, not co-located

nf-core convention puts a component test next to its component
(`subworkflows/local/<name>/tests/main.nf.test`), and the upstream category above follows exactly
that. Our own component tests deliberately do **not**: `split_joint_vcf.nf.test` sits in `tests/`
even though it tests `subworkflows/local/split_joint_vcf/`. Reasons, strongest first:

1. **Test discovery is scoped to `tests/`.** `tests/nf-test-ottilie.config` sets `testsDir "tests"`,
   deliberately, so the ALE suite isn't polluted by the 100 upstream component test files (and their
   duplicates under `.claude/worktrees/`). A co-located test falls outside that scope and silently
   drops out of a bare `nf-test test -c tests/nf-test-ottilie.config` — it would still run if named
   explicitly on the command line (verified: paths outside `testsDir` are honoured), but it would no
   longer be part of the default gate. Restoring it costs either `testsDir "."` (which pulls in all
   the upstream tests) or a multi-path invocation that must be re-edited for every new test and
   threaded into CI.
2. **`tests/` is now the fork-owned suite.** With the inherited upstream pipeline tests triaged out,
   what remains is a coherent ALE unit sharing one config (`nf-test-ottilie.config`: profile,
   `resourceLimits`, plugins, `triggers`). Splitting it across two trees buys nothing at this size.
3. **Fixtures live there.** `tests/fixtures/` holds the committed joint VCFs (+ README) that
   `split_joint_vcf.nf.test` consumes. Co-locating the test would either separate it from its data
   or require moving the fixtures too.

**Counter-argument, for the record:** `subworkflows/local/split_joint_vcf/` is 100% ours and would
survive a future re-fork / sarek migration intact, whereas `tests/` receives upstream content again
and needs re-triage. Co-location would let the test travel with its code. That is a real benefit —
it is just outweighed today by (1).

> ⚠️ **Not a fixed decision.** `tests/` is an upstream directory too, so this is a judgement call
> about *this* fork at *this* size, not a principle. Revisit if any of these change: our component
> tests outgrow a handful of files; a re-fork makes `tests/` re-triage expensive enough to dominate;
> CI moves to `--changed-since`/`--related-tests` (where co-location gives better change detection);
> or we adopt a discovery setup that can scope to `tests/` *and* `*/local/**/tests/` at once. If it
> flips, move the fixtures with the tests and update `testsDir` in `tests/nf-test-ottilie.config`.

### Upstream pipeline-test triage — one-time cleanup (v1.0.0)

The `tests/` dir inherited 20 pristine upstream sarek pipeline-level tests, all 0-diff vs upstream
and **never adapted for this fork**. Each was written against a scenario/toolset ALE does not run:

- **Cancer / paired modes** we don't use — `tumor-normal-pair` (needs a tumor sample; the fork's
  all-normal mode breaks it), `variant_calling_strelka`/`_bp`, `variant_calling_controlfreec`.
- **Aligners / tools we don't use** — `sentieon`, `aligner-dragmap` (we run bwa-mem), the VEP/bcfann
  annotation variants (`annotation_vep`, `annotation_bcfann`, `annotation_merge`).
- **Steps / output modes we don't use** — `save_output_as_bam`, `saved_mapped`, and the restart-entry
  tests `start_from_markduplicates` / `start_from_preparerecalibration` / `start_from_recalibration`,
  plus `alignment_from_everything` / `alignment_to_fastq`.
- **Generic upstream defaults** on human test data — `default`, `aligner-bwa-mem`(`2`),
  `annotation_snpeff`.

They all target human test data and fork-incompatible assumptions, so most fail/error → negative
value. Everything reusable in them (the `stable_name` / `stable_path` / `.nftignore` snapshot idiom)
was already copied into `ottilie_e2e.nf.test`. They are deleted (with their orphaned `.snap`) as a
**one-time cleanup**, keeping only our ALE contract tests.

**`ottilie_e2e.nf.test` is the end-to-end case for the v1.0.0 release** (the full ALE workflow on the
ottilie 2-sample dataset via the `ottilie_test` profile); `split_joint_vcf.nf.test` is the one
subworkflow unit test. Those two were what we maintained at v1.0.0; the suite is ten files now (§11).

**Legacy pytest-workflow stack removed in the same triage.** The `tests/` dir also inherited the
upstream **pytest-workflow** apparatus — nf-core's *older* test framework (`- name:` / `command:` /
`files: md5sum:`, run by `pytest --tag`), which **nf-test superseded**. It is a set of interlocking
files, all removed together:

| File(s) | Role |
|---------|------|
| `tests/test_*.yml` (29) | the test definitions |
| `tests/tags.yml` | tag → source-file globs |
| `tests/config/pytesttags.yml` | tag → test-file map (CI change filter) |
| `tests/requirements.txt` | Python deps (`pytest-workflow`, `cryptography`) |

Three independent reasons this is correct, not a divergence:

1. **The runner never came with the fork.** The harness that runs these — upstream's
   `.github/workflows/pytest.yml` (`pip install -r tests/requirements.txt` → `pytest --tag …`, using
   `tests/config/pytesttags.yml` + `tests/csv/`) — **does not exist in our `.github/workflows/`** (we
   have only the container build). So these YAMLs were inert scaffolding here with nothing to run them.
2. **Deprecated framework, zero reuse value** — unlike the `.nf.test` files (whose idioms we copied
   into `ottilie_e2e`), we'd never author a pytest-workflow test. They're also unrelated to the
   `.nf.test` files (no cross-reference) and cover inapplicable upstream scenarios (sentieon,
   deepvariant, mutect2, umi, msisensorpro, lofreq, …) on human data.
3. **Upstream is retiring them too.** The sarek CHANGELOG documents a systematic pytest→nf-test
   migration — PRs **1677** (aligner/default), **1708** (alignment/annotation), **1711** (strelka),
   **1731** (controlfreec) all *"Migrate pipeline pytest … tests to nf-test"* — and **3.8.1 ships just
   1** pytest YAML (vs 3.5.1's 29) alongside 62 `.nf.test`. Deleting them **tracks** where upstream is
   heading, so the "0-diff, redone on migration" caveat barely applies (the version we rebase onto will
   have removed them).

**Kept — not pytest-only:** `tests/csv/` and `tests/config/bcfann_test_header.txt` stay, because the
still-present, 0-diff `conf/test.config` (+ 18 upstream extra-CI profiles) reference them for the
**nf-test** default path too — they are not pytest scaffolding, and removing them would break that
pristine upstream config. (Our own bcftools-norm investigation under `tests/test/` was archived to
`docs/archive/test_bcftools/`.)

> ⚠️ **This is not a permanent state.** A future full re-fork / sarek migration copies clean upstream
> back, so the same triage must be redone then. The planned migration would obsolete these tests
> anyway, so we do **not** invest in adapting them — the minimal ALE suite (ottilie e2e +
> split_joint_vcf at v1.0.0, ten files now) is what survives a migration. The 100 upstream component
> test files (94 module + 6 subworkflow) are **not** part of this triage (see the table above).

---

### `groupTuple` order is not deterministic — sort when the tool reads file order

Found 2026-08-28 by an e2e snapshot diff that had no business existing (`--manta_high_sensitivity`
defaults to false, so the run should have been byte-identical). Only two hashes moved: the two Manta
IGV reports. The VCF *bodies* were identical apart from Manta's record IDs (`MantaBND:52:1:3:…` vs
`…:1:4:…`), their `MATEID`s, and the joint VCF's sample-column order.

Cause: `groupTuple()` emits grouped items in **channel-arrival order**, which varies run to run.
`MANTA_GERMLINE` builds `--bam a --bam b …` from that list, and Manta numbers its record IDs and
orders VCF sample columns by `--bam` order. Fix: `groupTuple(sort: { it.name })` in
`bam_variant_calling_germline_manta`, so the grouped CRAMs are always alphabetical.

Rule: **whenever a grouped list is handed to a tool whose output depends on input order, sort it.**
Recorded as a difference class (the one that is a bug, not noise) in
[`output_comparison.md`](output_comparison.md) §2.9.
Most other `groupTuple` calls in this repo group interval-scattered pieces of one sample and feed a
coordinate-sorting merge (`bcftools concat`, `GatherVcfs`), so they are order-insensitive; the joint
HC path groups gVCFs across samples but `GenomicsDBImport` sorts sample names itself. Manta was the
one place where order leaked into the output.

Why the earlier runs looked stable: the first joint-Manta e2e and its `--update-snapshot` re-record
happened to arrive in the same order, so the snapshot recorded one of the two possible outputs. A
snapshot passing twice is **not** proof of determinism when the input is a `groupTuple` list — check
the ordering, or run once with the samplesheet rows reversed.

The reversal check was run for the SVDB SV merge chain (2026-08-31, before its snapshot was
trusted): forward vs reversed samplesheet, standalone launcher on the same outdir — all SV/CN
matrices, merge inputs and VCF **records** byte-identical; only the `##bcftools_viewCommand …
Date=` wall-clock header lines differed (difference class 2.1, present between any two runs).
The chain's order-proofing levers: `svdb/merge` `sort_inputs=true`, `toSortedList()` for matrix
columns, explicit `[manta, tiddit]` L2 input order, `groupTuple(sort:{it.name})` for joint Manta.
Two practical rules from running the check: (1) never run two Nextflow instances against the same
`--outdir` — they race on `pipeline_info/` report files (one aborts) and, worse, one may read
files the other is republishing; (2) a `cmp` loop must distinguish "differs" from "missing" —
a half-failed run makes everything look nondeterministic.

## 11. Target coverage: the four nf-test layers (post-1.0.0)

v1.0.0 shipped two owned tests — `ottilie_e2e` (`nextflow_pipeline`) and `split_joint_vcf`
(`nextflow_workflow`); `fastp_preprocessing` (process) and `fastqc_trimmed` (subworkflow) followed. The long-term target is coverage of **our own modifications** at all four
nf-test layers. This section is the durable target; the *scheduling* of it lives as a single
prioritized item in `roadmap.md` (Robustness / infrastructure).

nf-test's four test types, and what each maps to in this fork:

| Layer | nf-test type | Our surface | Status |
|-------|--------------|-------------|--------|
| Function | `nextflow_function` | Groovy helpers we changed | **0 owned** |
| Process | `nextflow_process` | the 19 fork-added `modules/local/` directories (the `SAREK_MODIFICATIONS.md` inventory; 20 processes, `breseq/` holds two; the three inherited from sarek, `add_info_to_vcf`, `create_intervals_bed`, `samtools/reindex_bam`, are upstream code) + upstream modules whose behaviour we own via config | **4** (`fastp_preprocessing` — `FASTP` under `conf/modules/trimming.config`, 11 cases, one of them on the `nextflow.config` defaults alone, 1 000-pair fixture; `preflight_reference` — the task-level reference preflight, 4 cases on hand-made fixtures: OK with an embedded `##FASTA`, SKIPPED without a GFF3, ERROR/exit 65 on renamed contigs, OK-with-note when the GFF3 has a contig the FASTA lacks; `variantfiltration_fallback` — the soft-filter `ext.args` of `conf/modules/joint_germline.config` run by real GATK on the real 100-record joint VCF, 2 cases: the exact FILTER string of every record plus a negative control with the broken `TYPE == SNP` spelling; `snpeff_codon_table` — the per-genome `codonTable` line of the shipped snpEff cache, run by real snpEff on a synthetic COX2 variant, 3 cases: the shipped cache, a 25 KB Mito-only fixture cache with the line and the same without it) |
| Subworkflow | `nextflow_workflow` | the custom `subworkflows/local/` | **4** (`split_joint_vcf`; `joint_calling_output_selection` — `BAM_JOINT_CALLING_GERMLINE_GATK`, stub mode: the three-tier output selection, one case per tier (fallback only, VQSR present, neither) plus the no-input starvation shape; `manta_experiment_grouping` — `BAM_VARIANT_CALLING_GERMLINE_MANTA` under `--joint_manta`, stub mode: one Manta task per experiment, keyed and named as documented; `fastqc_trimmed` — `FASTQC_TRIMMED_QC`: unsplit pair, fastp-named shards incl. an empty one, single-end lone file; 136 KB of shard fixtures) |
| Pipeline | `nextflow_pipeline` | supported end-to-end routes | **4** (`ottilie_e2e`; preview-mode smoke tests `report_gff3_optional`, `tools_without_annotation`, `preflight` — the latter reads `[yAMP preflight]` lines from nf-test's `meta/nextflow.log` and error text from `workflow.stdout`; 8 cases incl. the three `--qc_only` ones) |
| Gate | bash, outside nf-test | the `--qc_only` starvation gate (`workflows/sarek/main.nf`) | **`tests/qc_gate.sh`** — (a) minutes: a QC-only run of the test set executes *exactly* the allow-listed processes (read QC + reference prep, 15 processes / 18 tasks (2026-09-28, with the reference preflight task; 17 before); since 2026-09-29 the MultiQC process on the list is `MULTIQC_READ_QC` — the alignment-QC and complete-QC reports must not run); a stray process means something downstream of alignment fires on empty input (`toList`/`ifEmpty`/value channel) and the failure message names it. (b) one e2e: `-resume` of run (a) without the flag caches every run-1 task but the read-QC MultiQC report (`MULTIQC_READ_QC`; its input checks and summary record `qc_only`), matches a one-shot run's task list, and `tests/qc_gate_compare.py` finds the deliverables identical (md5 for the `.nftignore`-kept files, records for every VCF). Not nf-test because it needs two launches sharing a session. Run (a) after any `workflows/`/`subworkflows/` change (commit-gate trailer), (b) when the gate or the resume contract itself changes |

The 100 upstream component test files do **not** count as coverage here — they test unmodified nf-core
code (see the category table in §10). Only tests over fork-specific code do. Counted 2026-10-13 as
`*.nf.test` files: 94 under `modules/nf-core/` (93 `tests/` dirs; `spring/decompress` keeps its test
in a `test/` dir), 5 under `subworkflows/nf-core/` and 1 inherited under
`subworkflows/local/samplesheet_to_channel/tests/`.

### Priority theme: the "no known-variants resource" modifications

The custom yeast genome has no curated known-sites VCF (no dbSNP/gnomAD equivalent), so several GATK
best-practice steps that *assume* one had to be reworked. This is the fork's most consequential
divergence from upstream and its least-covered code:

| Step | What we did | Where |
|------|-------------|-------|
| **VQSR** (joint germline) | added `VARIANTFILTRATION_FALLBACK` — a hard-filter step that soft-flags the FILTER column when VQSR can't run, plus three-tier output selection | `subworkflows/local/bam_joint_calling_germline_gatk/main.nf`, `conf/modules/joint_germline.config:87` |
| **BaseRecalibrator** | *skipped*, not replaced — `skip_tools = 'baserecalibrator'`. Not auto-skipped: drop the flag and the run **aborts** — not from GATK (it never launches; its known-sites channel is empty) but from `failOnMismatch` on the `ch_table_bqsr` join at `workflows/sarek/main.nf:567` | `conf/test/ottilie_test.config:41` and the run scripts |
| **CNNScoreVariants / FilterVariantTranches** | nothing — structurally bypassed, it's in the `else` of `if (joint_germline)` and we run joint | `bam_variant_calling_germline_all/main.nf:232` |
| **Mutect2** | `--germline-resource` / `--panel-of-normals` omitted; `FilterMutectCalls` fed placeholder contamination channels | `bam_variant_calling_somatic_mutect2/main.nf` |

Note the asymmetry: BQSR is a **config-level skip** (nothing to unit-test beyond "the skip takes
effect"), whereas the VQSR fallback is **real added logic** and is the highest-value test target in
the repo. It gets specific entries at layers 2 and 3 below.

### Layer 1 — `nextflow_function`

Deliberately the smallest layer: nearly all our logic lives in bash/Python *inside* processes, not
in Groovy. The one genuine candidate is **`processVersionsFromYAML`**
(`subworkflows/nf-core/utils_nfcore_pipeline/main.nf:95`) — we rewrote it (explicit
`FileInputStream` + null/empty guards) to fix the method-resolution ambiguity that broke the custom
VCF filters, and the co-located upstream `tests/main.function.nf.test` has **no case for it**. Since
that file is upstream-co-located, adding a case there conflicts with the "leave untouched" policy —
prefer a case in our own `tests/` file (see §10 rationale).

> Not this layer: the Python in `bin/` (`build_cn_matrix.py`, `cn_cohort_matrix.py`,
> `generate_index.py`, the dashboard scripts). Those need **pytest**, not nf-test — a separate track,
> and arguably the higher-value one given how much report logic sits there.

### Layer 2 — `nextflow_process` (biggest gap)

18 of the 19 fork-added `modules/local/` are untested in isolation (`preflight_reference` has had a process test since 2026-09-28). Two upstream modules whose *behaviour we own*, through config or through what we ship with them, have one: `VARIANTFILTRATION_FALLBACK` since 2026-10-19 and `SNPEFF_SNPEFF` (the cache's codon-table line) since 2026-11-02. The rest are only exercised transitively through the
e2e snapshot, which tells you *that* something changed, not *what* broke. Priority order by logic
density:

1. **`VARIANTFILTRATION_FALLBACK` — DONE 2026-10-19** (`tests/variantfiltration_fallback.nf.test`, 2 cases,
   ~35 s). Highest value in the repo, because its failure mode is **silent**:
   `conf/modules/joint_germline.config` records that the unquoted JEXL `TYPE==SNP` / `TYPE==INDEL`
   *matches nothing* rather than erroring (hence `vc.isSNP()` / `vc.isIndel()`), and the e2e snapshot
   can't see it — the VCFs are `.nftignore`-excluded as non-deterministic. The test runs **real GATK**
   (the JEXL has no other interpreter; a stub would exercise nothing) on the **real** unfiltered joint
   VCF of the 2-sample set (`tests/fixtures/joint_germline_unfiltered.vcf.gz`, 100 records, 61 SNPs /
   39 indels) against the test set's FASTA/`.fai`/`.dict`, and pins: the record count (soft filter —
   flags, never removes) and order; the exact FILTER string of every record (83 PASS, 14 `MQ_filter`,
   2 `SOR_FS_filter`, 1 `MQ_filter;QD_filter`, GATK joins tags alphabetically), re-derived from the
   INFO fields rather than copied; the FS gate on the six SNPs with SOR > 3.0 and FS = 0 that motivated
   it; no SNP-only tag on an indel (five indels have SOR > 3.0, one has MQ 39.46) and no indel-only tag
   on an SNP; every `##FILTER` Description equal to the JEXL verbatim (pins the six filters no record
   trips — QUAL, FS, MQRankSum, ReadPosRankSum, FS_INDEL, ReadPosRankSum_INDEL; min QUAL is 33.47);
   the `ext.prefix` file name; gatk4 4.5.0.0 in `versions.yml`. A second case is a **negative
   control**: a config next to the test rewrites the type gates to the unquoted spelling and asserts
   what GATK then does — exit 0, a per-record `undefined variable SNP` WARN in the task log, no
   type-gated tag anywhere, the universal `QD_filter` still on XV:708819 — so the main case's
   sensitivity is measured, not assumed. Two facts found on the way: the **quoted** `TYPE == 'SNP'`
   resolves on GATK 4.5.0.0 and tags the same 17 records, so only the unquoted form is the trap; and
   the earlier fixture `joint_soft_filtered.vcf.gz` is from a different (untrimmed, 2026-08-31) run
   than the current `output_ottilie_test/` VCF — same count, seven different sites — so its FILTER tally
   was no oracle. *Selector:* in `nextflow_process` isolation the module runs under its **own** name
   `GATK4_VARIANTFILTRATION` (nf-test's mock calls `${process}(*input)`, no alias possible), so a bare
   `withName: 'VARIANTFILTRATION_FALLBACK'` silently misses there — and a miss reads exactly like the
   JEXL regression (no `ext.args` → every `.` rewritten to `PASS`). The config now selects
   `'VARIANTFILTRATION_FALLBACK|GATK4_VARIANTFILTRATION'` (the bare name is included nowhere else) and
   the test asserts the `ext.prefix` name to tell the two causes apart. The `fastp_preprocessing` model
   only worked because `FASTP` is both the module's name and the selector. The contract in one line:
   **without this step every record's FILTER is `.`**, so `bcftools view -f PASS` returns zero — see
   `docs/variant-calling/haplotypecaller/SOFT_FILTER_HAPLOTYPECALLER_JOINT.md`.
2. **`SNPEFF_SNPEFF` codon table — DONE 2026-11-02** (`tests/snpeff_codon_table.nf.test`, 3 cases, ~85 s).
   The second upstream module whose behaviour we own, here through what we ship with it: the per-genome
   `snpEff.config` of the cache. snpEff ignores the annotation's `/transl_table` and keeps no genetic code
   in the `.bin` files; it reads `<db>.<contig>.codonTable : <Table>` from `<dataDir>/<db>/snpEff.config`
   at annotation time, so a cache that loses the line translates Mito with the standard code and reports
   a synonymous change at a `TGA` (tryptophan in yeast mitochondria) as `stop_lost`, silently
   (`genbank_reference_input.md` §4). The e2e cannot see it: the test set has no Mito contig. The test
   runs the **real module** (the ottilie profile's `tools` makes `conf/modules/annotate.config` apply, and
   the `ext.prefix` file name is asserted so a selector miss is told from the regression) on one
   synthetic record, `Mito:73925 A>G`, the third base of COX2's first in-frame `TGA`
   (`tests/fixtures/cox2_mito_73925.vcf`): case 1 the **shipped cache** (`params.snpeff_cache`, needs
   `data/ottilie/`) must give `synonymous_variant p.Trp56Trp`; cases 2 and 3 use a committed 25 KB
   Mito-only cache (`tests/fixtures/snpeff_cache_mito/`, runtime files only, recipe in the fixtures
   README) with the line (synonymous) and without it (`stop_lost p.Ter56Trpext*?`), the negative control
   that measures what case 1 is sensitive to and runs on a fresh clone. The gate maps it from
   `conf/modules/annotate.config` and `modules/nf-core/snpeff/snpeff/`.
3. **Matrix/cohort builders** — `build_cn_matrix`, `build_cn_cohort`, `build_sv_matrix`. Real
   transformation logic with known edge cases (the Jensen's-inequality collapse bug, `fold_change`
   re-derivation). Pure table-in/table-out — cheap, deterministic fixtures.
4. **SV merge** — `survivor_sv_merge`, `survivor_cohort_merge` (incl. the input-sort guard already
   on the roadmap).
5. **VCF manipulation** — `filter_pass_vcf`, `add_info_to_vcf`, `prepare_vcf`. Small fixtures,
   assertable record counts — same idiom as `split_joint_vcf.nf.test`.
6. **Report/format** — `generate_index`, `igvreports_*`, `cnr_to_bedgraph`, `prepare_gff3`. Watch
   determinism: igv-report HTML varies run-to-run; assert the `tableJson` blob, not the file hash.
7. **`MANTA_GERMLINE` under `--manta_high_sensitivity`** — the third upstream module whose behaviour
   we own via config, and the flag has **no automated coverage** (added 2026-09-10; it is opt-in
   only, so nothing is pending on it). Two halves, in two places: `--exome` from the `ext.args`
   closure in `conf/modules/manta_ale.config` (selector `MANTA_GERMLINE|MANTA_TUMORONLY|MANTA_SOMATIC`,
   gated on `tools` containing `manta`), and `assets/manta_high_sensitivity.ini`
   (`graphNodeMaxEdgeCount = 0`) passed as the module's config-file input from
   `workflows/sarek/main.nf` (`file(…, checkIfExists: true)` when on, `[]` when off). Fixture-less:
   run the process with the ini as input and assert the rendered command (`--exome` present, the
   `.ini` referenced) with the flag on, and neither with it off — no CRAM needed, the assertion is
   on `process.trace`/the `.command.sh`, not on a VCF. Same selector caveat as item 1, plus the
   `tools` gate must be set in the test's params. The `file`-vs-`[]` choice in the workflow is
   layer-4 territory (a `-preview`-style pipeline test), not this test.

### Layer 3 — `nextflow_workflow`

Channel wiring and metadata propagation — where this fork's real risk lives.

**First: `bam_joint_calling_germline_gatk` — the three-tier output selection.** The subworkflow picks
`recal_vcf ?: fallback_vcf ?: joint_vcf` (VQSR > filter-annotated > unfiltered) via two chained joins
on remapped keys. **Tested since 2026-10-16** (`tests/joint_calling_output_selection.nf.test`, stub mode,
three cases: no resources → the soft-filtered VCF; stub resources → the APPLYVQSR_INDEL VCF wins; the
fallback switched off by `ext.when` → the raw joint VCF, the third tier). The output-selection
logic now has a dedicated test; GenomicsDBImport and GenotypeGVCFs themselves still run only in the e2e.
The two reasons it needed one:

- **Only one branch is ever exercised.** No `known_snps_vqsr` / `known_indels_vqsr` / `dbsnp_vqsr` is
  set anywhere in our configs, so VQSR never runs and the fallback branch is always taken. The
  VQSR-wins branch is effectively dead code in ALE — untested until this test, and it would only ever activate on the
  day someone supplies known sites, i.e. the worst moment to discover it's broken.
- **The joins are asymmetric.** The VQSR join uses `remainder: true`; the fallback join does not. That
  is correct *today* only because `VARIANTFILTRATION_FALLBACK` is unconditional — give it an
  `ext.when` and `genotype_vcf` goes silently empty rather than failing. Worth pinning as a contract.

The test covers both by feeding the resource channels directly and asserting which VCF comes out —
no GATK run needed for the selection logic itself.

> **Found by this test (2026-10-16), fixed 2026-10-19:** the fallback join (`main.nf:145`, and `:154`
> for the index) had no `remainder: true`, so with no fallback VCF it emitted nothing and the third
> tier (`?: joint_vcf`) was unreachable; no run was affected, since the fallback step is unconditional.
> Both joins now carry `remainder: true` and the "neither" case asserts the raw joint VCF (it asserted
> the empty output as-is for the three days in between). The fix's first version broke the `--qc_only`
> starvation gate, caught by `tests/qc_gate.sh a`: the `ifEmpty` placeholder on the VQSR channel leaked
> through the two remainder joins as a `[meta, null]` row when nothing upstream ran; the missing
> remainder had been the guard by accident. A `filter` on the merged VCF is the guard now, and a fourth
> case (no input → nothing emitted) pins it at this level. Selector lesson from the same test: in nf-test's
> unit isolation the process is `BAM_JOINT_CALLING_GERMLINE_GATK:VARIANTFILTRATION_FALLBACK` with nothing
> before it, so `withName: '.*:BAM_JOINT_…'` never matches there; `'.*BAM_JOINT_…'` (no leading
> colon) matches both that and the pipeline's full path.

**Then**, all `subworkflows/local/`: `vcf_filter_haplotypecaller_joint`, `mutation_report` (tool-presence branching on `params.tools`),
`fastq_variant_calling_breseq` (the `subMap` regrouping),
`prepare_reference_cnvkit`. Assert what §3 calls out: ploidy/status/sex surviving the joins, and the
conditional skips (VCFtools for Mutect2/ploidy>2) actually firing.

### Layer 4 — `nextflow_pipeline`

`ottilie_e2e` covers one route (haploid, joint germline, snpeff/cnvkit/tiddit/manta). The gap is
**scenario** coverage, not more assertions: **ploidy 1 / 2 / 3** variants (each hits different
conditional logic) and any additional supported route we commit to. Cost is wall-clock, so these
want the CI/`--changed-since` work to land first.

### Sequencing

Start with the VQSR-fallback pair — the `VARIANTFILTRATION_FALLBACK` process test *and* the
`bam_joint_calling_germline_gatk` selection test (done 2026-10-19 and 2026-10-16). They're two halves of one
modification, both have silent failure modes, and neither is reachable by the e2e snapshot. Then the rest of layer 2 (largest
gap, cheapest fixtures, fastest feedback), then 3, then the ploidy scenarios at layer 4; layer 1 is
opportunistic. Prerequisite for all of it: a fixtures convention beyond the
current hand-committed `tests/fixtures/` — decide committed-small vs. Azure Blob before the file
count grows.

### Measuring it

The layer table above counts tests. Which fork lines, closures and branches those tests actually
execute is measured by `tests/nf_coverage.sh` (a JaCoCo agent on the Nextflow head JVM; a
measurement, not part of the commit gate). **Branch coverage is the headline measure** (JaCoCo
branches, two per conditional jump, so a two-operand `&&` counts six:
[`nextflow_branch_counting.md`](nextflow_branch_counting.md)); fully covered decision lines are the
worklist. Method, first results and the list of fork code that nothing executes:
[`nextflow_code_coverage.md`](nextflow_code_coverage.md).

---

## 12. What counts as validated — the contract-test rule

`ottilie_e2e` is the **contract test**: the only run whose outputs are compared against a committed
record (`tests/ottilie_e2e.nf.test.snap`). A launcher run (`bin/test_ottilie.sh`) or a pilot run
(`run_ottilie_pilot.sh`) exercises the same code but compares against nothing, so it cannot fail on a
changed output. That distinction was blurred on 2026-09-01: the SOR_FS filter change (`4c45fb8`) was
committed on the strength of a launcher run and a pilot ("2-sample end-to-end test: 173 tasks
green") and left the snapshot stale — the next plain e2e failed on six HaplotypeCaller hashes that had
nothing to do with the change being tested at the time.

**Rule.** Any change that can alter pipeline outputs — `conf/modules/*`, `subworkflows/`, `modules/`,
`workflows/`, task scripts in `bin/`, defaults in `nextflow.config` — goes through this loop before
it is committed, and the commit message names which runs were done:

```bash
export NXF_VER=25.10.4
# 1. Run the contract test normally. Do NOT pass --update-snapshot yet.
nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test
# 2. Explain EVERY snapshot difference (which file, which change caused it). An unexplained
#    difference is a finding, not noise — stop and investigate.
# 3. Re-record, then review the .snap diff as source code: only the explained lines may move.
nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test --update-snapshot
git diff tests/ottilie_e2e.nf.test.snap
# 4. Commit code + .snap together. A change that is inert at defaults commits with NO .snap change,
#    and a green plain run afterwards is the proof.
```

When two behaviour changes are in flight, re-record them **separately** (stash one, re-record the
other on clean HEAD, commit, unstash), so each `.snap` diff is attributable to one commit — the
2026-09-03 SOR_FS re-record was done exactly this way, ahead of the read-preprocessing commit.

Launcher and pilot runs remain valuable for what they *are*: the pilot is where truth-set sensitivity
is measured and the launcher is the fastest way to inspect real outputs. Record them as evidence in
the commit message or the validation doc, never as the validation itself.

### The commit gate (`bin/check_snapshot_staged.sh`, added 2026-09-04)

The rule is enforced at commit time by a gate that checks **evidence, not outputs** — it never runs a
test, it checks that the commit says which validation happened, so it takes milliseconds and a false
claim is on record:

0. `bin/check_doc_drift.sh` runs first, on every commit: the docs that copy the tree — the three
   ADDED inventories in `SAREK_MODIFICATIONS.md`, the `TESTMAP`, the docs index — must agree with it,
   or the commit is blocked with one `DRIFT:` line per fix (2026-09-28; *Docs that copy the tree* below).
1. If no *staged* file is under `conf/modules/`, `subworkflows/`, `modules/`, `workflows/`,
   `nextflow.config`, or is a task script — a `bin/` file that some `modules/**/main.nf` calls by name,
   derived at run time (2026-09-28; was `bin/*.py`) — or a report asset, a path under `${projectDir}` that a
   `report_*` param in `nextflow.config` names (the index renderer, its templates, the igv-reports templates
   and filter config under `docs/igvreports/`; derived from the config, 2026-10-06), the commit passes
   (docs / tests / tooling only).
2. Otherwise `tests/ottilie_e2e.nf.test.snap` must be staged too (outputs moved and were re-recorded),
   **or** the message must carry a trailer `Snapshot: unchanged (e2e green on <commit>, <date>)`.
3. Paths with a unit test additionally need `Module test: <name> green` in the message. The map is
   the `TESTMAP` in the script and is deliberately not copied here (the copy that used to be here
   went stale, 2026-09-28); `bin/check_doc_drift.sh` demands an entry for every process / workflow
   test under `tests/` and checks that every entry's path and test exist.
4. Staged files under `workflows/` or `subworkflows/` additionally need `Gate test: qc_gate (a) green`
   (`tests/qc_gate.sh a`, minutes): the `--qc_only` gate works by starvation, and a `toList()` /
   `ifEmpty` / value-channel input added downstream of alignment breaks it with no other symptom
   (§11, Gate row; added 2026-09-24).
5. New or removed output names in the staged `.snap` need `docs/dev-practices/output_comparison.md`
   staged too — a dated §2.10 row, since every comparison against an older run will show them — or a
   trailer `Baseline diff: <why no row is needed>` (2026-09-28).

Wiring: `.claude/settings.json` runs it as a `PreToolUse` hook on every `git commit` Claude issues
(`bin/hook_git_commit_gate.sh` extracts the `-F` file or heredoc message from the command); for
commits made by hand install it as a git hook — `ln -s ../../bin/check_snapshot_staged.sh
.git/hooks/commit-msg` (git passes the message file as `$1`). An exit code of 2 blocks with the reason.

**Known gaps in the path list (2026-09-10, both observed; the second fixed 2026-09-28):**

- **Too narrow — `conf/test/` is not a behaviour path.** A recipe edit in
  `conf/test/ottilie_common.config` (tools, `skip_tools`, the joint-calling flags) moves the e2e
  snapshot, yet passes the gate with no trailer because only `conf/modules/` is matched. Widening the
  pattern to `conf/test/` would also catch the `_az` / `_ci` profiles, which change only paths and
  never outputs, and every such commit would then need a `Snapshot: unchanged` trailer it does not
  deserve. The precise fix is to match `conf/test/ottilie_common.config` by name (the profiles include
  it; it is the only file under `conf/test/` that holds recipe). Undecided; decide before the recipe
  next changes.
- **Too wide — every `bin/*.py` is a "task script".** **Fixed 2026-09-28:** the set is now derived —
  a `bin/` file is a task script when some `modules/**/main.nf` names it — so the docs and schema
  generators (`bin/apply_schema_overlay.py`, `bin/make_params_template.py`, which no module calls) are
  out of the rule without a second list, and `bin/preflight_reference.sh`, the first `.sh` task script,
  is in it. The `*.py` pattern had let a commit staging only that file through with no trailer at all
  (verified on a scratch index before the fix). **Still too narrow until 2026-10-06:** the index renderer
  `docs/igvreports/generate_index.py` and its templates reach their process through `params.report_*`, not
  through `bin/`, so a renderer-only or template-only commit passed with no trailer. The gate now also derives
  every `${projectDir}` path that a `report_*` param names in `nextflow.config` (five today, all under
  `docs/igvreports/`); found while reviewing the new index UI, verified with a fake staged list.

### Docs that copy the tree (2026-09-28)

Some docs hold content *derived* from the tree: the inventories of added files, the unit-test map,
the docs index, task and file counts, the known-differences table. On 2026-09-28 the
reference-preflight commit updated every doc its plan named and still left five such copies stale —
two of them stale since August (the `modules/local/` list named two retired `survivor_*` modules and
lacked four SV modules; nobody had compared it with the tree). Three rules follow:

1. **A list that copies the tree is a table the drift script parses, or a pointer to one** — never a
   second prose copy. The three ADDED tables in `SAREK_MODIFICATIONS.md` are the inventory; the rebase
   runbook and this file point at them. `bin/check_doc_drift.sh` compares each table with the tree
   both ways (undocumented path, phantom row) and checks the counts in the headings and Summary, the
   `TESTMAP` against `tests/`, and `docs/README.md` against `docs/usage/` + `docs/dev-practices/` (tracked or staged files only: an untracked draft owes no row until it is staged, 2026-10-19).
2. **A measured count lives in one dated place** — its CHANGELOG entry — and other docs point there.
   The gate cannot derive "18 tasks"; fewer copies is the only fix.
3. **The doc set of a commit is derived from the *type* of change, not from the plan's doc column.**
   The checklist is the `commit-review` skill (`.claude/skills/commit-review/SKILL.md`): a new
   module / config / task script / test, a snapshot name delta, a changed count, new user-facing
   behaviour — each names the docs that must move and how to check them. Its mechanical half is the
   drift script; the gate runs it, so the skill can be skipped but its script cannot.

## 13. Benchmark claims — provenance, evidence labels, script-before-numbers

§12 covers changes to the pipeline. This covers the other thing we commit: **numbers** — the
concordance rates, retention percentages and pass-table counts that end up in `04_validate/` reports
and in user-facing docs. They get quoted back months later as settled fact, so they need the same
discipline as code. Five rules, each learned during the Manta calling-mode work: 13.1–13.3 on
2026-09-02..04, and 13.4–13.5 on 2026-09-07 — both from failures that the first three did not
prevent.

**13.1 Commit the analysis script before publishing numbers from it.** The joint-vs-per-sample
pass-table comparison ran as ad-hoc code for two days while its results were already written into
`manta_joint_at_scale/REPORT.md`. Writing it up as
[`compare_sv_pass_tables.py`](../benchmarking/ottilie_xenobiotic_ale/04_validate/compare_sv_pass_tables.py)
immediately exposed a discrepancy: the committed tables classified breakpoints against a narrower
"engineered locus" list (16 ABC transporters + ADH1) than the later analysis, which had to add URA3
and CYC1 — the cassette's own marker and terminator. Several FALSE counts were understated. Ad-hoc
code cannot be diffed, so a definition that drifts mid-analysis drifts silently.

**13.2 Every published number names its producer.** A benchmark table states the script that computes
it and the run directory it reads, so any figure can be re-derived — or falsified — without the
session that made it. Committed launchers exist for this reason even when the analysis is a one-off:
`run_sv_mode_series.sh` records how the outputs were produced, `compare_sv_pass_tables.py` how they
were scored, and `04_validate/README.md` maps every script to its results directory.

**13.3 Label a claim by its evidence, and never upgrade it silently.** The most expensive error in
that work was writing "**2 real** clone-specific rows" when the measurement only supported "2 rows
**not matching my known-artifact list**" — an absence of evidence reported as evidence. It survived
into two commits before a direct check overturned it: the parent carries 201 read pairs across the
URA3→CYC1 junction against 215 and 217 in the clones the matrix scored as carriers, so those rows are
a threshold artifact, not biology. Distinguish *measured* (a number the script computed), *inferred*
(consistent with a mechanism) and *assumed*; keep the weaker word until the stronger one is earned.
Where a script can carry the caveat itself, put it there — `compare_sv_pass_tables.py` prints, on
every run, that "candidate real" means only "not at a known engineered locus".

**Corollary — corrections stay visible.** When a number changes, say so where the old one lived, and
why. `REPORT.md` marks its falsified "~15–20" guard threshold in place rather than quietly deleting
it, because that figure had already been quoted into a plan file.

**13.4 A corrected number has copies — grep for them.** The corollary above says mark the old value
where it lived. That is not enough on its own, because a number lives in more places than the table
that produced it. `d178e34` raised the FALSE counts (13.1) and updated `REPORT.md`'s **tables**,
leaving the pre-correction values in four prose passages across three files. For three days
`manta_calling_modes.md` read "26 of 34" nine lines above a series reading "13 → 28 → 33 → 36" — the
page contradicting itself, on a public repo. It surfaced on 2026-09-07 only because someone asked
about an unrelated *caveat*, which prompted a re-read of the numbers; nothing structural would have
caught it.

So: when a number changes, grep the repo for the old value **and its derived phrasings** before
committing. The forms that survived here were `26 of 34`, `13 → 26` and `6 / 1` — prose restates
numbers in shapes that do not match the table's format, so grepping for the table layout finds
nothing. Tables are the easy half.

**13.5 Provenance includes the parameters, and defaults move under you.** A benchmark's inputs are
not only *which data* but *how it was processed*. The whole SV mode comparison — four cohort sizes,
three modes, every count in `manta_joint_at_scale/REPORT.md` — is **untrimmed-read data**, because
the Tier-2 CRAMs were made 2026-06-01 with `trim_fastq: false` and no fastp step, while the pipeline
default changed on 2026-09-04 (`948163c`) to `--trim_adapter --trim_quality_3prime tail`. Nothing
recorded this until 2026-09-07. The cohort **sample lists** were properly tracked (§F.2 of the plan
file, generators committed), so the traceability bar as written was met — and the benchmark was still
not reproducible, because rebuilding those cohorts from FASTQ today applies the new default and
yields a different experiment on the same samples.

Two rules follow:

- **Record the parameters that touch the data alongside the inputs.** The reproducibility unit is
  *sample list + read-touching parameters*. `04_validate/README.md` now states, per cohort, what to
  pass to reproduce a run **as run** versus to re-cut it against current defaults.
- **A default change is a provenance event for every number already published.** When you change a
  default, ask what it reclassifies. `948163c` retroactively made three months of SV benchmarking
  historical without altering a single file in `04_validate/`. This is the failure mode where nobody
  is wrong at any point: existing numbers change *meaning* without changing *value*, so nothing looks
  stale. CLAUDE.md already carried this caveat for the Azure baseline; the SV benchmark had identical
  exposure and no one connected the two for three days. On the next default change, grep for what
  else was built on the old one.

## 14. Cross-session state lives in one file

Several sessions work this repo in parallel, each with its own memory. Memory is reliable for what a
session did and why; it is **not** reliable for shared repo state. On 2026-09-04 one session's notes
recorded a commit as unpushed that was already on the remote, and neither session's notes knew that a
default-on trimming change had made the contract test flaky for everyone.

**Rule.** "What is committed, what is pushed, what is running" belongs in the current
`PLAN_next_checklist.md` (uncommitted working file, deleted when executed), written by whichever
session changes that state — not in per-session memory, which cannot be kept consistent. Per-session
memory keeps genuinely private context: reasoning, dead ends, user preferences. A session that
discovers something affecting another's area (a shared-test regression, a changed error path) records
it there with the commit id, so the next session reads it without having to be told.

## TODO

- [ ] Create downsampled test FASTQs and upload to Azure Blob
- [ ] Build out nf-test layers 1–4 over custom code — target and priorities in §11
- [ ] Create `test` profile in nextflow.config
- [ ] Establish truth set from current validated run
- [ ] Set up CI (GitHub Actions or Azure DevOps)
- [ ] Document fork divergences in CHANGELOG.md
