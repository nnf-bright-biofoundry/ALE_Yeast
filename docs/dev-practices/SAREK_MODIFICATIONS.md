# ALE Modifications vs. nf-core/sarek 3.5.1

**Purpose:** the authoritative inventory of every change the ALE fork makes on top of pristine
nf-core/sarek 3.5.1. This is the primary reference for a future sarek rebase (see
[`ale_sarek_upgrade_runbook.md`](ale_sarek_upgrade_runbook.md)) and for onboarding.

**Guiding principle** (from the runbook): keep modifications *additive* and *isolated*. New files
(local subworkflows/modules, configs) don't conflict on rebase. In-place edits to upstream files —
especially the 4 patched `modules/nf-core/` modules and `workflows/sarek/main.nf` — are the real
rebase cost; each is called out below.

## How to regenerate this diff

```bash
# Pristine 3.5.1: /tmp is ephemeral, so re-download when missing (verified gone 2026-09-01):
#   nf-core pipelines download sarek --revision 3.5.1 -o /tmp/sarek_upstream_351  (nf-env conda)
# or fetch single files from the tag: https://raw.githubusercontent.com/nf-core/sarek/3.5.1/<path>
U=/tmp/sarek_upstream_351/3_5_1
diff -qr subworkflows/local "$U/subworkflows/local"
diff -qr modules/local      "$U/modules/local"
diff -qr modules/nf-core    "$U/modules/nf-core" | grep -v '/tests\|environment.yml\|meta.yml'
diff -qr conf               "$U/conf"
for f in main.nf nextflow.config nextflow_schema.json workflows/sarek/main.nf; do diff -q "$f" "$U/$f"; done
```

## Summary

| Category | Added | Modified (in-place — rebase cost) |
|----------|-------|-----------------------------------|
| Root files | — | `main.nf`, `nextflow.config`, `nextflow_schema.json` |
| Core workflow | — | `workflows/sarek/main.nf` ⚠️ heaviest |
| `subworkflows/local/` | 5 | 9 |
| `modules/local/` | 21 | 0 |
| `modules/nf-core/` | 5 (installed) | **4 patched** ⚠️ |
| `conf/` | 19 | 7 |

---

## Root files (modified in place)

