# yAMP documentation index

A map of `docs/`. **This page links; it does not explain.** For what yAMP is, how to install it, and
how to run it, start at the [**root README**](../README.md).

| If you want to… | Go to |
|---|---|
| Install / run the pipeline | [`../README.md`](../README.md) |
| Set up a brand-new machine | [`usage/new_machine_setup.md`](usage/new_machine_setup.md) |
| Write the input samplesheet | [`usage/input_samplesheet.md`](usage/input_samplesheet.md) |
| Prepare your reference (FASTA, GFF3, SnpEff cache) | [`usage/prepare_reference.md`](usage/prepare_reference.md) |
| Launch with a params file (template, precedence, traps) | [`usage/launch_params_file.md`](usage/launch_params_file.md) |
| Know what's in this release (incl. tool tiers) | [`../CHANGELOG.md`](../CHANGELOG.md) |
| Know what changed vs upstream Sarek | [`dev-practices/SAREK_MODIFICATIONS.md`](dev-practices/SAREK_MODIFICATIONS.md) |
| Understand a specific tool's behaviour | [Variant calling & CNV/SV](#variant-calling--cnvsv) |
| Interpret the outputs | [Output & reporting](#output--reporting) |
| Work on the pipeline itself | [Development & maintenance](#development--maintenance) |
| Cut a release | [`dev-practices/release_process.md`](dev-practices/release_process.md) |

---

## Input & preparation

| Doc | What it covers |
|---|---|
| [`usage/input_samplesheet.md`](usage/input_samplesheet.md) | Samplesheet columns (`experiment`, `sample`, `ploidy`, `clonal_or_population`, …), the optional `status` / `sex` columns and their defaults, conventions, and the one-normal-per-experiment rule |
| [`usage/prepare_reference.md`](usage/prepare_reference.md) | **Preparing a reference**: GenBank → FASTA + GFF3 + SnpEff cache (`prepare_input/process_GeneBank/process_genbank_auto.sh`), or FASTA + GFF3 → cache (`prepare_input/build_snpeff_cache.sh`); snpEff 5.1 lock, flat layout, chromosome-name rule, GenBank-converter limitation |
| [`prepare_input/sarek_csv_to_XPMD/README.md`](prepare_input/sarek_csv_to_XPMD/README.md) | Samplesheet conversion to XPMD format |
| [`benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md`](benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md) | Test-data lineage, truth set, and how to regenerate or download it |

### Running & deployment

| Doc | What it covers |
|---|---|
| [`usage/qc_first_run.md`](usage/qc_first_run.md) | **QC-first run (`--qc_only`)**: stop after read QC, sign the reports off, continue the same run with `-resume`; what to look at, the errors, how the gate works and the test that guards it |
| [`usage/launch_params_file.md`](usage/launch_params_file.md) · [`usage/params_template.yml`](usage/params_template.yml) | **Launching with a params file**: generated template of every launch-form field (+ the hidden Tier-1 ones) in form order; `-params-file` / Seqera upload / `tw launch`; precedence; the `null`-is-a-string and directory-cache traps |
| [`dev-practices/compute_resources.md`](dev-practices/compute_resources.md) | Resource model, `resourceLimits` clamp, per-VM porting, cloud notes |
| [`dev-practices/azure_batch_execution.md`](dev-practices/azure_batch_execution.md) | **Start here for Azure Batch.** Why the config differs from the stock tutorial (4 settings), plus the execution gotchas: work-dir/container rule, node-agent SKU, pool ids, `-resume`, cost |
| [`seqera_cloud/seqera_cloud_deployment_checklist.md`](seqera_cloud/seqera_cloud_deployment_checklist.md) | Seqera Platform + Azure Batch deployment checklist (April 2026, predates the service-principal work; verify against `deploy/azure/seqera-sp/RUNBOOK.md`) |
| [`seqera_cloud/azure_batch_recommendations.md`](seqera_cloud/azure_batch_recommendations.md) | ⚠️ Stale (April 2026): VM-sizing background only. Its config advice recommends **account keys**, which the current setup deliberately replaced with an Entra service principal |
| [`usage/azure_vm_swap_setup.md`](usage/azure_vm_swap_setup.md) · [`usage/azure_blob_large_file_upload.md`](usage/azure_blob_large_file_upload.md) | VM swap; uploading >50 GB files to blob |
| [`usage/nextflow_local_executor_deadlock.md`](usage/nextflow_local_executor_deadlock.md) | Local-executor deadlock and how to avoid it |
| [`dev-practices/troubleshooting.md`](dev-practices/troubleshooting.md) | Common run failures (starting with misleading samplesheet errors) |

---

## Output & reporting

Output-directory layout is in the [root README](../README.md#output).

| Doc | What it covers |
|---|---|
| [`igvreports/README.md`](igvreports/README.md) | igv-reports report structure, templates, and the static assets the pipeline consumes |
| [`igvreports/check_mutations.md`](igvreports/check_mutations.md) | How the report is assembled for ALE variant review |
| [`igvreports/templates/README.md`](igvreports/templates/README.md) | The `index.html.j2` contract: the context the renderer builds, what changed in the 2026-10-06 redesign, presentation mode |
| [`generate_mutation_report/README.md`](generate_mutation_report/README.md) | MUTATION_REPORT integration design |
| [`generate_mutation_report/generate_index_container.md`](generate_mutation_report/generate_index_container.md) | The `ale-reports` container (pandas + jinja2) used by GENERATE_INDEX |
| [`qc-reporting/multiqc_mosdepth_coverage.md`](qc-reporting/multiqc_mosdepth_coverage.md) | How to read MultiQC/mosdepth coverage numbers |
| [`manual_vcf_operations.md`](manual_vcf_operations.md) | bcftools recipes for slicing pipeline VCFs by hand |

---

## Variant calling & CNV/SV

### SNV / INDEL: HaplotypeCaller (Tier 1)

| Doc | What it covers |
|---|---|
| [`variant-calling/haplotypecaller/haplotypecaller_workflow_analysis.md`](variant-calling/haplotypecaller/haplotypecaller_workflow_analysis.md) | Joint vs individual calling; the known-sites starvation pattern on custom genomes (why BQSR/VQSR are off) |
| [`variant-calling/haplotypecaller/SOFT_FILTER_HAPLOTYPECALLER_JOINT.md`](variant-calling/haplotypecaller/SOFT_FILTER_HAPLOTYPECALLER_JOINT.md) | `VARIANTFILTRATION_FALLBACK`: thresholds, FILTER tags, PASS extraction |
| [`variant-calling/haplotypecaller/HARD_FILTER_HAPLOTYPECALLER_JOINT.md`](variant-calling/haplotypecaller/HARD_FILTER_HAPLOTYPECALLER_JOINT.md) | `--hard_filter_haplotypecaller_joint` (clonal/population AF thresholds): opt-in, off in every ALE recipe since 2026-09-08 |
| [`variant-calling/haplotypecaller/SPLIT_JOINT_VCF_PIPELINE.md`](variant-calling/haplotypecaller/SPLIT_JOINT_VCF_PIPELINE.md) | `--split_haplotypecaller_joint_vcf`: per-sample extraction, channel flow |
| [`compare_single_pop_HpCaller/README.md`](compare_single_pop_HpCaller/README.md) | Single-sample vs joint calling comparison |

### CNV: CNVKit (Tier 1)

| Doc | What it covers |
|---|---|
| [`variant-calling/cnvkit/cnvkit_cn_calculation.md`](variant-calling/cnvkit/cnvkit_cn_calculation.md) | **Canonical** CN-matrix reference: `fold_change = 2^log2`, cohort collapse, column schema |
| [`variant-calling/cnvkit/cnvkit_ploidy_behavior.md`](variant-calling/cnvkit/cnvkit_ploidy_behavior.md) | Why integer `cn` is always diploid-baseline regardless of ploidy; VCF export |
| [`variant-calling/cnvkit/cnvkit_sarek_dual_call.md`](variant-calling/cnvkit/cnvkit_sarek_dual_call.md) | `.call.cns` vs `.germline.call.cns` |
| [`variant-calling/cnvkit/cnvkit_small_chr_exclusion.md`](variant-calling/cnvkit/cnvkit_small_chr_exclusion.md) | Small-chromosome exclusion in WGS mode |

### SV: Manta + TIDDIT + SURVIVOR (Tier 1)

| Doc | What it covers |
|---|---|
| [`variant-calling/sv_merge.md`](variant-calling/sv_merge.md) | **Maintainer reference** for the SURVIVOR merge chain: CLI params, `SUPP_VEC`, `proximity_match`, CSV schema, gotchas |
| [`variant-calling/tiddit/tiddit_ploidy_behavior.md`](variant-calling/tiddit/tiddit_ploidy_behavior.md) | TIDDIT `-n` ploidy effects on normalization and GT thresholds |
| [`variant-calling/manta/manta_filter_vs_ft.md`](variant-calling/manta/manta_filter_vs_ft.md) | `FILTER` vs `FORMAT/FT` in single-sample Manta |
| [`variant-calling/manta/manta_calling_modes.md`](variant-calling/manta/manta_calling_modes.md) | **Which Manta mode to use**: joint per-experiment is the default and why; large-cohort limit; why `--manta_high_sensitivity` stays opt-in |
| [`variant-calling/sv_uniform_genotyping_roadmap.md`](variant-calling/sv_uniform_genotyping_roadmap.md) | **Roadmap (not implemented)**: GVCF-style split of SV discovery from genotyping; why joint Manta covers small cohorts but not large ones, and the trigger to build it |

### Tier 2 tools

| Doc | What it covers |
|---|---|
| [`archive/tier2/tier2_af_filters.md`](archive/tier2/tier2_af_filters.md) | AF-based somatic filters for Mutect2 & FreeBayes, and why they're Tier 2 |
| [`variant-calling/mutect2/mutect2_custom_genome_resources.md`](variant-calling/mutect2/mutect2_custom_genome_resources.md) | Running Mutect2 without germline-resource / panel-of-normals |
| [`variant-calling/mutect2/MUTECT2_JOINT_CALLING_TIMEOUT.md`](variant-calling/mutect2/MUTECT2_JOINT_CALLING_TIMEOUT.md) | Joint-Mutect2 timeout behavior |
| [`archive/tier2/FREEBAYES_FILTERING_PIPELINE.md`](archive/tier2/FREEBAYES_FILTERING_PIPELINE.md) | FreeBayes filtering chain (germline mode only) |
| [`archive/tier2/controlfreec_germline_changes.md`](archive/tier2/controlfreec_germline_changes.md) | Control-FREEC single-sample germline mode |
| [`variant-calling/breseq/BRESEQ_LOW_COVERAGE_BEHAVIOR.md`](variant-calling/breseq/BRESEQ_LOW_COVERAGE_BEHAVIOR.md) | ⚠️ breseq calls **false whole-chromosome deletions** on low-coverage / subsampled data. Read before trusting any breseq output |
| [`variant-calling/breseq/BRESEQ_INTEGRATION_PLAN.md`](variant-calling/breseq/BRESEQ_INTEGRATION_PLAN.md) | breseq subworkflow design & integration record (as-built) |
| [`investigate_filter/mutect2_filter/README.md`](investigate_filter/mutect2_filter/README.md) | Mutect2 filtering-strategy investigation |
| [`compare_mutect2_HpCaller/CENPK_all/paper_a_benchmark/README.md`](compare_mutect2_HpCaller/CENPK_all/paper_a_benchmark/README.md) | VCF filtering guidelines from the Mutect2-vs-HC benchmark |

### Background reading

[`usage/variantcalling/`](usage/variantcalling/) is a general variant-calling tutorial
([introduction](usage/variantcalling/introduction.md) · [theory](usage/variantcalling/theory.md) ·
[Sarek](usage/variantcalling/sarek.md) · [interpretation](usage/variantcalling/interpretation.md)).

---

## Development & maintenance

| Doc | What it covers |
|---|---|
| [`dev-practices/release_process.md`](dev-practices/release_process.md) | **SOP for cutting a release**: checklist, tag → container-image flow, verification, and the CI/registry gotchas |
| [`dev-practices/check_docs.py`](dev-practices/check_docs.py) | Doc consistency checker (broken markdown links + stale backticked repo paths); used by the release checklist |
| [`dev-practices/SAREK_MODIFICATIONS.md`](dev-practices/SAREK_MODIFICATIONS.md) | Full inventory of fork changes vs pristine sarek 3.5.1 |
| [`dev-practices/ale_sarek_upgrade_runbook.md`](dev-practices/ale_sarek_upgrade_runbook.md) | How to rebase onto a newer sarek; the Nextflow 26.x blocker inventory |
| [`dev-practices/testing_and_coverage_overview.md`](dev-practices/testing_and_coverage_overview.md) | **Start here for testing.** One-page overview of testing and code coverage: the five testing documents in reading order, the results so far, the three tools, the test levels and their case counts, the four coverage measures with the current fork figures, the limits of the measurement, and the decisions taken; the short version of `testing_best_practices.md` and `nextflow_code_coverage.md` |
| [`dev-practices/testing_best_practices.md`](dev-practices/testing_best_practices.md) | nf-test strategy, what is (and isn't) tested here, coverage targets |
| [`dev-practices/nextflow_code_coverage.md`](dev-practices/nextflow_code_coverage.md) | **Which lines of our `.nf` / `.config` files the test suite executes.** JaCoCo on the Nextflow head JVM (`tests/nf_coverage.sh`): lines, data-driven closures, branch coverage (the headline; JaCoCo branches, two per conditional jump) and fully covered decision lines (the worklist); the first measurement and the list of fork code no test runs |
| [`dev-practices/test_inventory_2026-10-19.md`](dev-practices/test_inventory_2026-10-19.md) | **Test inventory per scope** (`bin/test_inventory.py`): every file under `main.nf`, `nextflow.config`, `workflows/`, `subworkflows/`, `modules/`, `conf/`, `bin/` classified ADDED / MODIFIED / PRISTINE against pristine sarek 3.5.1 by byte comparison, with whether any run of the 2026-10-13 coverage measurement reached it; the fork files no test executes, the disagreements with `SAREK_MODIFICATIONS.md`, and the one-line sentence that replaces the folder-based "6 of 89" |
| [`dev-practices/sarek_351_benchmark_2026-10-20.md`](dev-practices/sarek_351_benchmark_2026-10-20.md) | **Benchmark: pristine nf-core/sarek 3.5.1 under the yAMP coverage method** (issue #14, item 5; script in [`dev-practices/sarek_351_benchmark_2026-10-20/`](dev-practices/sarek_351_benchmark_2026-10-20/)): sarek's own `default.nf.test` on its own code (13.7 % branches) against our e2e on fork code (42.0 %) and our whole suite (56.7 %), each tree on its own-code denominator, plus our e2e on our whole tree (20.7 %) as context; the floor pair, the joint-germline route, an all-code-to-all-code table, and why the denominators differ by a factor of six |
| [`dev-practices/nextflow_branch_counting.md`](dev-practices/nextflow_branch_counting.md) | **How JaCoCo counts branches in Groovy / Nextflow code** (probe of 2026-10-13, sources and data in [`dev-practices/nextflow_branch_counting/`](dev-practices/nextflow_branch_counting/)): two per conditional jump, so `if (a && b)` is six where Java gives four, `if (!a)` four, `x?.y` none, and a `branch` operator default adds one branch no run can take. The measured basis for reading the branch-coverage figure in `nextflow_code_coverage.md`; the per-construct table, the bytecode, and how much of the fork denominator the compiler artefacts are |
| [`dev-practices/output_comparison.md`](dev-practices/output_comparison.md) | **Which outputs are deterministic and which are not**: the classes of run-to-run noise (timestamps, gzip framing, embedded paths, MultiQC renders, igv-reports blobs) with normalisation recipes, plus the 3-tier method for diffing two runs. The *why* behind `tests/.nftignore` |
| [`dev-practices/compute_resources.md`](dev-practices/compute_resources.md) | Resource model and config layout |
| [`dev-practices/roadmap.md`](dev-practices/roadmap.md) | Prioritized post-1.0.0 work |
| [`dev-practices/history_rewrite_2026-08.md`](dev-practices/history_rewrite_2026-08.md) | The 2026-08-31 history rewrite (private-data purge before open-sourcing): old ↔ new SHA map and the purge list. Every pre-rewrite commit SHA is stale |
| [`usage/preflight_checks.md`](usage/preflight_checks.md) | **Start-up preflight**: the `[yAMP preflight]` errors (no experiment id, duplicate input files, impossible `--qc_only` combinations) and warnings (Tier-1 recipe drift, mixed ploidy/clonal flag within an experiment) that run before the first task, plus the task-level reference check (FASTA vs `report_gff3` contig names) that runs as the first task |
| [`usage/read_preprocessing.md`](usage/read_preprocessing.md) | **Read preprocessing, user view**: the opt-in steps in run order (UMI consensus · adapter trimming · fixed-count clipping · quality trimming per end · read filtering), parameters, recommended recipe, schematic |
| [`dev-practices/fastq_preprocessing_audit.md`](dev-practices/fastq_preprocessing_audit.md) | **What happens to reads before bwa-mem**: audit of the FastQC/fastp path, the 2026-09 trimming design, fastp measurements on the test set, validation, and the open Trimmomatic question |
| [`dev-practices/troubleshooting.md`](dev-practices/troubleshooting.md) | Debugging guide |
| [`dev-practices/container_null_cloud_portability.md`](dev-practices/container_null_cloud_portability.md) | Replacing `container null` processes for cloud portability |
| [`pipeline-guides/NEXTFLOW_EXT_PREFIX_GUIDE.md`](pipeline-guides/NEXTFLOW_EXT_PREFIX_GUIDE.md) | How `ext.prefix` works in nf-core module configs |
| [`fixes/`](fixes/) | Write-ups of individual resolved defects (MultiQC versions map, `bin/` staging tar paths, VM resource limits) |
| [`yAMP_docs/yAMP_design.md`](yAMP_docs/yAMP_design.md) | Design overview / project write-up |

Project-level operational notes for contributors live in [`../CLAUDE.md`](../CLAUDE.md).

---

## Benchmarking & validation

| Doc | What it covers |
|---|---|
| [`benchmarking/README.md`](benchmarking/README.md) | Index of benchmark studies and their conventions |
| [`benchmarking/ottilie_xenobiotic_ale/README.md`](benchmarking/ottilie_xenobiotic_ale/README.md) | The release benchmark: *S. cerevisiae* S288C xenobiotic ALE (Ottilie et al. 2022); truth set = 4 SNVs + a chr I duplication |
| [`benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md`](benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md) | SRA → CRAM → test-FASTQ lineage and durability |
| [`benchmarking/adipic_acid_ale/README.md`](benchmarking/adipic_acid_ale/README.md) | breseq vs HaplotypeCaller on CEN.PK113-7D |

---

## Archive

[`archive/`](archive/) holds superseded designs and closed investigations, kept for provenance only;
they do **not** describe current behavior. Notably
[`archive/variant_dashboard_system.md`](archive/variant_dashboard_system.md) (the pre-MUTATION_REPORT
dashboard design), [`archive/sarek_fork_ideas.md`](archive/sarek_fork_ideas.md) (deferred fork ideas),
and per-tool investigation notes under `archive/cnvkit/` and `archive/igvreports/`.

---

## Credits

yAMP is a fork of [nf-core/sarek](https://nf-co.re/sarek) 3.5.1; all upstream credits and tool
citations are retained in [`../CITATIONS.md`](../CITATIONS.md). ALE-specific development is by the
Aletech team (https://github.com/Aletechdev); the pipeline is maintained at
https://github.com/nnf-bright-biofoundry/ALE_Yeast.
