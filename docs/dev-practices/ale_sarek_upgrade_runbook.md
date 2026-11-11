# ALE-Sarek Upgrade Runbook

> ⚠️ **The "Architecture", "Repo Layout", "Upgrade Steps", and "Current Patches" sections below
> describe a PROPOSED patch-and-rebuild workflow for a future sarek rebase. It is NOT how the repo is
> built today.** As of v1.0.0 the fork is a **direct, in-place fork** of sarek 3.5.1 at the repo root —
> there is no `_upstream/` directory, no `patches/`, no `rebuild.sh`, and no `conf/ale.config`. The
> actual, as-built change inventory is [`SAREK_MODIFICATIONS.md`](SAREK_MODIFICATIONS.md).
>
> The parts of this document that describe **current reality** are
> [Known Blocker: Nextflow 26.x](#known-blocker-nextflow-26x-couples-with-a-future-rebase), the two
> *Known Rebase Hazard* sections (SnpEff cache; MultiQC container pin; VariantFiltration container), "Current Additive Files", and
> "Key Principles".

## Architecture (proposed)

The proposal: maintain a **single repo** that Seqera Cloud launches directly. `main.nf` must be at repo root. Customizations would be managed via:

- **Patches** (`_upstream/patches/*.patch`): minimal unified diffs that modify upstream Sarek files (main.nf wiring, schema, samplesheet parsing). These are disposable — regenerate when they break.
- **Additive files** (`modules/local/`, `subworkflows/local/`, `conf/ale.config`): our own code that never conflicts with upstream.
- **Spec markdowns** (`_upstream/specs/*.md`): semantic descriptions of *what* and *why* we customized. These are the source of truth. When a patch breaks, use the spec to regenerate it.

## Repo Layout

```
ale-sarek/
├── main.nf                         # Patched Sarek main.nf
├── nextflow.config
├── nextflow_schema.json            # Patched with ALE params
├── modules/
│   ├── nf-core/                    # Upstream, don't touch
│   └── local/                      # Upstream local + OUR additions
├── subworkflows/
│   ├── nf-core/                    # Upstream, don't touch
│   └── local/                      # Upstream local + OUR additions
├── conf/
│   └── ale.config                  # Our overrides (additive)
├── _upstream/
│   ├── SAREK_VERSION               # Pinned version string, e.g. "3.8.1"
│   ├── patches/                    # Ordered .patch files
│   ├── specs/                      # Decision record markdowns
│   ├── ale_modules/                # Source copies of our additive modules
│   ├── ale_subworkflows/           # Source copies of our additive subworkflows
│   └── rebuild.sh                  # Rebuild script
```

## Upgrade Steps

### 1. Prep: identify the new version

```bash
# Check latest Sarek release
git ls-remote --tags https://github.com/nf-core/sarek.git | tail -5

# Update pin
echo "3.9.0" > _upstream/SAREK_VERSION
```

### 2. Run rebuild script

```bash
bash _upstream/rebuild.sh
```

This script:
1. Clones clean upstream Sarek at the pinned version
2. Applies each patch in order
3. Copies additive ALE modules/subworkflows into place
4. Syncs result back to repo root (preserving `_upstream/`)

Then regenerate the launch-form schema from the overlay (see the note under *Current Patches*):

```bash
python bin/apply_schema_overlay.py          # heed its warnings — they flag params renamed upstream
python bin/apply_schema_overlay.py --check
python bin/make_params_template.py          # docs/usage/params_template.yml follows the visible set
python bin/make_params_template.py --check
```

### 3. If a patch fails

The script stops and tells you which patch broke. To fix:

1. Read the corresponding spec in `_upstream/specs/` to understand the intent
2. Look at what changed upstream in the affected file
3. Regenerate the patch against the new upstream
4. Re-run `rebuild.sh`

### 4. Run verification checklist

Each spec markdown contains a verification checklist. Walk through them:
- Do FastP defaults still match our expectations?
- Is the variant filtering fallback wired correctly?
- Do samplesheet extensions parse correctly?
- Does the `--qc_only` starvation gate still hold? `tests/qc_gate.sh a` must pass (minutes) — a
  rebase is when `toList()` / `ifEmpty` / value-channel inputs arrive unreviewed downstream of
  alignment. Rule: `SAREK_MODIFICATIONS.md` → `workflows/sarek/main.nf` → the `--qc_only` gate.

### 5. Test

```bash
# Minimal local test
nextflow run . -profile test,docker --skip_tools baserecalibrator

# Full ALE test dataset
nextflow run . -profile test_ale,docker --input test_data/ale_samplesheet.csv
```

### 6. Commit and tag

```bash
git add -A
git commit -m "Upgrade to Sarek 3.9.0 + ALE patches"
git tag ale-sarek-3.9.0-v1
git push origin main --tags
```

## Known Blocker: Nextflow 26.x (couples with a future rebase)

**The pipeline is pinned to the Nextflow 25.10.x line** (`manifest.nextflowVersion = '!>=24.04.2, <26.0.0'`).
A move to Nextflow 26.x / Seqera 26.1.x is **not a runtime bump — it is an nf-core template
migration** and should be done together with a nf-core/sarek 4.x rebase, not on its own.

Why: Nextflow 26's stricter config DSL cannot parse the current `nextflow.config` (inherited
nf-core 3.5.1 template boilerplate). This was investigated on 26.04.6 (2026-07-13, re-verified
2026-07-22) and is an **iceberg** — fixing the first error only exposes the next layer. All four
blockers below must be resolved before the pipeline launches on 26.x.