- **`workflows/sarek/main.nf`** ⚠️ — the largest edit surface. ALE additions: custom VCF filtering
  channels (FreeBayes/Mutect2 AF filters via `TABIX_TABIX` + `vcf_with_tbi`), and the **inline
  MUTATION_REPORT** call at the end of the MultiQC block with the `ch_report_vcfs` annotated-or-raw
  fallback (commit `bb1439f`). Record the report's channel contract here on every rebase. Also the
  **FASTP gate** (`trim_adapter || trim_fastq || trim_quality_3prime || trim_quality_5prime || split_fastq > 0`)
  plus the `trim_fastq` deprecation warning — two lines added 2026-09-02. **Post-trim FastQC**
  (2026-09-23): a 5-line `FASTQC_TRIMMED_QC(FASTP.out.reads, params.split_fastq > 0)` call inside the
  fastp block, gated by the same `fastqc` skip token as upstream's raw `FASTQC`; its zips join `reports`.
  **Mutation-report input** (`ch_report_vcfs`): annotated VCFs when an annotator runs, else the raw
  `vcf_to_annotate` VCFs indexed in place by `TABIX_TABIX as TABIX_REPORT_VCFS` (2026-09-23; the
  branch had referenced the `vcf_with_tbi` channel removed with the Tier-2 filters and aborted at DAG
  build). Config block in `conf/modules/mutation_report.config` (unpublished). Same fix made
  `modules/local/publish_vcfs` accept raw caller file names and `docs/igvreports/generate_index.py`
  drop its never-rendered SnpEff impact loader.
  **The `--qc_only` gate** (2026-09-24, `docs/usage/qc_first_run.md`): right after the fastp block and
  before breseq, `if (params.qc_only) reads_for_alignment = Channel.empty()` (+ a `log.info`), and
  `!params.qc_only` added to the breseq condition (breseq reads the fastp output directly, so starving
  alignment does not starve it). **The gate works by starvation**: nothing downstream is wrapped, the
  DAG is identical to a full run, and the follow-up `-resume` is exact. It holds only while no process
  downstream of alignment can fire on EMPTY input — a `toList()`, an `ifEmpty(...)`, a `Channel.value`
  / `Channel.of`, or a plain-file input as a process's *only* inputs would make that process run in a
  QC-only run, silently. Reference preparation, `PREPARE_GFF3` and `PREFLIGHT_REFERENCE` do exactly that
  and are on the allow-list on purpose. A `remainder: true` join is another way in (*measured* 2026-10-19:
  `bam_joint_calling_germline_gatk` emitted a `[meta, null]` row from its `ifEmpty` placeholder once both
  output joins had a remainder, and the run died on `vcf.baseName`; a `filter` on the merged VCF guards it). **After any change or rebase that adds such an operator downstream of
  alignment, run `tests/qc_gate.sh a`** (minutes; the commit gate demands its trailer for `workflows/`
  and `subworkflows/` changes) — either gate the new process on `params.qc_only` or, if it is harmless
  reference prep, add it to `ALLOW` in the script. Side finding recorded here, not fixed: the breseq
  input test checks the deprecated `trim_fastq`, so with today's defaults (`trim_adapter`) breseq
  receives the **untrimmed** reads despite its comment (`reads_for_breseq`); breseq is held pending the
  AMP-v1 merger decision.
  **Task-level reference preflight** (2026-09-28, `docs/usage/preflight_checks.md`): right after the
  channel initialisation, `PREFLIGHT_REFERENCE(fasta.map{ meta, f -> f }, report_gff3-or-[])`,
  unconditional (every `--step`; in a QC-only run too — on the allow-list), its `mqc` table mixed into
  `reports`, its versions into `versions`. Nothing else consumes it, so no other task hash moved when it
  was added. Module `modules/local/preflight_reference` runs `bin/preflight_reference.sh`; its config
  block `conf/modules/preflight.config` sets `errorStrategy 'terminate'` and `debug`.
  **Three MultiQC reports + input-checks table** (2026-09-29, `docs/usage/qc_first_run.md` → *The three
  MultiQC reports*): a new `take:` input `preflight_mqc` (the DAG-build checks' table, from
  `PIPELINE_INITIALISATION`) is mixed into `reports` first, so it joins `PREFLIGHT_REFERENCE`'s rows in
  one table. `reports` is tapped twice — `reports_read_qc` right before the `--qc_only` gate,
  `reports_alignment_qc` at the end of the `mapping`/`markduplicates` block — and the MultiQC block calls
  `MULTIQC as MULTIQC_READ_QC`, `MULTIQC as MULTIQC_ALIGNMENT_QC` and upstream's `MULTIQC`, all three
  with the workflow summary + methods text (`ch_multiqc_common`); only the complete one gets the
  versions YAML (a `collectFile` over every process — it would hold the early reports back to the
  end). A report whose stage does not run is **starved** (ternary on its first input), never wrapped:
  the early two at the wrong `--step`, and alignment-QC + complete under `--qc_only` — their inputs hold
  the read-QC files, so the gate's own starvation misses them; `qc_gate.sh a` pins it
  (`MULTIQC_READ_QC` is on the allow-list, the other two must not run). `MUTATION_REPORT` now gets
  `MULTIQC.out.report.toList()` directly; `multiqc_report` (the completion e-mail's) is the read-QC
  report under `--qc_only`. The Workflow Summary goes through `collapsedSummaryMultiqc()`.
- **`assets/multiqc_config.yml`** — `module_order` has two `fastqc` entries with distinct `anchor`s
  (`fastqc_raw` with `path_filters_exclude`, `fastqc_trimmed` with `path_filters` on
  `*_trimmed*_fastqc.zip`) around fastp, and `extra_fn_clean_exts` strips `_trimmed` (2026-09-23;
  replaces the trim_galore-era `*_val_*.zip` exclude). Behaviour measured on MultiQC 1.25.1 and
  re-measured, identical, on 1.35 (2026-09-24 — the pinned version, see `modules/nf-core/` PATCHED):
  section ids and the `fastqc_after_preprocessing-` General Stats prefix are asserted by the e2e test.
  Re-measure at every MultiQC bump. `report_comment` is a yAMP sentence (2026-09-24): 1.35 validates
  the file against a config schema and upstream's `false` fails it (warning only).
  `report_section_order` keys the Workflow Summary as `nnf-bright-biofoundry-ALE_Yeast-summary` (keyed
  2026-09-29, re-keyed 2026-10-23 with the repo transfer): the section id is
  `<manifest.name with / → ->-summary`, so upstream's `nf-core-sarek-summary` stopped matching when
  `manifest.name` changed (2026-07-27) and the summary rendered second instead of last. Re-key it (and the
  `summary_id` in `tests/ottilie_e2e.nf.test`) whenever `manifest.name` changes.
- **`main.nf`** — removed the old outer MUTATION_REPORT path-discovery call (superseded by the inline
  call); `NFCORE_SAREK` takes a second input, `preflight_mqc`, passed on to `SAREK` as its last
  argument (2026-09-29, the input-checks table); otherwise close to upstream.
- **`nextflow.config`** — ALE params (report_* / generate_reports / split & hard-filter HC / read
  preprocessing `trim_adapter`, `trim_quality_*`, `filter_quality*`, `adapter_sequence*`), extra
  `includeConfig`s, ALE profiles. **`snpeff_cache` default `null`** (2026-09-07; upstream
  `s3://annotation-cache/snpeff_cache/` dropped from config AND schema — the launch form injected it over
  profiles, `azure_batch_execution.md` §13; explicit use of that URL still works). **`custom_config_base`
  default `null`** likewise (config since the nf-core download days; schema default dropped 2026-09-08 so
  a Platform launch no longer pulls nf-core's institutional configs from GitHub while a local run does not).
- **`nextflow_schema.json`** — schema entries for the new params. ⚠️ **GENERATED since 2026-09:**
  upstream schema + [`conf/schema_overlay.yml`](../../conf/schema_overlay.yml) (visible-param
  allowlist for the Seqera launch form + ALE-owned help texts), applied by
  [`bin/apply_schema_overlay.py`](../../bin/apply_schema_overlay.py). Never hand-edit `hidden`
  flags or overridden texts in the JSON — edit the overlay and re-run the script
  (`--check` verifies the committed schema matches). On a sarek upgrade: take the upstream
  schema wholesale, re-run the script, review the diff. The user-facing
  [`docs/usage/params_template.yml`](../usage/params_template.yml) is generated from the result by
  [`bin/make_params_template.py`](../../bin/make_params_template.py) (also `--check`) — re-run it
  whenever the visible set, a visible parameter's description or `conf/test/ottilie_common.config`
  changes.
  **The overlay also carries validation rules since 2026-10-04**, so it changes start-up behaviour
  and not only the form: (1) `report_gff3` gains `pattern: ^\S+\.gff3?$` with an `errorMessage`,
  and `exists: true`; (2) the five visible path parameters (`input`, `outdir`, `fasta`,
  `snpeff_cache`, `report_gff3`) gain one `allOf` subschema, `^(?!az://[^/]*\.)`, that fails an
  account-prefixed Azure path. Upstream's own `pattern` on those fields is left untouched: the
  launch form uses a field's `pattern` as its file browser's filter, which is why the Azure rule
  sits in `allOf` ([`azure_batch_execution.md` §19–§20](azure_batch_execution.md#19-a-path-picked-in-platforms-file-browser-stops-the-run-at-start-up-2026-10-01)).
  Two overlay keys were added with them: `group_removals` (keys deleted from a section's entry;
  drops upstream's section `help_text` of *Reference genome options* and *Input/output options*,
  which the form prints on screen) and `strip_description_backticks` (the form prints the line
  under a field as plain text). At a sarek upgrade: if upstream adds a `pattern`, `exists` or
  `allOf` to one of these fields, the overlay's value replaces it key by key, so compare the two
  before re-running the script.

### New params (nextflow.config / schema)

`qc_only` (2026-09-24; first field of upstream's `main_options` group since 2026-10-05, until then in a fork-owned group `qc_first_run`), `joint_manta` (upstream-shaped, PR candidate), `manta_high_sensitivity`, `generate_reports`, `split_haplotypecaller_joint_vcf`, `hard_filter_haplotypecaller_joint`,
`report_gff3`, `report_filter_config`, `report_cohort_template`, `report_sample_template`,
`report_index_script`, `report_templates_dir`, `report_outdir`, `report_multiqc_path`,
`seqera_workspace_url` (2026-10-01; hidden, schema group `generic_options` — the report index's link to its Seqera run);
the ten `report_qc_*` thresholds of the report index's Samples-table QC grading (2026-10-06; hidden, `generic_options`:
`report_qc_{cov,breadth,map,dup}_{pass,fail}`, `report_qc_cohort_cov_frac`, `report_qc_min_dp`; read by `modules/local/generate_index`
and handed to `generate_index.py` as `qc_thresholds.json`);
read preprocessing (2026-09-02): `trim_adapter` (upstream `trim_fastq` kept as deprecated alias),
`adapter_sequence`, `adapter_sequence_r2`, `trim_quality_3prime`, `trim_quality_5prime`, `trim_quality_mean`,
`trim_quality_window`, `filter_quality`, `filter_quality_phred`, `filter_quality_percent`.

---

## `subworkflows/local/` — ADDED (5, additive — low rebase cost)

| Subworkflow | Purpose |
|-------------|---------|
| `mutation_report` | Multi-caller dashboard (CN/SV matrices + igv-reports + index). Channel-based. |
| `split_joint_vcf` | Split joint germline VCF → per-sample VCFs (channel-based metadata). |
| `vcf_filter_haplotypecaller_joint` | Hard-filter per-sample VCFs from joint calling. Opt-in (`--hard_filter_haplotypecaller_joint`); off in every ALE recipe since 2026-09-08. |
| `fastq_variant_calling_breseq` | breseq path (AMP-v1 legacy integration, not Tier 1). |
| `fastqc_trimmed` | `FASTQC_TRIMMED_QC` (2026-09-23): FastQC on the fastp output (`CAT_FASTQ` per mate first when `split_fastq > 0`), report-only, mixed into MultiQC as a second FastQC section (`assets/multiqc_config.yml`: two `fastqc` anchors + `_trimmed` clean rule). Called from `workflows/sarek/main.nf` inside the fastp block under the `fastqc` skip token. Unit test `tests/fastqc_trimmed.nf.test`. |

## `subworkflows/local/` — MODIFIED (9, in place)

| Subworkflow | ALE change (why) |
|-------------|------------------|
| `bam_variant_calling_germline_all` | ⚠️ Core ALE wiring: CNVKit `.cnr/.cns` emits + 4 `hc_kind` lineage tags; FreeBayes somatic disabled; split/hard-filter HC; split of the joint Manta VCF (`SPLIT_JOINT_VCF_MANTA`, ALE-only — not part of the `joint_manta` PR candidate). |
| `bam_variant_calling_germline_manta` | `joint_manta` input + one `groupTuple` branch (per-patient multi-sample run); `manta_config` input (optional configManta.py ini → module `config`, `[]` otherwise); `tbi` emit (3.8.1 shape). Deliberately mirrors upstream `joint_mutect2`; new lines in 3.10 strict-syntax dialect, no versions plumbing → pastes onto sarek `dev` unchanged. **Upstream PR candidate** — keep free of ALE-specific logic. |
| `bam_variant_calling_cnvkit` | Ploidy passthrough; emit `cnr`/`cns_batch` for the report. |
| `bam_joint_calling_germline_gatk` | `VARIANTFILTRATION_FALLBACK` when VQSR can't run (custom genomes, no known-sites). |
| `samplesheet_to_channel` | ALE metadata columns (ploidy; all-samples-as-normal). Launch-time guard (2026-09-07): `snpeff` in `tools` with neither `snpeff_cache` nor `download_cache` → error; new `download_cache` take (caller `utils_nfcore_sarek_pipeline` passes it). |
| `utils_nfcore_sarek_pipeline` | YAML `processVersionsFromYAML()` reads content explicitly (cloud paths, SnakeYAML ambiguity) and drops empty documents. **ALE preflight (2026-09-23):** `validateAleRecipe()` (called from `validateInputParameters()`; warns per parameter that drifts from the Tier-1 recipe map — a deliberate second copy of `conf/test/ottilie_common.config` + the read-preprocessing defaults, kept honest by the zero-warnings case of `tests/preflight.nf.test`) and `validateAleSamplesheet(rows)` (errors: empty experiment id after the schema's `patient`/`experiment` overwrite, duplicate input paths; warns: mixed ploidy / clonal flag within an experiment). To run the row checks at DAG build, `samplesheetToList()` is materialised into a list before `Channel.fromList` — same rows, same channel. Prefix `[yAMP preflight]`; user page `docs/usage/preflight_checks.md`. **QC-first run (2026-09-24):** `validateQcOnly()` (errors for `--qc_only` with `step != mapping`, `multiqc` skipped, `cleanup = true` — read via `workflow.session.config.cleanup`), and `PIPELINE_COMPLETION` takes two more inputs (`qc_only`, `multiqc_title`; `main.nf` passes `params.*`) for `qcOnlyCompletion()`, which prints the report path (MultiQC's `--title` → filename rule reproduced; measured on 1.25.1 and 1.35) and the `-resume <sessionId>` command. Neither `params` nor `workflow` resolves inside the `onComplete` closure of a workflow body (NPE at completion) — hence the inputs and the script-level function. **Input-checks table (2026-09-29):** the three `validate*` functions also return `[check, status, detail]` rows (OK rows included; console output unchanged), `preflightTable()` renders them with the header `bin/preflight_reference.sh` writes (same MultiQC id → one table; keep the two identical), and `PIPELINE_INITIALISATION` emits them as `preflight_mqc` (`collectFile`, `storeDir` `reports/preflight/`). `collapsedSummaryMultiqc()` wraps the Workflow Summary YAML of nf-core's `paramsSummaryMultiqc()` in `<details>` (the vendored function stays untouched). `qcOnlyCompletion()` names the read-QC report. |
| `bam_variant_calling_somatic_all` | FreeBayes somatic channel disabled (noise for ALE). |
| `bam_variant_calling_somatic_mutect2` | FilterMutectCalls placeholder-channel fix (runs without germline resource/PoN). |
| `annotation_cache_initialisation` | Skip `exists()/isDirectory()` for `az|s3|gs://` cache paths (blob prefixes are not directories). ⚠️ **File deleted upstream in 3.9.0** (#2194), replaced by nf-core `utils_annotation_cache`, which also applies the `<db>/<db>/` key to every cloud URL — our flat `az://` cache dirs fail under it. Port as a subworkflow patch, or make it moot with a tarball cache: `ale_sarek_upgrade_runbook.md` → *Known Rebase Hazards: SnpEff cache*. |

## `modules/local/` — ADDED (21, additive)

One row per directory. `bin/check_doc_drift.sh` (run by the commit gate) keeps this table, the two
other ADDED tables and the counts in their headings and in the Summary equal to the tree — the rebase
runbook points here instead of carrying a copy (corrected 2026-09-28: the list still named the two
`survivor_*` modules retired at `cf24115` and lacked the four SV modules added in August). Upstream's
own `modules/local/` (`add_info_to_vcf`, `create_intervals_bed`, `samtools`) is untouched.

| Module | Role |
|--------|------|
| `build_cn_matrix` | Per-sample CN matrices from CNVKit output (`bin/build_cn_matrix.py`). Mutation report. |
| `build_cn_cohort` | Collapsed cohort CN matrix from the bin-level CN (`bin/cn_cohort_matrix.py`). Mutation report. |
| `build_contig_cn` | Contig-level copy number from TIDDIT's per-contig coverage (`bin/contig_copy_number.py`) — the one place Mito is quantified. |
| `build_sv_matrix` | SV cohort matrix from the SVDB cross-caller cohort VCF (`bin/sv_cohort_matrix.py`). |
| `check_sv_sample_order` | Guard for `SVDB_MERGE --same_order`: svdb never checks sample-column names and would assign genotypes by position, silently. |
| `cnr_to_bedgraph` | CNVKit `.cnr` → BedGraph coverage tracks for igv-reports. |
| `collapse_sv_pairs` | SV breakend pairs → one record per junction, on every caller's VCF before any SVDB merge (`bin/collapse_sv_pairs.py`). |
| `filter_pass_vcf` | PASS-only VCF plus a stats TSV for the report. |
| `generate_index` | The dashboard `index.html` (Jinja2; pandas + jinja2 image — `docs/igvreports/`). |
| `igvreports_cohort` | Cohort igv-reports HTML (custom Tabulator template; the gene track is its only track). |
| `igvreports_sample` | Per-sample igv-reports HTML with CRAM pileup and gene track. |
| `igvreports_sv_cnv` | Per-sample SV/CNV igv-reports HTML (CNVKit BedGraph tracks, Manta, TIDDIT). |
| `prepare_gff3` | Sort, bgzip and tabix the `report_gff3` gene track. |
| `prepare_vcf` | VCF pre-processing for igv-reports (multi-allelic split, …). |
| `publish_vcfs` | The report's download VCFs, renamed for users (annotated when an annotator ran, else raw). |
| `tiddit_sv_filter` | Manta-inspired soft filters for TIDDIT's PASS view (2026-08-31). |
| `preflight_reference` | Task-level reference preflight (2026-09-28): `bin/preflight_reference.sh` in the gawk container; one check today, FASTA vs `report_gff3` contig names (`docs/usage/preflight_checks.md`). |
| `genbank_reference` | GenBank reference route, step 1 (2026-11-02, unwired until `--genbank` lands): `bin/genbank_to_reference.py` in the BioPython container derives from one GenBank the FASTA and the report GFF3 (LOCUS names, record order), the contig manifest, the per-genome `snpEff.config` (one `codonTable` line per contig whose `/transl_table` is not 1), the snpEff copy with VERSION := LOCUS, the names snpEff will store, and two rows of the input-checks table. **Contig-name wiring convention** (`genbank_reference_input.md` §3.2): every contig name in a FASTA, GFF3, config line or manifest is the LOCUS name; whoever hands snpEff a GenBank rewrites VERSION first; snpEff stores names *simplified* (leading chr/chromo/chromosome and leading zeros stripped) and simplifies a VCF's CHROM the same way, so every output keeps LOCUS. |
| `snpeff_build` | GenBank reference route, step 2: `snpEff build -genbank` in nf-core module shape (`meta.yml`) on snpEff's bundled config plus the per-genome codonTable lines; gates in `bin/snpeff_build_gates.sh` (protein check `Errors: 0`, stored contig names == the expected list), exit 65 on failure; the GenBank copy removed from the cache afterwards. Candidate for an nf-core `snpeff/build` contribution (inline the gate script then). |
| `breseq` | breseq (`breseq/`, `breseq/summary_mqc/`) — Tier-2, AMP-v1 legacy, not released. |
| `gdtools` | breseq's gdtools (`gdtools/convert/`) — legacy, with `breseq`. |

---

## `modules/nf-core/` — PATCHED (4 — ⚠️ highest rebase risk)

> 2026-09-09: `controlfreec/freec/main.nf`, `conf/modules/controlfreec.config` and the somatic/tumor-only
> Control-FREEC subworkflows were reverted to pristine sarek 3.5.1 and the fork's germline Control-FREEC
> subworkflow removed — tag `tier2-tools-archive`, `docs/archive/tier2/README.md`.

These are in-place edits to upstream nf-core modules. On rebase, re-apply or re-evaluate each:

| Module | ALE change |
|--------|------------|
| `gatk4/haplotypecaller/main.nf` | `--sample-ploidy ${meta.ploidy}` for variable-ploidy yeast (Tier 1). |
| `vcftools/main.nf` | Conditional-skip guards (ploidy>2, Mutect2 phased GT, joint-calling segfault). |
| `multiqc/main.nf` + `environment.yml` | **Container pinned to MultiQC 1.35** (2026-09-24): `biocontainers/multiqc:1.35--pyhdfd78af_0` and its galaxy singularity twin, `environment.yml` → `1.35`. The module's inputs/outputs are still the sarek-3.5.1-era nf-core signature and `modules.json` still records that module's git_sha (`nf-core modules lint` flags the local edit — same class as the two rows above). |
| `gatk4/variantfiltration/main.nf` + `environment.yml` | **Container set to the tree's GATK image** (2026-10-01): `biocontainers/gatk4:4.5.0.0--py36hdfd78af_0` and its galaxy singularity twin, `environment.yml` → `gatk4=4.5.0.0`, in place of upstream's Wave community image `gatk4_gcnvkernel:edb12e4f0bf02cd3` (GATK 4.6.2.0 + gcnvkernel, one 1 977 MB layer, used by this module alone). The module itself is the later nf-core version installed for `VARIANTFILTRATION_FALLBACK` and is otherwise untouched; `modules.json` still records its git_sha. Why: every cold node paid a 2 GB pull for a 5-second step, and on 2026-10-01 that layer was served at 0.36 MB/s — two Platform runs sat about 90 minutes on it (`azure_batch_execution.md` §18). VariantFiltration applies JEXL expressions to existing annotations; measured record-identical between 4.6.2.0 and 4.5.0.0 on the test set (100 records) and the 4-sample pilot (451). **At a rebase:** keep the step on whatever GATK image the rest of the new tree uses; take upstream's container only if the other GATK modules moved to it too. |

**Why pin the container rather than take upstream's 3.10 `multiqc` module** (which pins the same 1.35):
the 3.10 module has a new input contract (one tuple `[meta, files, config, logo, replace_names,
sample_names]`), meta-tupled outputs (`MULTIQC.out.data` becomes `[meta, dir]`, so `GENERATE_INDEX`'s
input mapping changes) and reports its version through an `eval` topic that needs the `nf-core-utils`
plugin and Nextflow ≥ 25.04 — that is the versions-manifest / topic-channel migration of a sarek
rebase, not a MultiQC bump. **At a rebase to sarek ≥ 3.10 drop this pin**: the new module brings 1.35
itself (`ale_sarek_upgrade_runbook.md` → *Known Rebase Hazard: MultiQC container pin*). What 1.35
changed on our outputs — measured 2026-09-24 on the e2e MULTIQC task's exact staged inputs, run twice —
is tabled in `output_comparison.md` §2.4 / §2.10 / §2.12.

## `modules/nf-core/` — ADDED (5, via `nf-core modules install`)

`bcftools/filter`, `bcftools/query`, `bcftools/view`, `gatk4/variantfiltration`, `igvreports`.
Upstream-managed modules (clean installs, low rebase cost) — except `gatk4/variantfiltration`, whose
container is patched since 2026-10-01 (PATCHED table above).

---

## `conf/` — ADDED (19)

One row per file (`*.config` and `*.yml`, path relative to `conf/`), kept equal to the tree by
`bin/check_doc_drift.sh` like the other two ADDED tables.

| File | Role |
|------|------|
| `modules/manta_ale.config` | Manta overrides: `--exome` when `manta_high_sensitivity` (or `wes`); keeps upstream `manta.config` 0-diff. Pairs with `assets/manta_high_sensitivity.ini`. |
| `modules/genbank_reference.config` | `GENBANK_REFERENCE` and `SNPEFF_BUILD` (2026-11-02): errorStrategy terminate + debug like the preflight task, publish of their input-checks tables and of `reference/<db>/` (inert until the `--genbank` route is wired). |
| `modules/split_joint_vcf.config` | Per-caller (HC, Manta) rules for `SPLIT_JOINT_VCF`, keyed on `meta.variantcaller`; moved out of `joint_germline.config` so that upstream file only carries the VARIANTFILTRATION_FALLBACK change. |
| `modules/preflight.config` | `PREFLIGHT_REFERENCE` (2026-09-28, included from `nextflow.config`): `errorStrategy 'terminate'` (the base strategy is `finish`; the script exits 65, outside the retry range), `debug` so its verdict lines reach the console, publish to `reports/preflight/`. |
| `modules/mutation_report.config` | Process settings of the `mutation_report` subworkflow. |
| `modules/custom_haplotypecaller_joint_filter.config` | The opt-in hard filter of the per-sample VCFs from joint calling (`vcf_filter_haplotypecaller_joint`; off in every ALE recipe since 2026-09-08). |
| `modules/breseq.config` | breseq (Tier-2). `custom_freebayes_filter.config` / `custom_mutect2_filter.config` were removed 2026-09-09 with their subworkflows — `docs/archive/tier2/README.md`. |
| `test/ottilie_common.config` | The shared ottilie calling recipe, included by every ottilie profile. |
| `test/ottilie_test.config` | The release contract test: 2 samples, 4 chromosomes, local `data/ottilie/`. |
| `test/ottilie_test_az.config` | The same test with every input on the private blob (`az://`), for Azure Batch / Seqera. |
| `test/ottilie_test_ci.config` | The same test streamed from the public blob over https (no credentials). |
| `test/ottilie_pilot_az.config` | The full-depth 4-sample pilot — a benchmark profile, not a contract test. |
| `azured4as.config` | The dev-VM resource profile (`-profile azureD4as`, 4 vCPU / 16 GB). |
| `mymachine.config` | Template resource config for any other machine (copy, edit the two numbers, pass with `-c`). |
| `azure_batch.config` | Azure Batch executor with a local head job (`-c`, deliberately not a profile). |
| `disk_probe.config` | Opt-in diagnostic: logs each Batch node's disk usage at the start of every task. |
| `seqera_azure.config` | Seqera Platform supplement to `base.config` for Azure Batch. |
| `schema_overlay.yml` | The ALE overlay that `bin/apply_schema_overlay.py` applies to the upstream schema (visible parameters, groups, launch-form order and texts; since 2026-10-04 also the file-name and Azure-path validation rules of the path parameters). |
| `params_ottilie_test_blob.yml` | Params file for the blob-hosted test run with `azure_batch.config`. |

The two legacy Seqera presets are gone — `params_seqera_test.yml`, the CEN.PK preset, removed
2026-09-09; `params_seqera_381.yml`, the upstream-sarek-3.8.1 comparison preset, removed 2026-09-11,
last at `63eacf9` — the generated Launchpad box in `deploy/azure/seqera-sp/` is the live preset and
`docs/usage/params_template.yml` the user-facing one.

## `conf/` — MODIFIED (7, in place)

`base.config`, `modules/cnvkit.config` (ploidy on call+export; germline CNVKIT_CALL prefix),
`modules/joint_germline.config`
(VARIANTFILTRATION_FALLBACK params only — the SPLIT_JOINT_VCF rules moved to `split_joint_vcf.config`; its selector also names the module's own `GATK4_VARIANTFILTRATION`, which is what the process runs as in `tests/variantfiltration_fallback.nf.test`), `modules/freebayes.config`,
`modules/tiddit.config`, `modules/modules.config` (vcftools conditional `ext.when`),
`modules/trimming.config` (fastp: `filter_quality` off-switch for the read filter, `--cut_<mode>` per
end, explicit adapters — `fastq_preprocessing_audit.md` §2.1). Post-trim FastQC (2026-09-23):
`modules/modules.config` gains `FASTQC_TRIMMED` (`ext.prefix = "${meta.id}_trimmed"`, publish to
`reports/fastqc/<id>/trimmed/`) and `CAT_FASTQ_TRIMMED` (unpublished); `base.config`'s `FASTQC`
resource block became `FASTQC|FASTQC_TRIMMED`. Three MultiQC reports (2026-09-29; replaces the
2026-09-24 `yAMP QC-only run` title closure): `MULTIQC_READ_QC` / `MULTIQC_ALIGNMENT_QC` / `MULTIQC`
get `--title "<multiqc_title ?: yAMP> read-QC | alignment-QC | complete-QC"`; `--title` also names the
early two's files, while the complete one pins `output_fn_name` / `data_dir_name` / `plots_dir_name`
to MultiQC's defaults via `--cl-config` (explicit names beat the title slug — measured on 1.35), so
everything keyed on `multiqc_report.html` / `multiqc_data/` is unchanged. One `publishDir` block for
all three. **Selector inheritance (measured 2026-09-29):** every `withName: 'MULTIQC'` setting also
reaches the two aliases unless a block for the alias sets the same directive
(`compute_resources.md` → *Aliases*). Hence `base.config` gives them their own block,
`MULTIQC_READ_QC|MULTIQC_ALIGNMENT_QC` → 1 CPU / 6 GB (until then they inherited `MULTIQC`'s 4 CPUs /
12 GB — `82fa664`'s message says `process_single`, which was never true), and each alias block in
`modules/modules.config` sets its own `ext.args`: without it an alias would inherit the complete
report's title and pinned output names and overwrite `multiqc_report.html`.

---

## Rebase guidance

1. **Additive files** (added subworkflows/modules/configs) carry forward with no conflict — copy them in.
2. **The 4 patched nf-core modules + `workflows/sarek/main.nf`** are the real work: re-apply each edit
   against the new upstream, then re-run the ALE contract test (`tests/ottilie_e2e.nf.test`) to confirm
   the deliverables still match. If a deliverable shifts, the CSV/tree assertions pinpoint it.
3. **Do NOT** surgically delete unused upstream tools (sentieon, ascat, dragmap, tumor-only) — leaving
   them inert is more upgrade-friendly than a delete-patch that conflicts forever (see runbook).
4. Upstream-provided `*.diff` patches (dragmap, gatk4/intervallisttobed, bcftools/annotate,
   controlfreec/assesssignificance) ship with sarek — retain them, they are not ALE changes.
5. **The `--qc_only` gate is a starvation gate** (see `workflows/sarek/main.nf` above). A rebase is
   when `toList()` / `ifEmpty(...)` / value-channel / plain-file inputs arrive unreviewed downstream
   of alignment: run `tests/qc_gate.sh a` after every rebase and after any such change, and either
   gate the offending process on `params.qc_only` or add harmless reference prep to the allow-list.
