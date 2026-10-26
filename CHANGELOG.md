# ALE Yeast pipeline: change log

## Unreleased

### Repository

- **Repository transferred to `nnf-bright-biofoundry/ALE_Yeast` (2026-10-23)**, from
  `Aletechdev/ALE_Yeast`. `manifest.name` and `manifest.homePage` follow the handle (the project rule:
  `nextflow run <name>` resolves against GitHub, and Seqera shows one name per pipeline only when the two
  agree), so the pipeline line of `versions.yml` reads `nnf-bright-biofoundry/ALE_Yeast: v1.0.0` and the
  MultiQC Workflow Summary section is keyed `nnf-bright-biofoundry-ALE_Yeast-summary` (re-keyed in
  `assets/multiqc_config.yml` and the e2e test). The README and new-machine clone commands, the launch
  form's image URLs, the Launchpad registration script and the Launchpad entry itself point at the new
  handle. GitHub redirects the old URL, so existing clones keep working; `git remote set-url origin
  git@github.com:nnf-bright-biofoundry/ALE_Yeast.git` is still the right move. Dated records (RUNBOOK
  entries, baseline comparisons, the sarek 3.5.1 benchmark rows) keep the handle that was current when
  they were written. The ghcr mirror of the report image is named after the repo owner by the CI
  workflow: a manual build on 2026-10-26 created `ghcr.io/nnf-bright-biofoundry/ale-reports` on first
  push with the repo's built-in token, no package set-up needed; the `1.0.0` mirror and the Docker Hub
  image the pipeline pins are unaffected. The Seqera workspace holds no GitHub credential since
  2026-10-26: the public repo clones anonymously (verified by a Platform run), and the expiry hook no
  longer tracks a token (`deploy/azure/seqera-sp/RUNBOOK.md`, *GitHub PAT*).

- **Git history rewritten (2026-08-31)** with `git filter-repo` to purge private experiment data
  before open-sourcing. Every commit SHA changed; SHAs recorded before this date refer to the
  pre-rewrite history. Purge list + full old→new commit map:
  `docs/dev-practices/history_rewrite_2026-08.md`.

### Added

- **The soft-filter step has a dedicated test on real data** (2026-10-19;
  `tests/variantfiltration_fallback.nf.test`, `nextflow_process`, real GATK, 2 cases, ~35 s). The module
  is stock nf-core; what is ours is the JEXL in `conf/modules/joint_germline.config`, whose failure
  mode is silent (the unquoted `TYPE == SNP` matches nothing and leaves a well-formed VCF), and the e2e
  cannot see a VCF's FILTER column. The test feeds the real unfiltered joint VCF of the 2-sample set
  (new fixture `tests/fixtures/joint_germline_unfiltered.vcf.gz`, 100 records, 61 SNPs / 39 indels) and
  the test set's reference to the module and pins the exact FILTER string of every record (83 PASS,
  14 `MQ_filter`, 2 `SOR_FS_filter`, 1 `MQ_filter;QD_filter`, re-derived from the INFO fields and equal
  to GATK's output of that run), the record count and order, the FS gate on the six SNPs with
  SOR > 3.0 and FS = 0, that no SNP-only tag lands on an indel and vice versa, every `##FILTER`
  Description, the `ext.prefix` name and the GATK version. A negative control (a config next to the
  test) runs the unquoted spelling and asserts what GATK does with it: no type-gated tag, the universal
  `QD_filter` still on one record, a per-record WARN only in the task log. Found on the way: in
  `nextflow_process` isolation the module runs under its own name, so the bare
  `withName: 'VARIANTFILTRATION_FALLBACK'` missed and read exactly like the regression; the selector is
  now `'VARIANTFILTRATION_FALLBACK|GATK4_VARIANTFILTRATION'` (pipeline behaviour unchanged, e2e snapshot
  unchanged). Also: the quoted `TYPE == 'SNP'` resolves on GATK 4.5.0.0, and the 2026-08-31 fixture
  `joint_soft_filtered.vcf.gz` is from a different run than the current `output_ottilie_test/` VCF
  (same count, seven different sites). The commit gate maps the module directory and the config to the
  test (a path may now cite several tests). `testing_best_practices.md` §11 layer 2 item 1.
- **The joint-calling output selection has a dedicated test** (2026-10-16;
  `tests/joint_calling_output_selection.nf.test`, stub mode, 86 s). Three cases drive
  `BAM_JOINT_CALLING_GERMLINE_GATK` as a unit through the three-tier choice
  `recal_vcf ?: fallback_vcf ?: joint_vcf`: no known-variant resources (the ALE route) emits the
  soft-filtered VCF; stub resources launch the four VQSR steps and the recalibrated VCF wins; the
  fallback switched off by `ext.when` (a config next to the test) leaves `genotype_vcf` empty, which the
  case asserts as the current behaviour, intended assertion in its comment. Each case also pins which
  processes launched. Zero-byte placeholders under `tests/fixtures/stub_cram/` (four added). The
  VQSR-wins tier had never run in this fork. GenomicsDBImport and GenotypeGVCFs still run only in the
  e2e. The commit gate maps the subworkflow and `conf/modules/joint_germline.config` to the test.
  Found on the way: the selector trap again (`'.*:BAM_JOINT_…'` never matches in unit isolation, the
  process name there has nothing before it; the no-leading-colon form resolves in both contexts) and
  the join defect (fixed 2026-10-19, under *Fixed*). `testing_best_practices.md` §11 layer 3.
- **Coverage re-measured after it** (2026-10-16, `84e8274`, same versions as 2026-10-13): branch coverage
  of fork code 514 → 516 of 916; the two output-selection lines 2/4 → 3/4 (the ceiling until the join
  is fixed); closures and fully covered decision lines unchanged. Found on the way: with a third `-c`
  config the report maps a short config's class to the wrong file (line denominators only; recorded
  as a limit, fix pending). `nextflow_code_coverage.md` → *Results (2026-10-16)*.
- **SNV / InDel events table: every PASS site is in the page** (2026-10-07; `docs/igvreports/generate_index.py`,
  `docs/igvreports/templates/index.html.j2`). A third view, *All PASS sites*, lists the strain background every sample
  shares and the carried sites with no sample to compare against; the default views (*Protein-changing*, *All differing*)
  and every count are unchanged (test set: 5 / 24 / 83; pilot: 46 / 201 / 399). Rows ship differing first, so the
  1,000-row cut never drops a differing site for a shared one. Found on the way, with read-level evidence: a carried PASS
  site where every other sample has *no reads* is HaplotypeCaller recording a genome-to-cassette junction it assembled in
  one sample only (zero-depth reference block in the others, 30 to 200 soft-clipped reads overlapping); on the test strain
  these are the PDR15, VMR1, HIS3 and CAN1 junctions, so the differing rule rightly leaves them out and the Methods say so.
  Without SnpEff the toggle reads *Differ between samples* / *All PASS sites*. CSV unchanged; `index.html` is name-only in
  the snapshot.