> ⚠️ The `<26.0.0` version guard is a **secondary** net. On 26.x the parse error (blocker 1) occurs
> *before* Nextflow can read the manifest, so the guard never fires — you get
> `Cannot read project manifest -- Config parsing failed`, not a clean version message. The
> **primary** defense is pinning the runtime: `export NXF_VER=25.10.4` (already set in the launch
> scripts `bin/CENPK_run_sarek_351_all.sh` + `bin/test_ottilie.sh`; pin the Seqera CE the same way).

**The four blockers (26.04.6 strict config DSL), verified against the current `nextflow.config`:**

1. **Top-level `def` mixed with config statements** — `def trace_timestamp = new java.util.Date()...`
   (~L386) is rejected: *"Variable declarations cannot be mixed with config statements."* Inlining the
   date into each consuming GString clears this one but exposes the layers below.
2. **`Invalid include source`** — 26.x validates `includeConfig` paths at parse time. The
   `markduplicates_bam` / `markduplicates_cram` / `prepare_recalibration_bam` /
   `prepare_recalibration_cram` profiles (~L317-322) `includeConfig` `conf/test/*.config` files that
   **do not exist** in this fork. (Same latent bug the roadmap flags for removal; these are upstream
   restart-test profiles ALE doesn't use — deleting them is the preferred fix.)
3. **`manifest is not defined` (×6)** — `${manifest.name/version/doi}` GStrings in the help/completion
   blocks (~L437, L454, L457, L462) are not resolvable under strict config.
4. **`validation is not defined` (×2)** — `validation.help.beforeText` / `afterText` (~L466-467),
   from the nf-schema plugin, not resolvable under strict config.

**Seqera compatibility (verified 2026-07-13):** Seqera Platform 25.3.x → Nextflow 25.10.2 (same line,
works); Seqera 26.1.x → Nextflow 26.04 (breaks on the above). So the pipeline runs on Seqera **only**
on a 25.3.x compute environment until the 26.x migration is done.

Line numbers drift as the config changes — match on the construct, not the number.

## Coverage tooling on Nextflow 26 / strict syntax (probed 2026-10-14 on 26.10.0; couples with the 26.x migration)

The coverage method (`tests/nf_coverage.sh`, `tests/nf_coverage_report.py`,
[`nextflow_code_coverage.md`](nextflow_code_coverage.md)) was probed on Nextflow 26.10.0 / Groovy 4.0.33 with the
strict parser on by default: [`nextflow_branch_counting/nf26/RESULTS.md`](nextflow_branch_counting/nf26/RESULTS.md).
The agent attaches and the per-line branch counts are identical to 25.10.4 (0 of 7 probe rows differ), but the
tooling records **config classes only** on 26.x, with exit 0. Since 2026-10-14 the script fails that case
(`check_scripts_recorded`, "holds no Script_* class"). Four changes, ready to apply at the migration:

1. **Agent filter** (`agent()` in `tests/nf_coverage.sh`): `includes=Script*:_nf_config_*` must become
   `includes=Script*:_nf_config_*:Main*:_nf_script_*`. The entry script compiles to the fixed-name class `Main`,
   included scripts to `_nf_script_<16 hex>`; `includeConfig`'d files are `_nf_config_<16 hex>` like the top config
   (no longer `Script<MD5>`). The filter itself stays required: without one the launcher dies with
   `NoClassDefFoundError: jdk/internal/reflect/GeneratedConstructorAccessor1` on both versions.
2. **Class-to-file map** (`tests/nf_coverage_report.py`): the log block `Parsed script files:` still lists
   `<class>: <path>` per script, so widen the regex from `Script_\w+` to `(Main|_nf_script_\w+|Script_\w+)`; the
   config line is `ConfigCmdAdapter - Parsing config file:` (was `ConfigBuilder`); `includeConfig`'d files join
   the `_nf_config_` line-fit candidates instead of the `'Script' + md5` name; the javap pass must select
   `Main*` and `_nf_script_*` too.
3. **One `Main` per merged report**: `jacococli report` fails with `Can't add different class with same name: Main`
   when two different `Main.<id>.class` sit in `--classfiles`, and every nf-test test launches its own entry
   script. Keep the `Main` whose log line maps to the repo's `main.nf`, drop the rest before the report.
4. **Constant-jump filter**: the `branch { … name: true }` catch-all compiles to
   `getstatic Boolean.TRUE; invokedynamic cast; ifeq` instead of `iconst_1; ifeq`. Add that pattern (same
   "not itself a jump target" guard) or the four `mutation_report/main.nf` defaults return to the counts and
   the headline reads 514 / 920 again.

**Strict-syntax migration estimate** (`NXF_VER=26.10.0 nextflow lint .`, nothing fixed, the lines for tracked files in
`nextflow_branch_counting/nf26/out/ale_lint.txt`): **432 errors in 94 files** of the pipeline tree, 67 in
`main.nf` (26 top-level `params.*` statements mixed with declarations, the rest cascading "not defined"), 19 in
`nextflow.config` (the four blockers above plus the computed `includeConfig` paths), 257 in `subworkflows/local/`
(46 files), 44 in `conf/` (27 files), 31 in unmodified `modules/nf-core/` (17 files), 0 in `modules/local/`.
Many are cascades of one root cause per file; the count sizes the lint output, not the work.

## Known Rebase Hazards: SnpEff cache (couples with any 3.9.0+ rebase; verified 2026-09-07)

Two upstream changes in this one area land together at the next rebase. Neither is caused by ALE code,
both break ALE's current cache handling, and the second is **dropped rather than ported** if the
tarball item in `roadmap.md` → *Onboarding* is done first.

1. **snpEff 5.1 → 5.4.0c** (sarek master `modules/nf-core/snpeff/snpeff/environment.yml`). snpEff
   refuses a database outside its compatibility window — `Database version: '5.2', Program version:
   '5.1', Compatible versions: '[5.1, 5.0]'` (sarek #1654). **Every ALE cache was built with 5.1**:
   `process_genbank_auto.sh`, `build_snpeff_cache.sh`, `02_reference_prep/prepare_s288c_reference.sh`, the published `snpeff_cache.tar.gz`,
   and the `az://aletest/ottilie/v{1,2}/*/snpeff_cache/` directories. At the rebase: read the 5.4 window,
   expect to **rebuild every cache** with the new container, and **re-record the e2e snapshot** (ANN
   strings can move with a rebuild). The standalone cache builder (roadmap) turns this into a re-run.
   `--download_cache` and the stock `R64-1-1.105` only become options again if the bumped snpEff reaches
   the current AWS database host — the 5.1 container's built-in host is dead (sarek #1980).

2. **`subworkflows/local/annotation_cache_initialisation` is deleted upstream (3.9.0, #2194)**, replaced
   by nf-core `subworkflows/nf-core/utils_annotation_cache`. ALE's edit to the local file — skip
   `exists()/isDirectory()` for `az|s3|gs://` paths, because Azure blob prefixes are not directories —
   has no file to land on. The nf-core version applies the `<db>/<db>/` key to **every** cloud URL (3.5.1
   applied it only to the exact `s3://annotation-cache/…` URL) *and* still runs the directory check. So
   a flat `az://…/snpeff_cache/R64-1-1.105/` directory — what `ottilie_test_az`, `ottilie_pilot_az` and
   the Launchpad params box use today — **fails at DAG build** under the new code. Two ways out:
   - (a) port the cloud-path skip as an `nf-core subworkflows patch` on the managed file — the
     highest-maintenance patch class this fork carries;
   - (b) ship the cache as a `.tar.gz` blob: staged as a plain file, it never enters that subworkflow,
     so the patch is dropped instead of ported. Needs the tarball item first, then the az profiles and
     the params box switched to the tarball.

   Related, same rebase: 3.10.0 (#2184) removed `format: directory-path` from `snpeff_cache` and added
   it to `validation.defaultIgnoreParams`, but **kept the schema `default`**
   `s3://annotation-cache/snpeff_cache/`. The Seqera launch form injects that default over profile
   values (`azure_batch_execution.md` §13), so the overlay's key-removal for `snpeff_cache` must be
   re-applied after taking the upstream schema.

**Where the tarball hook must live to survive this:** an additive `subworkflows/local/` file plus ~8
lines in `main.nf` around the cache block, keyed on the `snpeff_enabled` boolean — a `take:` of both the
3.5.1 local subworkflow and `utils_annotation_cache`, and both emit `[meta, cache]`, so the hook is the
same on either side of the rebase. **Do not** put it inside `annotation_cache_initialisation`.

Sources (read 2026-09-07): sarek #1654, #1980, #2184, #2194; nf-core/modules
`subworkflows/nf-core/utils_annotation_cache/main.nf`; sarek master `main.nf` cache block.

## Known Rebase Hazard: VariantFiltration container (re-decide at every rebase; added 2026-10-01)

`modules/nf-core/gatk4/variantfiltration/main.nf` + `environment.yml` run `VARIANTFILTRATION_FALLBACK` on
`biocontainers/gatk4:4.5.0.0`, the image of the other 20 GATK modules of the 3.5.1 tree, instead of the
module's own `gatk4_gcnvkernel` Wave image (GATK 4.6.2.0, a 2 GB layer used by nothing else — the cause
of two ~90-minute waits on Seqera Platform on 2026-10-01, `azure_batch_execution.md` §18). The rule to
carry across a rebase is the *alignment*, not the version: after the rebase this step must run on the
same GATK image as HaplotypeCaller / GenotypeGVCFs in the new tree. If upstream's GATK modules have all
moved to one shared image, take upstream's container and drop the patch; if they are still split, re-apply
it with the new tree's image. Either way the versions manifest line for `VARIANTFILTRATION_FALLBACK`
moves with it, and the soft-filtered VCF must stay record-identical (compare `FILTER` tallies on the
contract test's joint VCF).

## Known Rebase Hazard: MultiQC container pin (drop at any 3.10.0+ rebase; added 2026-09-24)

`modules/nf-core/multiqc/main.nf` + `environment.yml` pin MultiQC **1.35** on the sarek-3.5.1-era
module (container URIs + conda version only; `modules.json` still names that module's git_sha). sarek
3.10.0 and `dev` pin the same 1.35, but through a **new-signature module**: one
`[meta, files, config, logo, replace_names, sample_names]` input tuple, meta-tupled outputs
(`GENERATE_INDEX` reads `MULTIQC.out.data`, so its input mapping changes), and the version reported via
an `eval` topic that needs the `nf-core-utils` plugin and Nextflow ≥ 25.04. At the rebase: **take
upstream's module and drop this pin** — do not port it — and expect the topic-channel /
versions-manifest migration with it. The e2e snapshot was re-recorded for 1.35 on 2026-09-24, so the
rebase's own MultiQC diff should be empty apart from the module's wiring. Rationale and the measured
output changes: `SAREK_MODIFICATIONS.md` → `modules/nf-core/` PATCHED; `output_comparison.md` §2.10.

## Current Patches (maintain this list)

| Patch | Modifies | Purpose | Spec |
|-------|----------|---------|------|
| `001-samplesheet-ale-columns.patch` | samplesheet_to_channel/, schema | Add ALE metadata columns to input CSV | `specs/samplesheet_extensions.md` |
| `002-main-nf-fallback-wiring.patch` | main.nf | Wire VARIANTFILTRATION_FALLBACK after joint genotyping | `specs/variant_filtering.md` |
| `003-schema-ale-params.patch` | nextflow_schema.json | Add ALE-specific params to Seqera launch UI | `specs/samplesheet_extensions.md` |
| `004-multiqc-container-pin.patch` (as built: in-place edit, 2026-09-24) | modules/nf-core/multiqc/ | Pin the MultiQC 1.35 container on the 3.5.1-era module; **drop, don't port**, at a ≥ 3.10 rebase | `SAREK_MODIFICATIONS.md` → `modules/nf-core/` PATCHED |

> **Schema visibility is NOT patched** (since 2026-09): the launch-form hidden/visible state and the
> ALE-owned help texts live in `conf/schema_overlay.yml`, applied by `bin/apply_schema_overlay.py`.
> Since 2026-10-04 the overlay also sets validation keywords on the path parameters (`pattern` and
> `exists` on `report_gff3`, an `allOf` Azure-path rule on five fields): check them against the new
> upstream entries of those parameters, the overlay replaces a keyword it names.
> After applying patches to a new upstream `nextflow_schema.json`, re-run
> `python bin/apply_schema_overlay.py` (then `--check` in verification) — see
> `SAREK_MODIFICATIONS.md` → root files → `nextflow_schema.json`.

## Current Additive Files (these never conflict) — as built

Purely additive, so a rebase carries them over untouched. Full list and per-file rationale in
[`SAREK_MODIFICATIONS.md`](SAREK_MODIFICATIONS.md).

- **`modules/local/`, `subworkflows/local/`, `conf/`** — the inventory is the three ADDED tables in
  [`SAREK_MODIFICATIONS.md`](SAREK_MODIFICATIONS.md), one row per path, kept equal to the tree by
  `bin/check_doc_drift.sh` on every commit (2026-09-28; this bullet used to copy the list and had been
  stale since the SURVIVOR retirement). Removals are recorded there too (`vcf_filter_mutect2/`,
  `vcf_filter_freebayes/` — 2026-09-09, tag `tier2-tools-archive`, `docs/archive/tier2/README.md`).

The hard-filter fallback is **not** a local module: it reuses the nf-core module
`modules/nf-core/gatk4/variantfiltration/`, aliased as `VARIANTFILTRATION_FALLBACK` inside
`subworkflows/local/bam_joint_calling_germline_gatk/` (a *modified* upstream subworkflow, so it does
carry rebase cost).

## Key Principles

- **Patches are small and disposable.** Each patch should be <100 lines of diff. All real logic lives in additive files.
- **Specs are the source of truth.** If a patch is lost or broken beyond repair, the spec contains enough detail to rewrite it from scratch.
- **Additive files never touch upstream code.** They only get `include`-d by patched files.
- **Skip releases you don't need.** Only upgrade when a new Sarek version has features or fixes relevant to ALE.