- **Mutation report index redesigned** (2026-10-06; `docs/igvreports/templates/index.html.j2` from the design
  handoff, `docs/igvreports/generate_index.py`, `modules/local/generate_index/main.nf`; contract in
  `docs/igvreports/templates/README.md`). Light document style, sticky section nav, a ruled Summary table instead of
  cards, provenance block in the header (commit, Nextflow and Seqera ids, session, output path with a Copy button, the
  report bundle's folder when it differs). Samples table with a QC status column graded by ten new hidden parameters
  `report_qc_*` (median coverage, breadth at ≥ 20× from MultiQC general stats, mapped %, duplicates %, a relative
  check at 0.33 of the cohort median coverage, the amber depth of the events table); a failed sample is named in the
  Summary. SNV / InDel: one Locus column, VAF cells with depth, a per-sample panel on click with a link into that
  sample's IGV report at the locus, an *IGV, all samples* button, the row cap raised from 300 to 1,000 with the full
  counts printed and a notice when cut, the three wordings kept (annotated, without SnpEff, one sample). SV: Type /
  Location / Length layout, a *Differ between samples* toggle. Copy number: the three tabs replaced by a Whole
  chromosomes table (samples as rows, TIDDIT / CNVKit source toggle, Mito coloured against the cohort median) and a
  Changed windows table with per-sample strips, chromosome chips and a hide-shared toggle; *All bins CSV* download.
  Methods: the eight previous sections after a generated QC-thresholds entry. Presentation mode (`?present`, key P).
  Dark mode and Google Fonts are gone; the page stays offline. Validated by the e2e contract test (snapshot unchanged:
  `index.html` is name-only, `data/snv_indel_sites.csv` identical) and headless Chromium on the 2-sample, pilot and a
  synthetic 60-sample render.
- **Commit gate: report assets count as output-changing paths** (2026-10-06; `bin/check_snapshot_staged.sh`). Every
  `${projectDir}` path a `report_*` param names in `nextflow.config` (the index renderer, its templates, the
  igv-reports templates and filter config under `docs/igvreports/`) now demands the e2e trailer like a `bin/` task
  script; a template-only commit used to pass with no trailer.
- **Mutation report index: readable at a glance, plus an SNV / InDel events table** (2026-09-30;
  `docs/igvreports/templates/index.html.j2`, `docs/igvreports/generate_index.py`). Header with a
  version chip (`--pipeline-version`, the manifest version), four tool chips and jump links; summary
  cards with a note line instead of threshold-laden labels (the QC card is gone, MultiQC is a header
  link; the "CN windows" card now counts windows that cross the threshold; the complete-output folder
  line moved from the header to below the cards); two-line notes above the tables; the three
  copy-number tables as tabs under one fold-change / log2 toggle; short headings.
  New **SNV / InDel events** section: PASS sites where at least one sample carries the variant and at
  least one is called reference (no parent label needed; a sample with no reads at the site is
  neither), protein-changing (SnpEff HIGH / MODERATE) view by default, all differing sites one click
  away, per-sample VAF cells as whole percent with genotype, allele counts and depth on hover or on
  click / tap (*no reads* where the site had no coverage), a ‡ on multi-allelic rows, header filters,
  capped at 300 rows; without SnpEff the gene columns are absent and every differing site is listed;
  with one sample every carried PASS site.
  The *SNV / InDel sites* card jumps to it; the section links the all-samples IGV report. Downloads:
  *CSV · all sites* (new bundle file `mutation_reports/data/snv_indel_sites.csv` — every joint-call
  row with FILTER, the multi-allelic site's alleles, SnpEff gene / effect / impact / HGVS, a
  `differs_between_samples` flag and per-sample GT / AD / DP / VAF), *VCF · all sites* (the cohort
  VCF under `vcf/haplotypecaller/`) and
  *CSV · rows shown* (the table as filtered). Stale Methodology text fixed: the SNP strand-bias
  filter reads `SOR_FS_filter` with its FS gate, the hard filter is described as opt-in, the VCF
  preparation source points at the pipeline's `PREPARE_VCF`. The report container has no bcftools,
  so the prepared cohort VCF is now read in pure Python (the old count helper silently returned
  nothing in every pipeline run). Tabulator 6.3 stalls the page on `maxHeight`, so tables use fixed
  or natural heights only.
- **Seqera Outputs tab: downloads as their own entries** (`tower.yml` 2b / 2c / 3b / 4b). The
  Platform previews a report in an iframe sandboxed without `allow-downloads`, so a page link in the
  index opens but a CSV / VCF link does nothing (the content host serves every file under the bundle
  once the preview's cookie is set — verified with curl; the same cookie refuses `../multiqc/`).
  The index detects the frame, says so beside each download row (right-click → *Open link in new
  tab* works: a browser-opened tab is not sandboxed) and hides the browser-generated export. Runbook
  entry 2026-09-30.
- **Mutation report index names the run that produced it** (2026-10-01). A *Run* line under the
  complete-output folder: run name, start time (UTC), pipeline commit (linked to GitHub; absent on a
  run from a local directory), Nextflow version, session id and — on a run launched by Seqera
  Platform — the Seqera run id, read from the `TOWER_WORKFLOW_ID` variable Platform sets on the head
  job. New optional, hidden parameter **`seqera_workspace_url`**: the workspace's browser URL
  (`https://cloud.seqera.io/orgs/<organisation>/workspaces/<workspace>`); with it the run id links
  `<url>/watch/<run id>`, without it the id is plain text. A run cannot learn that address itself
  (the names are not in its environment; Platform hands the watch URL to the Tower plugin, which
  keeps it private — RUNBOOK 2026-10-01), so it is set once per deployment: in the Launchpad entry's
  parameters or a config file. The `ottilie_test_az` / `ottilie_pilot_az` profiles set it for the
  project workspace. The run metadata is part of `GENERATE_INDEX`'s task hash, so a resumed run
  re-renders the index under its own name.
- **Mutation report index needs no network** (2026-10-01). Tabulator 6.3.0 (MIT) is vendored under
  `docs/igvreports/templates/vendor/tabulator-6.3.0/` (the pristine `dist/` files of
  `tabulator-tables@6.3.0` from unpkg, plus its `LICENSE`) and `generate_index.py` inlines the script
  and stylesheet into `index.html`, which grows from ~110 KB to ~580 KB on the test set. Before, a
  page opened without internet showed its text and no table at all. A templates folder without the
  vendor directory still renders, linking the CDN copy as before. **Only the index**: the
  all-samples report and the per-sample IGV pages still load Tabulator and igv.js from their CDNs.

- **Three MultiQC reports, the early two while the run continues** (`docs/usage/qc_first_run.md` →
  *The three MultiQC reports*). `multiqc/yAMP-read-QC_multiqc_report.html` (input checks, FastQC raw
  and after preprocessing, fastp) is published as soon as read QC ends, and
  `multiqc/yAMP-alignment-QC_multiqc_report.html` (+ duplicate metrics, samtools stats, mosdepth) as
  soon as every sample is aligned. The complete report is titled *yAMP complete-QC* but keeps its
  file names (`multiqc_report.html`, `multiqc_data/`). On Seqera Platform the Outputs tab lists each
  early report within about a minute of publication, while the run is still calling (entries *6a*,
  *6b*; measured on run `5CiOiON5oJuETn`: the tab fills during the run). The read-QC report replaces
  the QC-only run's *yAMP QC-only run* report — a QC-only run now writes the same read-QC report as
  any other run (`yAMP-QC-only-run_multiqc_report.html` is no longer written), and the follow-up run
  rewrites it. `multiqc_title` is now the prefix of all three titles. The two early reports request
  1 CPU / 6 GB (MultiQC is single-threaded; a 4-CPU request would wait for a whole free slot while the
  callers run); the complete one keeps upstream's 4 CPUs / 12 GB.
- **Input checks in every MultiQC report** — the *yAMP input checks* table (first section) lists
  every start-up check with its verdict: samplesheet (experiment ids, files listed once, ploidy and
  clonal flag per experiment), parameters (Tier-1 recipe, `--qc_only`) and the reference check's row
  (formerly the *yAMP preflight: reference* table). OK rows included, so the log is no longer needed
  to see what was checked; also written to `reports/preflight/preflight_samplesheet_params_mqc.tsv`.

- **QC-first run — `--qc_only`** (user page `docs/usage/qc_first_run.md`). A launch with the flag
  stops after read QC — preflight checks, FastQC on the raw reads, fastp, FastQC on the fastp output,
  MultiQC, plus reference preparation — exits 0 and prints where the report is and the exact
  follow-up command: the same command without the flag plus `-resume <session id>`, which continues
  from alignment with every read-QC task cached (on Seqera Platform: *Resume* with `qc_only`
  cleared). The QC-only MultiQC report is titled *yAMP QC-only run*, so it lands as
  `multiqc/yAMP-QC-only-run_multiqc_report.html` next to the final report (a user `multiqc_title`
  names both runs' reports the same, so the final one then replaces it). Refused at start-up
  (`[yAMP preflight]` errors): `--step` other than `mapping`, `multiqc` skipped, `cleanup = true`.
  breseq is not run in a QC-only run. Mechanism: one starvation gate before alignment in
  `workflows/sarek/main.nf` (the alignment input is emptied; everything downstream never gets a task,
  so the DAG is unchanged and the resume is exact). Guarded by `tests/qc_gate.sh` — part (a), minutes:
  the QC-only run of the test set executes exactly the allow-listed processes (17 tasks, 14
  processes; 18 / 15 since the reference preflight task below); part (b), one e2e: the resumed run caches every run-1 task, matches a one-shot run's
  task list and produces identical deliverables (`tests/qc_gate_compare.py`; measured 2026-09-24
  against the e2e output: 16/152 tasks cached, 526 file names equal, 143 files md5-identical, 42/42
  VCFs record-identical). The commit gate now
  requires `Gate test: qc_gate (a) green` for changes under `workflows/` or `subworkflows/`. Default
  path unchanged (e2e snapshot unchanged). Launch-form group *QC-first run*; `tests/preflight.nf.test`
  gains three cases (8 in total). **Verified on Seqera Platform 2026-09-28** (runs `5m9NorL3JmkHFq` →
  `464Scp5QNoznbD`, `deploy/azure/seqera-sp/RUNBOOK.md`): run 1 18 tasks / 15 processes; the Resume
  17/153 cached with deliverables identical to the local e2e of the same commit. Scripted:
  `deploy/azure/seqera-sp/15_launch_run.sh` (launch, or `--resume` = Platform's Resume, with `--set`
  overrides on the committed params box), `16_watch_run.sh` (status until the run ends; UNKNOWN is a
  grace period, not an outcome) and `17_download_outdir.sh` (outdir download with the pipeline's SP).
  `tower.yml` lists the QC-only MultiQC report on the Outputs tab (`702a4c0`).

- **Coverage of the Nextflow code by the test suite** (dev tooling, 2026-10-02; a measurement, not a
  gate). `tests/nf_coverage.sh` attaches a JaCoCo agent to the Nextflow head JVM and reports, for our
  `.nf` and `.config` files, the lines executed, the data-driven closures entered and the conditions
  seen every way, for all code and for fork lines only. Method, the first measurement, the fork code
  that no test executes and the limits: `docs/dev-practices/nextflow_code_coverage.md`.

- **Commit gate: doc-drift check, snapshot name-delta rule, derived task scripts; `commit-review`
  skill** (dev tooling, 2026-09-28). `bin/check_doc_drift.sh` runs on every commit and blocks when a
  doc that copies the tree disagrees with it: the three ADDED inventories in `SAREK_MODIFICATIONS.md`
  (now one-row-per-path tables; the module list had been stale since the SURVIVOR retirement), the
  gate's unit-test map (every process / workflow test must be mapped — `manta_experiment_grouping`
  was not) and the docs index. The gate also demands a dated `output_comparison.md` §2.10 row (or a
  `Baseline diff:` trailer) when the staged e2e snapshot adds or removes output names, and derives
  "task script" from what `modules/**/main.nf` calls instead of `bin/*.py`, which had let the first
  `.sh` task script through with no trailer. `.claude/skills/commit-review/SKILL.md` is the judgement
  half: the docs a commit must move, derived from what is staged. `testing_best_practices.md` §12.

- **Reference preflight task** (`PREFLIGHT_REFERENCE`; `docs/usage/preflight_checks.md` → *Reference
  files*). The first task of every run — at every `--step`, and in a QC-only run — reads the reference
  files themselves (so cloud paths are staged) and checks that the `--report_gff3` contig names are the
  FASTA's: error when no name is shared (the mutation report's gene track would be empty and nothing
  else would complain; Ensembl `I` against SGD/NCBI `chrI` is the typical case). GFF3 contigs the
  FASTA lacks are noted in the OK row, not warned about — the release test set is a chromosome
  subset of a fully annotated genome (decision 2026-09-28; a partial naming mismatch such as `Mito`
  vs `chrM` is therefore only visible as that note, to be revisited on a real case). An embedded
  `##FASTA` section is ignored; SKIPPED without a GFF3. Verdicts go to a *yAMP preflight: reference*
  table in MultiQC and to `reports/preflight/preflight_reference_mqc.tsv`; only an ERROR reaches the
  console, with the
  `[yAMP preflight]` prefix. An error terminates the run (exit 65, no retry; own config block
  `conf/modules/preflight.config`). Nothing downstream consumes the task, so no other task hash
  changed. One check by decision; the others (FASTA syntax, user-supplied `.fai`/`.dict`, the SnpEff
  cache) are roadmap rows, to be added as real input errors turn up. Checks in
  `bin/preflight_reference.sh` (gawk container); test `tests/preflight_reference.nf.test` (4 cases on
  hand-made fixtures); on the QC-only allow-list.

- **Preflight checks at start-up** (`[yAMP preflight]`, user page `docs/usage/preflight_checks.md`).
  Before any task runs: hard errors for a samplesheet with no experiment id (a `patient` header —
  including the pipeline-written `csv/*.csv` restart sheets — is parsed as empty by the input
  schema, and the run would silently merge every experiment into one cohort) and for the same
  input file listed in two rows; warnings for every parameter that drifts from the validated
  Tier-1 recipe (callers, joint-calling flags, read-preprocessing settings — `tools` compared as a
  set) and for mixed ploidy or clonal/population flags within an experiment. The ottilie profile
  produces zero lines; `tests/preflight.nf.test` (preview mode, 5 cases) pins that and each check.
  Found while writing the test: **any `--tools` set without an annotator (`snpeff`, `vep`,
  `merge`, `bcfann`) aborts at DAG build** since the 2026-09-09 Tier-2 filter removal (a dangling
  `vcf_with_tbi` reference behind the mutation-report input; surfaces as the misdirected
  "sample-sheet only contains tumor-samples" error) — fixed in the next commit (see *Fixed*).

- **Post-trim FastQC.** FastQC now also runs on the fastp output — the reads that are aligned — so
  trimming results are assessed, not only reported by fastp (`FASTQC_TRIMMED_QC`,
  `subworkflows/local/fastqc_trimmed/`). With `split_fastq > 0` the shards are concatenated per mate
  first (nf-core `cat/fastq`), so both modes give one report per mate per lane under
  `reports/fastqc/<id>/trimmed/` (`<id>_trimmed_{1,2}_fastqc.*`). MultiQC shows two FastQC sections
  — *FastQC (raw)*, fastp, *FastQC (after preprocessing)* — whose General Stats columns share the
  sample rows (`_trimmed` stripped by an `extra_fn_clean_exts` rule; behaviour measured on the pinned
  MultiQC 1.25.1). `--skip_tools fastqc` skips both passes. Nothing downstream consumes the new
  outputs, so no existing task hash changes. Unit test `tests/fastqc_trimmed.nf.test` (unsplit, split
  with an empty shard, single-end lone file); the e2e contract test asserts the MultiQC layout. Closes
  finding F of `docs/dev-practices/fastq_preprocessing_audit.md`; user page
  `docs/usage/read_preprocessing.md` → Post-trim QC.

- **Dashboard header names the complete-output folder.** `mutation_reports/index.html` now prints
  "Complete output: `<outdir>`" (the run's resolved `outdir` — a local absolute path or the `az://`
  URL on a cloud run — plus the report bundle's own folder when `report_outdir` moves it). Motivation:
  in Seqera's *Outputs* tab the index is what people open, and the outdir was hard to find in the
  launch view. Resolved as a string (not `file()`) so a cloud outdir needs no credentials at
  DAG-build time. `GENERATE_INDEX` takes two new `val` inputs; `generate_index.py --outdir /
  --report-dir`.

- **ALE-specific `tower.yml`** (Seqera *Outputs* tab): lists the mutation-report entry points
  (index, cohort report, per-sample IGV reports), the three cohort CSVs and one MultiQC — replacing
  sarek's inherited list of per-sample txt tables and never-produced ASCAT/Control-FREEC/VEP entries.
  Verified on Platform 2026-09-11 (run `5s5ufIqc8nWdNn`); the index's relative links resolve inside
  the tab's preview.

- **Read preprocessing organised as four steps** (schema group "Read preprocessing", user page
  `docs/usage/read_preprocessing.md`): step 0 UMI consensus (hidden) → fastp step 1 adapter trimming
  `trim_adapter` (+ `adapter_sequence`, `adapter_sequence_r2` for kits fastp cannot infer;
  `trim_fastq` kept as a deprecated alias) → step 2 fixed-count clipping (upstream `clip_*`) →
  step 3 quality trimming per read end `trim_quality_3prime` (`tail` | `right`) / `trim_quality_5prime` with shared `trim_quality_mean` (20)
  and `trim_quality_window` (4) — a variable number of bases by quality, Trimmomatic
  `TRAILING`/`SLIDINGWINDOW`/`LEADING` analogues → step 4 read filtering `filter_quality` (on, as
  upstream) with visible thresholds `filter_quality_phred` (15) / `filter_quality_percent` (40) and
  `length_required`. Parameter descriptions carry their step; UMI and split-publish params are hidden.
  The FASTP gate also fires on the quality-trimming params. Recommended ALE recipe
  `--trim_adapter --trim_quality_3prime tail` — **the default since 2026-09-04** (reads are no longer
  aligned as sequenced unless `--trim_adapter false` and `trim_quality_3prime` unset; the Azure
  baseline byte-comparison is invalidated until re-cut). Design + measurements:
  `docs/dev-practices/fastq_preprocessing_audit.md` §2. Module test: `tests/fastp_preprocessing.nf.test`.

- **TIDDIT soft filters for the SV pass view** (`TIDDIT_SV_FILTER`): three Manta-inspired named
  vetoes — `LowSupport` (<6 pairs+splits), `LowQual` (TIDDIT QUAL <40), `HighMQ0` (>40% low-MAPQ
  reads at a breakend) — appended softly to the per-sample SV-merge input. The pass matrix/VCF
  excludes them; the union view keeps every record with its reason; published caller VCFs are
  untouched. Calibrated on the no-SV pilot truth set (56/86 TIDDIT-only pass rows removed, 0
  Manta-corroborated rows affected); thresholds are config (`conf/modules/mutation_report.config`).
  The matrix now also folds TIDDIT's `DUP:INV` (like `DUP:TANDEM`) into `DUP`.
- SVDB SV merge chain: Manta `convertInversion` →
  breakend-pair collapse (both callers) → `svdb --merge` across samples (TIDDIT; and Manta when not
  joint) → `svdb --merge --priority manta,tiddit` across callers, in `union` and `union_pass`
  (input-pre-filtered) views. Cohort VCFs publish at the canonical
  `data/sv_cohort_merged_{union,union_pass}.vcf.gz` names; intermediates under
  `data/sv_merge_inputs/`. Recipe validated in `docs/benchmarking/ottilie_xenobiotic_ale/04_validate/sv_merge_bench/`.
  New local modules `COLLAPSE_SV_PAIRS` and `CHECK_SV_SAMPLE_ORDER` (sample-column guard for
  `--same_order`); nf-core `manta/convertinversion` installed; `svdb/merge` updated (2.8.2 → 2.8.4,
  versions now emitted via topic channels only).
- **`--joint_manta`** — Manta germline calling in joint (multi-sample) mode: one run per patient
  (= ALE `experiment`) over all of its samples, so every sample is genotyped at every candidate SV
  instead of an event with weak evidence being absent from that sample's VCF. Default `false`
  (per-sample runs, unchanged output). Output: `variant_calling/manta/{patient}/{patient}.manta.diploid_sv.vcf.gz`.
  Written in the shape of upstream `--joint_mutect2` (grouping inside the subworkflow, `manta.config`
  untouched) so it can be offered to nf-core/sarek.
- **`--manta_high_sensitivity`** (default `false`) — one switch that turns off Manta's two human-WGS
  repeat heuristics: the depth filters (`--exome`, Manta's only handle for them; not a data-type
  change, `--wes` stays false) and the breakend-hub edge cap (`graphNodeMaxEdgeCount = 0` via
  `assets/manta_high_sensitivity.ini`, passed through the module's `config` input). Applies to every
  Manta run, per-sample or joint. Off, Manta behaves exactly as before. On the 4-sample pilot (joint
  mode) it reports 58 records instead of 31: the engineered-cassette junctions, a shared 343-bp
  delta-LTR insertion and 16 former `MaxDepth` records become PASS; no truth-set change either way.
- **Per-sample split of the joint Manta VCF** (ALE-only, on by default in the ottilie profiles):
  `SPLIT_JOINT_VCF` now also handles Manta — each sample gets back
  `variant_calling/manta/{sample}/{sample}.manta.diploid_sv.vcf.gz` so annotation, IGV reports and
  the SV merge are unchanged, with hom-ref/missing rows dropped (`--min-ac 1:nref`, ploidy-agnostic)
  and Manta's per-sample `FORMAT/FT` promoted to `FILTER` (`MinGQ`), so a weak genotype is not read
  as PASS because the cohort-level record is. Split rules for all callers now live in
  `conf/modules/split_joint_vcf.config`, keyed on `meta.variantcaller`.

### Changed

- **The testing documents have one entry point** (docs only, 2026-10-20; issue #14).
  `docs/dev-practices/testing_and_coverage_overview.md` opens with a *Documents* section (the five
  testing documents in reading order, one line each on what the document answers) and a *Results so
  far* table (the three coverage measurements of 2026-10-13, 2026-10-16 and 2026-10-19 by commit, each
  row linked to its section of `nextflow_code_coverage.md`). In `testing_best_practices.md`, §1–§9 are
  marked as the pre-1.0.0 plan kept for the record and §10–§14 as the rules in force; no heading,
  anchor or section moved. The docs index marks the overview as the place to start.
- **The testing overview reads for a team outside this repository** (docs only, 2026-10-20):
  `testing_and_coverage_overview.md` gains a context paragraph (what the fork is, what "fork code" and
  the other terms mean), the sarek 3.5.1 comparison beside the *Results so far* table, a *Running it*
  block that works from a clean clone (environment, test-data download), and a last section on what of
  the method transfers to another Nextflow pipeline and what is specific to this one.
- **Coverage report: branch coverage is the headline measure; *Conditions seen every way* renamed
  *Fully covered decision lines*** (dev tooling, 2026-10-13; `tests/nf_coverage_report.py`,
  `tests/nf_coverage.sh`, `docs/dev-practices/nextflow_code_coverage.md`). A probe of how JaCoCo counts
  Groovy bytecode (`docs/dev-practices/nextflow_branch_counting.md`, sources and per-line data in
  `nextflow_branch_counting/`) showed two branches per conditional jump: `if (a && b)` is six where
  Java gives four, `if (!a)` four, `x?.y` none, and a `branch` operator's `name: true` default adds
  one branch no run can take (4 of the fork's 920). The numbers are unchanged and are not adjusted;
  the table titles, legends and the doc say what is counted, the doc now reports branch coverage
  (162 / 197 / 384 / 514 of 920 for plan-only, `--qc_only`, e2e, merged; the 2026-10-02 data) next to
  the per-line worklist (80 / 254), and `RUN_INFO.txt` records the Groovy and Java versions from the
  next run on, since the branch denominator moves with the compiler. "Condition" in these docs now
  means the `if` itself, not the measure. Same day: the report excludes the side of a jump on a
  compile-time constant that no run can take (the four `branch { name: true }` catch-alls of
  `mutation_report/main.nf`, lines 176, 304, 409, 470, found in the bytecode); on the 2026-10-02 data
  the merged headline reads 514 / 916 instead of 514 / 920 and the fully covered decision lines 83
  instead of 80 of 254. `tables.txt` lists the excluded branches and the raw totals;
  `--no-constant-filter` restores JaCoCo's raw counts. Measured again the same day on `99aef57`
  (11 runs, all exit 0, 1 952 s): branch coverage 514 / 916 (56.1 %) and fully covered decision lines
  83 / 254, identical to the filtered 2026-10-02 data; fork lines 1 012 / 1 117 after the two files
  that changed in between. The doc's numbers are now that run's.

- **Coverage tooling probed on Nextflow 26.10.0 (strict parser); the script now fails a run that recorded
  config classes only** (dev tooling, 2026-10-14; `tests/nf_coverage.sh`,
  `docs/dev-practices/nextflow_branch_counting/nf26/`, `docs/dev-practices/ale_sarek_upgrade_runbook.md`,
  `docs/dev-practices/nextflow_branch_counting.md`). A strict-syntax companion of the branch-counting probe,
  run on 26.10.0 / Groovy 4.0.33 with 25.10.4 as the control, gives identical per-line branch counts (0 of 7
  rows differ) but shows the method's blind spot: the strict parser names the script classes `Main` and
  `_nf_script_<hash>` instead of `Script_<hash>`, so the agent's `includes` filter records config classes
  only and the run still exits 0. `tests/nf_coverage.sh` now checks every run's data with `jacococli
  execinfo` and fails with the cause when no `Script_*` class is in it (tested on the plan-only run with a
  wrong filter, then restored). The four changes the migration needs (filter, class-to-file map, one `Main`
  per merged report, the `Boolean.TRUE; invokedynamic cast; ifeq` catch-all pattern) and the lint estimate
  (432 errors in 94 files of the pipeline tree, 67 in `main.nf`, 19 in `nextflow.config`) are in the
  upgrade runbook; evidence in `nf26/RESULTS.md`. No pipeline code changed.

- **Samplesheet: `status` and `sex` documented as optional, dropped from the examples** (2026-10-06; `docs/usage/input_samplesheet.md`, `README.md`, `docs/README.md`, `CLAUDE.md`). No code change: nf-schema already fills a missing column from `assets/schema_input.json` (`status` 0, `sex` NA), and a Tier-1 run reads neither, so a sheet without them is the recommended form and is easier to inspect. Verified by parsing a two-sample sheet without either column and building its DAG in preview, identical to the test sheet's. Only `--tools ascat` / `controlfreec` (Tier-2) still need `sex`; the `csv/` restart sheets carry the filled-in values.
- **Launch form: the iGenomes paragraph left the *Reference genome options* section** (2026-10-04).
  Upstream's section help text ("The pipeline config files come bundled with paths to the Illumina
  iGenomes reference index files. …") is now the last paragraph of the help text of the hidden
  `genome` parameter, the one field it is about; the section shows its description and the four
  custom-genome fields only. New overlay key `group_removals` (`conf/schema_overlay.yml`,
  `bin/apply_schema_overlay.py`), the group-level twin of `property_removals`, so the move is
  re-applied when the upstream schema is taken at a sarek upgrade. Schema text only; no parameter,
  default or visibility change (32 visible / 120 hidden). The Azure file-browser warning in the
  *Input/output options* and *Reference genome options* descriptions is now a paragraph of its own.
  The same key drops upstream's help text of *Input/output options* ("Specify input samplesheet,
  step and output folder."), which was printed under a description that already says it
  (2026-10-05); no section with a visible field carries a help text now.

- **Launch form: backticks removed from the line under each field** (2026-10-04). The form prints a
  field's description as plain text (Markdown is rendered in section descriptions only), so code
  spans showed their backticks on 18 of the 32 visible fields. New overlay switch
  `strip_description_backticks` (`conf/schema_overlay.yml`, `bin/apply_schema_overlay.py`) removes
  them from the description of every visible parameter; help texts, section descriptions and hidden
  parameters are unchanged. `docs/usage/params_template.yml` regenerated (it carries the same
  descriptions). Text only. On 2026-10-05 the long dash was taken out of the four form texts that
  carried it (the line under `filter_quality`, the help texts of `tools`, `qc_only` and
  `joint_manta`), and out of the README, the docs index and the `docs/usage/` pages, each sentence
  reworded with a full stop, colon, comma or brackets. `qc_only`: "Requires step = mapping; breseq
  is not run." moved from the line under the field to the help text, which is now four paragraphs
  (what it is for, run 1, run 2, conditions) instead of one; the line under the field now reads
  "Stop before alignment and write a MultiQC report of the reads: fastp (trimming and filtering)
  and FastQC before and after read preprocessing." `qc_only` is now the first
  field of *Main options*, above `tools`, and its own section *QC-first run* is gone (the schema
  group `qc_first_run` is removed; a QC-only run's parameter summary lists `qc_only` under *Main
  options*). The
  sections after it follow the run: *Read preprocessing*, *Alignment*, *Variant Calling*
  (`group_order`; until now *Variant Calling* came before the read-level sections).
  `docs/usage/params_template.yml` follows the form's order. *Read preprocessing* reads shorter:
  the section text went from 86 to 44 words and the lines under its 17 fields from 400 to 251, as
  "Step N · what it does. Default or empty meaning."; the fastp option names and the background a
  line carried are in that field's help text (five help texts gained a sentence). The *Alignment*
  section text went from 55 to 24 words; what `save_mapped` and `save_output_as_bam` do is now
  said in the lines under those two fields.

- **The Launchpad entry opens with `qc_only` ticked** (2026-10-05). A launch from the entry is a
  QC-first run 1 unless the box is unticked. The value sits in the entry's saved parameters
  (`qc_only: true` in `deploy/azure/seqera-sp/launchpad_params_ottilie_test_az.yml`, written by
  `14_register_pipeline.sh`, `ENTRY_QC_ONLY`), not in `nextflow.config` or the schema: the pipeline
  default, the command line, nf-test and every profile are unchanged. `15_launch_run.sh` sends the
  same parameters, so a scripted launch now stops after read QC unless `--set qc_only=false`;
  `--resume` sends `qc_only: false` unless told otherwise. New `14_register_pipeline.sh --update`
  puts the committed parameters into an existing entry in place (`PUT /pipelines/{id}`, same
  pipeline id; Platform records a new version of the entry), so a parameter change no longer needs a
  re-registration. Measured on the preview entry; `docs/usage/qc_first_run.md` → *On Seqera Platform*.
  Both scripts now default to the entry name `yAMP` (the entry was renamed from
  `yAMP-ottilie-test-az`).

- **`--report_gff3` must be named `.gff3` or `.gff`** (2026-10-04). The parameter had no file-name
  check, so a gzipped or otherwise unusable file was accepted at start-up and in the launch form. It
  now carries the pattern `^\S+\.gff3?$` (`conf/schema_overlay.yml`): the gene track is read as plain
  text by `PREPARE_GFF3` and by the reference preflight, so a `.gz` cannot work. A run given another
  name stops at parameter validation with "The gene annotation must be an uncompressed GFF3 file
  whose name ends in .gff3 or .gff"; the launch form's file browser offers only matching files
  (expected from how it treats `input`, not yet seen for this field). It also carries `exists: true`:
  a local or https path that is not there stops at validation, where it used to abort the DAG build
  with the unrelated "sample-sheet only contains tumor-samples" message. nf-schema does not check
  cloud paths.

- **An account-prefixed Azure path is named at start-up** (2026-10-04). The five visible path
  parameters carry an `allOf` subschema that fails `az://<account>.<container>/…`, the form the
  launch form's Browse button inserts. An account-prefixed `fasta`, `snpeff_cache` or `report_gff3`
  now stops at parameter validation with the parameter's name and "Azure paths read
  az://<container>/..., without the storage account name"; `input` and `outdir` still stop with the
  bare `Status code 400`, raised before validation reports. The launch form itself cannot flag the
  path: it checks only a field's `pattern`, which is also its file browser's filter
  (`docs/dev-practices/azure_batch_execution.md` §19 and §20).

- **`VARIANTFILTRATION_FALLBACK` runs on the same GATK image as the other GATK steps** (2026-10-01;
  `modules/nf-core/gatk4/variantfiltration`). The module — a later nf-core version than the rest of
  the 3.5.1 tree — pinned the Wave community image `gatk4_gcnvkernel` (GATK 4.6.2.0, a 2 GB layer no
  other step uses); it now uses `biocontainers/gatk4:4.5.0.0--py36hdfd78af_0`. A fresh node no longer
  pulls 2 GB for a 5-second step, and the run no longer depends on that registry: on 2026-10-01 the
  layer was served at 0.36 MB/s and two Seqera Platform runs waited about 90 minutes on it
  (`azure_batch_execution.md` §18). The soft-filtered VCF is record-identical (measured on the test
  set, 100 records, and the 4-sample pilot, 451 records; same `FILTER` tally); its
  `##GATKCommandLine` header line and the `VARIANTFILTRATION_FALLBACK` line of the software-versions
  manifest read 4.5.0.0 instead of 4.6.2.0.
- **The Workflow Summary is collapsed and back at the bottom** of the MultiQC report: its body opens
  on a click, and its ordering rule — keyed on the old `nf-core-sarek-summary` id, which stopped
  matching when `manifest.name` changed on 2026-07-27 and left the summary near the top — is re-keyed
  to the current `Aletechdev-ALE_Yeast-summary`.

- **MultiQC 1.25.1 → 1.35** (2026-09-24; the version sarek ≥ 3.10 ships). Container pin only —
  `modules/nf-core/multiqc/{main.nf,environment.yml}`; the module keeps its sarek-3.5.1 signature
  (`docs/dev-practices/SAREK_MODIFICATIONS.md` → `modules/nf-core/` PATCHED; to be dropped at the next
  rebase). `assets/multiqc_config.yml`: `report_comment` is now a yAMP sentence linking the user docs
  (1.35 validates the config and rejects upstream's `false`). Same sections in the same order, General
  Stats rows identical (+4 columns), the two FastQC passes and the `--title` file naming of the QC-only
  run unchanged, dashboard unchanged (all measured on the e2e task's staged inputs). What moves in
  `multiqc/` — the overrepresented-sequence tables dropped, picard histograms renamed by metric, new
  `llms-full.txt` / `multiqc.parquet` / `samtools_insert_size.txt`, a few plots renamed — is tabled in
  `docs/dev-practices/output_comparison.md` §2.10 (dated row); `multiqc.parquet` (non-deterministic) and
  `llms-full.txt` (embeds the Nextflow run name) join `tests/.nftignore`. e2e snapshot re-recorded: only
  `multiqc/` entries moved;
  no version line moves, because MultiQC's own version is not in the software-versions manifest
  (MultiQC consumes that file) — it is only in the excluded `multiqc_software_versions.txt`.

- **Launch form: sections reordered and the alignment group renamed** (2026-09-09; order refined
  2026-09-10 — Variant calling now directly after Main options, the read-level groups last): Input/output →
  Reference genome → Main options → Variant calling → Read preprocessing → **Alignment** (was sarek's "Preprocessing",
  a near-duplicate of "Read preprocessing"; the group covers bwa-mem alignment, duplicate marking and
  what to publish). `filter_quality`'s description now says the filter counts bases
  against `filter_quality_phred` and never uses the read's mean quality (that is step 3). Schema text
  and order only (`conf/schema_overlay.yml`); no behaviour change.

- **Reference preparation documented as two paths** — new user page `docs/usage/prepare_reference.md`:
  Path A GenBank → FASTA + GFF3 + SnpEff cache (`process_genbank_auto.sh`, verified on the S288C test
  GenBank; its GenBank → GFF3 step is documented as lossy — flat features, no phase, gene symbols dropped),
  Path B FASTA + GFF3 → cache with the new `docs/prepare_input/build_snpeff_cache.sh` (contig-name check,
  Ensembl ID-prefix clean-up, snpEff 5.1 pinned; rebuilds the project's S288C cache byte for byte). README launch
  example now passes `--report_gff3`. **Removed** `docs/prepare_input/process_GeneBank/generate_cache/
  gen_cache.sh` — hard-coded to a dev-VM path and a private genome, sarek-3.4-era layouts; every doc that
  named it as the cache generator now points at the two scripts above.

- **The per-sample HaplotypeCaller hard filter is no longer part of the ALE recipe.**
  `conf/test/ottilie_common.config`, `conf/params_ottilie_test_blob.yml`, the Launchpad box and the
  pilot/tier-2 launchers stop setting `hard_filter_haplotypecaller_joint`, so it follows the pipeline
  default (`false`, unchanged). The step only produced a third `sample_hard` VCF lineage that
  `MUTATION_REPORT` drops and no validation read, at a filter + SnpEff + bcftools/vcftools stats task
  per sample. Outputs: the `hard_filtered.*` family disappears (`variant_calling_filtered/`, its `tabix/`
  indexes and their annotation/report siblings; 16 fewer tasks on the 2-sample test); the joint VCF, the soft
  per-sample splits and all nine cohort deliverables are byte-identical. Opt back in with
  `--hard_filter_haplotypecaller_joint`. Expected difference against pre-2026-09-08 outputs
  (`docs/dev-practices/output_comparison.md` §2.10).

- **`custom_config_base` has no schema default any more** (`nextflow.config` was already `null`; the
  overlay's `property_removals` now drops upstream's `https://raw.githubusercontent.com/nf-core/configs/master`
  from the schema too). The Seqera launch form injected that URL over the config value
  (`azure_batch_execution.md` §13), so a Platform run loaded nf-core's institutional configs from GitHub
  at runtime while a local run did not. Local behaviour unchanged; every schema default now matches
  its `nextflow.config` default. Setting the URL explicitly still works.

- **`snpeff_cache` has no default any more** (`nextflow.config` → `null`; the schema `default` is deleted
  by the overlay's new `property_removals`). Upstream's `s3://annotation-cache/snpeff_cache/` holds no
  custom genome, and the Seqera launch form injected that schema default over profile values, killing
  profile-only launches (`docs/dev-practices/azure_batch_execution.md` §13). A run with `snpeff` in
  `--tools` and neither `--snpeff_cache` nor `--download_cache` now fails at launch with
  `Please specify --snpeff_cache …` (guard in `samplesheet_to_channel`, new `download_cache` input)
  instead of in `SNPEFF_SNPEFF` hours later. Passing the annotation-cache URL explicitly is unchanged.

- **`trim_nextseq` documented correctly.** Its description claimed Trim Galore's `--nextseq=X`
  quality-cutoff semantics; fastp's flag takes no value and only its non-zero-ness is used. At 0
  nothing is passed and fastp's read-name poly-G auto-detection applies, unchanged from upstream.
  `--trim_adapter` (= upstream's `--trim_fastq`) behaves as in upstream sarek 3.5.1 (adapter trimming
  plus fastp's read-level quality filter); the filter is now documented and switchable via
  `filter_quality` (default true), and its thresholds are passed explicitly.

- **`joint_manta` now defaults to `true`** (was `false`): joint multi-sample Manta is the validated
  Tier-1 recipe — the local test/pilot configs already ran it, while a Seqera launch inherited the
  old `false` default (the Launchpad preset never set it), so the two execution paths silently ran
  different Manta modes. Local ottilie runs are unchanged (their profiles pinned `true` already);
  set `--joint_manta false` for per-sample Manta on large cohorts (joint mode is one task per
  experiment whose cost grows with every sample; validated at 4).

- **Seqera launch form trimmed to the Tier-1 surface** (Tier-1 UX review, 2026-09-01): the schema
  now marks all but 26 parameters `hidden` (Seqera's "Show hidden params" toggle and `--help_full`
  still reach them; behavior, defaults and validation are unchanged). Visibility is generated from a
  new allowlist overlay — `conf/schema_overlay.yml` applied by `bin/apply_schema_overlay.py`
  (`--check` guards drift; parameters added by a future sarek upgrade are born hidden). The `tools`
  and `joint_manta` help texts are rewritten for the ALE germline-only reality. The ottilie
  profiles, blob params file and pilot/tier2 launchers stop passing `chr_dir` (Control-FREEC-only)
  and `genbank` (breseq-only) — both staged-but-unused on Tier-1 runs; the params remain available,
  hidden. Resolved-config proof: only those two values change, `-preview` DAG unaffected.

- **SURVIVOR retired**: `SURVIVOR_SV_MERGE`, `SURVIVOR_COHORT_MERGE` and the per-sample
  `data/sv_merged/<sample>/` outputs are gone. `data/sv_cohort_merged_{union,union_pass}.vcf.gz`
  keep their names but are now the SVDB cross-caller merges (provenance in `INFO/set`, `FOUNDBY`,
  `manta_*`/`tiddit_*` keys). The SV cohort matrix is a deterministic parse of those VCFs —
  `proximity_match` and its 1 kb gate are gone; rows carry Manta's split-read coordinates, one row
  per breakend junction, typed `<INV>` rows.
- Matrix/CN cohort CSVs now end lines with LF (were CRLF via the csv module default).
- Shared SV events no longer read as clone-specific in the Manta outputs of a multi-sample
  experiment: with joint calling every sample carries a genotype at every candidate (in the
  2-sample test set, `I:206105 DEL` and `VII:530034 INS` become shared PASS calls; breakpoints are
  estimated once from pooled reads, so coordinates shift slightly vs per-sample runs).

### Removed

- **Tier-2 AF post-filters for FreeBayes and Mutect2** (2026-09-09): `subworkflows/local/vcf_filter_freebayes`
  and `vcf_filter_mutect2`, `conf/modules/custom_{freebayes,mutect2}_filter.config`, the never-wired
  `filter_freebayes` / `freebayes_{qual,dp,af}_threshold` / `freebayes_high_impact` params (config + schema),
  and the `TABIX_TABIX` index step in `workflows/sarek/main.nf` that existed only to feed them (its
  `tabix/*.tbi` publishes for HC/Manta/TIDDIT VCFs go with it; the CNVKit `tabix/` files remain). The
  upstream callers are untouched. Also removed: `conf/params_seqera_test.yml`, the CEN.PK Launchpad
  preset superseded by the generated box. Everything is at git tag `tier2-tools-archive`; index and
  retrieval commands in `docs/archive/tier2/README.md`.
- **Control-FREEC germline mode** (2026-09-09): `subworkflows/local/bam_variant_calling_germline_controlfreec`
  and its wiring in `bam_variant_calling_germline_all` (the `controlfreec` branch of the mpileup condition,
  the `chr_files`/`mappability` takes) removed; `conf/modules/controlfreec.config`,
  `modules/nf-core/controlfreec/freec/main.nf` and the somatic/tumor-only Control-FREEC subworkflows
  reverted to pristine sarek 3.5.1 (patched nf-core modules 3 → 2). `--tools controlfreec` behaves as in
  upstream (somatic/tumor-only, `cf_ploidy`); it never runs on an all-germline ALE samplesheet. CNVKit
  remains the CNV deliverable. Same archive tag and index.

### Fixed

- **The joint-calling subworkflow could not emit the raw joint VCF** (found 2026-10-16 by
  `tests/joint_calling_output_selection.nf.test`, fixed 2026-10-19). The fallback join at
  `subworkflows/local/bam_joint_calling_germline_gatk/main.nf:145` (and `:154` for the index) had no
  `remainder: true`, so without a fallback VCF `genotype_vcf` was empty rather than the third tier of
  `recal_vcf ?: fallback_vcf ?: joint_vcf`. No run was affected (the fallback step is unconditional, so
  the join always matched); the ALE route and the VQSR route are byte-for-byte what they were. Both joins
  now carry `remainder: true`; the test's "neither" case asserts the raw joint VCF. The first version of
  the fix broke the `--qc_only` starvation gate, caught by `tests/qc_gate.sh a` in two minutes: the
  `ifEmpty([[:], []])` placeholder on the VQSR channel exists even when joint calling never ran, and with
  both remainders it left the joins as a `[meta, null]` row that crashed on `vcf.baseName` in
  `workflows/sarek/main.nf`. The missing remainder had been the starvation guard by accident. A
  `filter` on the merged VCF is the guard now, on both the VCF and the index channel, and a fourth test
  case (no input, no task, nothing emitted) pins it; it fails with the filter removed (checked).
- **The chromosome copy-number CSV button in the mutation report index was dead in every bundle**
  (found 2026-09-30, fixed 2026-10-01). `BUILD_CN_MATRIX` writes a `cn_matrices/` directory and was
  published into `data/cn_matrices/`, so its five tables landed under
  `mutation_reports/data/cn_matrices/cn_matrices/` while the index linked
  `data/cn_chr_summary_germline.csv`. The directory is now published into `data/` — the tables are at
  `mutation_reports/data/cn_matrices/<file>` — and the index links the chromosome summary there.
  (It cannot be a Seqera Outputs-tab entry of its own: a file that leaves its task inside a published
  directory raises no publish event, measured on run `4REMpK9OCBKY4z`; the `tower.yml` entry added
  with this fix was removed the same day.) **Five output paths move** (content unchanged): scripts reading
  `data/cn_matrices/cn_matrices/…` from older outputs need the shorter path for new ones
  (`output_comparison.md` §2.10).

- **`--tools` without an annotator aborted at DAG build** (2026-09-09 → 2026-09-23). The
  mutation-report input's no-annotation branch still named `vcf_with_tbi`, the indexed-VCF channel
  removed with the Tier-2 AF filters, so any tools set without `snpeff`/`vep`/`merge`/`bcfann` —
  e.g. a calling-only run before a SnpEff cache exists — died with a `MissingPropertyException`
  behind the misdirected "sample-sheet only contains tumor-samples" message. The branch now indexes
  the raw caller VCFs itself (`TABIX_REPORT_VCFS`, unpublished — the report bundles VCF + index) and
  hands the report the same `[meta, vcf, tbi]` tuples the annotators emit. The first real
  calling-only run then exposed two more defects of the same path, fixed together: the dashboard's
  index generator hard-required MultiQC's SnpEff table (`multiqc_snpeff.txt`) for an impact pivot
  that was never rendered — loader and pivot removed, footer no longer names SnpEff as a data
  source; and `PUBLISH_VCFS` derived sample names by stripping only the
  annotated suffix (`_snpEff.ann.vcf.gz`), so raw inputs were published as
  `<sample>.cnvcall.vcf.gz_cnvkit.vcf.gz` (now both name forms map to the same `<sample>_<caller>`
  names; the `_annotated` in the HaplotypeCaller names is kept so the dashboard's links do not
  change). Annotated runs are untouched (e2e snapshot unchanged). Preview test
  `tests/tools_without_annotation.nf.test`; the whole path verified once end-to-end on the ottilie
  set with `--tools cnvkit,tiddit,manta,haplotypecaller --generate_reports`.

- **Joint Manta output was not deterministic.** The grouped CRAM list came out of `groupTuple()` in
  channel-arrival order, and Manta derives its record IDs (and the joint VCF's sample-column order)
  from `--bam` order, so IDs, `MATEID`s and column order could differ between identical runs — visible
  downstream as changing IGV-report hashes. The CRAMs are now sorted by name before the joint call.

### Known limitations

- **Manta at its default settings (the ALE default) drops high-depth junctions and hub-adjacent
  events.** On the 4-sample pilot the joint run loses the `MaxDepth`-tagged engineered-cassette
  breakends (Manta's pooled-depth discovery skip) and a shared 343-bp delta-LTR insertion (the
  breakend-hub edge cap); per-sample calling has the same blind spot in the parent strain. Decided
  2026-08-28 to keep Manta's defaults — joint calling's noise reduction is wanted, and at the PASS
  level only one shared background insertion, one cassette junction and two 8-pair breakends are
  affected — and to expose the alternative as `--manta_high_sensitivity`. Audit, per-record effect
  and how to re-run it: `docs/benchmarking/ottilie_xenobiotic_ale/04_validate/pilot_results_v2/NOTES.md`,
  `04_validate/run_manta_joint_audit_pilot.sh <MODE>`.

- **Seqera Platform's file browser inserts Azure paths that Nextflow cannot read** (2026-10-01, run
  `5syUy3CSjd3kyO`). The launch form's Browse button writes `az://<account>.<container>/…`; Nextflow
  reads `az://<container>/…` only, and the run stops at start-up with `Status code 400,
  InvalidResourceName`. Delete `<account>.` after picking a path. Upstream:
  [nextflow#4683](https://github.com/nextflow-io/nextflow/issues/4683), open. The launch form now warns
  about it in the *Input/output options* and *Reference genome options* section descriptions and under
  `input` (`conf/schema_overlay.yml`). It cannot flag the path itself (§20); since 2026-10-04
  start-up validation names it for the three reference parameters. Detail:
  `docs/dev-practices/azure_batch_execution.md` §19.

## v1.0.0 — first production release (on nf-core/sarek 3.5.1)

Yeast ALE (Adaptive Laboratory Evolution) variant-calling pipeline: HaplotypeCaller joint germline
calling with variable ploidy, structural/copy-number calling, custom SnpEff annotation, and an
integrated multi-caller mutation-report dashboard. Full change inventory vs. upstream sarek:
[`docs/dev-practices/SAREK_MODIFICATIONS.md`](docs/dev-practices/SAREK_MODIFICATIONS.md).

### Tool support tiers

- **Tier 1 (tested — exercised by the ALE contract test):** HaplotypeCaller (joint + split +
  hard-filter), CNVKit, Manta, TIDDIT, SnpEff.
- **Tier 2 (functional, not release-tested):** Control-FREEC, breseq, and the FreeBayes/Mutect2
  AF-filter subworkflows (retained for dev/troubleshooting; not on the Tier-1 path).

### Added

- **MUTATION_REPORT dashboard** — per-sample + cohort igv-reports, CN cohort matrices (CNVKit),
  SV cohort matrices (SURVIVOR merge of Manta+TIDDIT), and an index.html linking MultiQC.
  Opt-in via `--generate_reports`.
- **ALE end-to-end nf-test** (`tests/ottilie_e2e.nf.test`) — pipeline-level contract test on the
  2-sample ottilie dataset; asserts the 4 cohort CSVs byte-for-byte + output structure + versions.
  Determinism proven across runs. Kept separate from the upstream sarek suite.
- **Split + hard-filter of joint HC VCFs** (`--split_haplotypecaller_joint_vcf`,
  `--hard_filter_haplotypecaller_joint`); `VARIANTFILTRATION_FALLBACK` when VQSR can't run.
- Variable-ploidy support threaded to HaplotypeCaller, CNVKit, Control-FREEC, FreeBayes, TIDDIT.
- Portable test-data provenance + samplesheet generation; container images pinned for cloud.

### Changed

- **MUTATION_REPORT is now channel-based and runs inline** in `workflows/sarek/main.nf` — consumes
  live pipeline output channels instead of re-reading `params.outdir`.
- BUILD_SV_COHORT split into single-container processes for cloud portability.
- Dead code / stale artifacts removed for release.

### Fixed

- **`--generate_reports` failed on a clean run** — the report raced `publishDir` reading published
  files from `params.outdir`. Now correct-by-construction on a fresh outdir (cloud/Seqera). (`bb1439f`)
- Per-sample SV/CNV reports were dropped by a one-to-one channel `join`; fixed with `combine(by:0)`.
- FilterMutectCalls now runs without a germline resource / panel-of-normals (placeholder channels).

### Known limitations

- **Nextflow:** run on **25.10.x** (manifest range `!>=24.04.2, <26.0.0`; launch scripts pin
  `NXF_VER=25.10.4`). **26.04+ fails to parse `nextflow.config`** (strict config DSL — starting with
  `def trace_timestamp` mixed with config statements) — a 26.x move is an nf-core template migration
  deferred to a post-1.0 sarek-4.x rebase. Full blocker inventory + Seqera notes in
  `docs/dev-practices/ale_sarek_upgrade_runbook.md`.
- **CNVKit CN scale:** `cn` is always diploid-baseline regardless of `--ploidy`; use `log2`/depth
  ratio (`fold_change`) for true signal on haploid/polyploid strains. See `docs/variant-calling/cnvkit/`.
- **VCFtools** conditionally skipped for ploidy>2, Mutect2 phased GT, and joint-calling VCFs.
- **Custom genomes:** no dbSNP / known-sites → BQSR and VQSR disabled (hard-filter fallback);
  Mutect2 runs without germline-resource / panel-of-normals; Control-FREEC has no BAF.

### Testing

- ALE contract test (nf-test) gates the deliverables; Tier-2 biological validation against the
  ottilie truth set (4 SNVs + chr I duplication, Ottilie et al. 2022) validates call correctness.

## v0.1.0-alpha:

Adapted from nf-core sarek 3-5-1, the main feature is HaplotypeCaller joint variant calling
