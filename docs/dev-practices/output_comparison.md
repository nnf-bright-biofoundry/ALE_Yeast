# Comparing pipeline outputs — what is a real difference, and what is noise

Two audiences, one problem:

- **Test authors** deciding what may be snapshotted byte-for-byte and what must go in
  [`tests/.nftignore`](../../tests/.nftignore).
- **Anyone diffing two runs** — cloud vs local, before vs after a change, two Azure Batch runs — and
  needing to know whether a difference is a regression.

The underlying question is the same: **which outputs of this pipeline are deterministic?** Fewer than
you would hope. This page lists the classes, the cause of each, and how to compare anyway.

> Worked example throughout: the 2026-08-06 comparison of a Seqera Platform run against the verified
> local-head-job baseline — 529 files in common, **464 byte-size identical, 65 differing, 0 regressions**.
> See [`azure_batch_execution.md` §11](azure_batch_execution.md).

---

## 1. The rule: compare deliverables byte-for-byte, everything else by content

**The acceptance criterion is the nine cohort deliverables (all CSV, listed below)**, because they are
what the pipeline exists to produce and they are genuinely deterministic. Elsewhere in these docs they
are referred to by the shorthand **"cohort deliverables"** — *cohort* separates them from per-sample
outputs, *deliverable* marks them as the thing that must be byte-identical:

```
mutation_reports/data/cn_cohort_collapsed.csv        mutation_reports/data/sv_cohort_matrix_union.csv
mutation_reports/data/cn_cohort_full.csv             mutation_reports/data/sv_cohort_matrix_union_pass.csv
mutation_reports/data/cn_matrices/cn_bins_continuous.csv
mutation_reports/data/cn_matrices/cn_chr_summary_{call,germline}.csv
mutation_reports/data/cn_matrices/cn_segments_{call,germline}.csv
```

(Outputs older than 2026-10-01, including the reference baseline, hold the last five one level deeper,
under `data/cn_matrices/cn_matrices/` — §2.10. Same files, same content.)

All nine were **byte-identical** across local and cloud — first on 2026-08-06, and again on the
2026-09-08 re-cut (`az://aletest/seqera-runs/yAMP-out-test-recut-20260908`, run `2W0uOsPYt03NAL`, the
current reference; there all 14 tables under `mutation_reports/data/` matched, 42/42 VCFs were
record-identical and both CRAMs read-identical). If one of those differs, it is a real finding.
Everything else needs normalising before it means anything.

---

## 2. Classes of non-determinism, and how to normalise each

### 2.1 Embedded timestamps and command lines — VCFs

VCF headers record when and how they were made. Strip before comparing:

```bash
zcat a.vcf.gz | grep -vE '^##(fileDate|source|SnpEffCmd|SnpEffVersion|bcftools_|GATKCommandLine)' > a.norm
zcat b.vcf.gz | grep -vE '^##(fileDate|source|SnpEffCmd|SnpEffVersion|bcftools_|GATKCommandLine)' > b.norm
diff a.norm b.norm
```

⚠️ **`##TIDDITcmd` embeds the thread count**, so TIDDIT VCFs can *never* be byte-identical between runs
with different `cpus`. A local `azureD4as` run (2 CPUs) vs Azure Batch `Standard_E4ds_v4` (4 CPUs) once
produced 8 "differences" that were purely `--threads 2` vs `--threads 4`, with zero variant-record
deltas. Strip that line or expect a false alarm.

### 2.2 gzip / bgzf framing — `.vcf.gz`, `.tbi`

Compressed containers differ by a few bytes even when the payload is identical (compressor version,
block boundaries, embedded mtime). Deltas of **1–7 bytes** on a `.vcf.gz` or `.tbi` are the signature.
**Always decompress before comparing** — never trust the `.gz` bytes.

The framing can also flip **run-to-run on the same machine** when the compressor is multithreaded:
mosdepth's `.regions.bed.gz` produced identical bytes on two consecutive runs (so a recorded md5
snapshot passed its determinism re-run) and then a different — content-identical — byte stream days
later, purely from thread scheduling (caught 2026-08-31). Two consecutive agreeing runs therefore do
NOT prove a `.gz` is byte-stable; snapshot compressed files by name only (`tests/.nftignore`) and
compare their content decompressed.

### 2.3 Absolute paths embedded in outputs

Sarek writes the output directory into its own bookkeeping CSVs:

```
csv/markduplicates_no_table.csv      csv/variantcalled.csv
```

So a longer `outdir` string produces a bigger file. In the worked example
`seqera-runs/2026-08-06-04` vs `ottilie-azurebatch-out` accounted **exactly** for the +12 and +33 byte
deltas. Same for `pipeline_info/params_*.json`. Normalise by rewriting the path, or ignore these files.

### 2.4 Render non-determinism — MultiQC plots and data

`multiqc/multiqc_plots/{svg,pdf,png}/*` and several `multiqc_data/*` files differ between runs on the
same inputs (font metrics, dict ordering, embedded creation dates). PDFs can differ by **tens of KB**,
which looks alarming and is not. Compare the underlying numbers instead, never the render.

Measured again on MultiQC 1.35 (2026-09-24, the pinned version; the e2e MULTIQC task's staged inputs
run twice): every `svg`/`pdf` differs between the pair while every `png` is byte-identical;
`multiqc_report.html`, `multiqc.log` and the new **`multiqc.parquet`** (the report's data store)
differ; the new **`llms-full.txt`** (a text rendering of the report for language models) is
byte-identical on fixed inputs — but in the pipeline it embeds the workflow-summary section, which
carries the Nextflow **`runName`**, so it differs between executions exactly like `pipeline_info/`
(§2.7; the e2e pair caught it: one differing line, the run name). Both new files are excluded from
the content snapshot. `multiqc_data.json` was identical across that pair but stays excluded (it was
not on 1.25.1).

### 2.5 Embedded base64 blobs — igv-reports HTML

`mutation_reports/samples/*_report.html` embeds a `sessionDictionary`: a base64-encoded gzip of IGV
alignment views, non-deterministic across gzip runs. File sizes differ slightly between identical runs.

**Compare the variant table instead** — that is the actual content:

```bash
grep -o 'const tableJson = .*' report.html | head -1 > a.tablejson
```

This is how all 17 reports (16 per-sample + cohort) were verified equivalent between pipeline versions.

### 2.6 Provenance that *should* differ — `versions.yml`

```
nnf-bright-biofoundry/ALE_Yeast: v1.1.0            # run from a local directory
nnf-bright-biofoundry/ALE_Yeast: v1.1.0-g<commit>  # run from a Git clone (Seqera Platform, nextflow run <org/repo>)
```

nf-core appends the short commit when a commit id exists. **Not a regression** — it is provenance, and
it means `versions.yml` can never be byte-compared across those two launch modes.

The key is `manifest.name`, which follows the GitHub handle: `Aletechdev/ALE_Yeast` from 2026-08-06 to
2026-10-23, `nnf-bright-biofoundry/ALE_Yeast` since the repo transfer. Every output produced before
2026-10-23 (including every baseline in §2.10) therefore differs on this line, and on the MultiQC summary
section id (`<handle with / → ->-summary`, visible in `multiqc_data/`), from a run of the current code.

The value is `manifest.version`: `v1.0.0` until 2026-11-09, `v1.1.0` since (release `v1.1.0`, the last
state where the reference is given only as pre-built files). Every output produced before that date
reads `v1.0.0`, with or without a commit suffix (the baseline's `v1.0.0-g86c4672` is one example).

⚠️ The verified Azure Batch baseline at `az://aletest/ottilie-azurebatch-out/` was produced under the
old `manifest.name` (`Aletechdev/AMP`), so that line differs there too. See
[`CLAUDE.md` → Pipeline Identity & Naming](../../CLAUDE.md).

### 2.7 Per-execution filenames — `pipeline_info/`

`execution_report_<timestamp>.html`, `execution_timeline_*`, `execution_trace_*`, `pipeline_dag_*`,
`params_*.json`, `manifest_*.bco.json` are timestamped per execution, so the **file names** differ and
the **counts** differ if one side was run more than once. In the worked example this fully explained
540 vs 534 files. Compare by *class*, not by name.

### 2.8 Everything else seen once

- **CRAM ±1 byte** — header metadata.
- **snpEff QC summaries** (`reports/snpeff/*`) — embedded run date.
- **FastQC html/zip**, samtools/picard stats — embedded dates and paths.

### 2.9 Identifiers and column order derived from input file order — **NOT noise, fix it**

The one class in this list that must **never** be normalised away or added to `.nftignore`: a
difference caused by the *order* in which files were handed to a tool. `groupTuple()` and `collect()`
emit in channel-arrival order, which depends on which upstream task finished first; a tool that reads
that order into its output makes every run different by chance.

Seen 2026-08-28 (fixed in `54c33f9`): `MANTA_GERMLINE` builds `--bam a --bam b …` from the grouped
CRAM list, and Manta numbers its record IDs (`MantaBND:52:1:3:…` vs `…:1:4:…`), the `MATEID`s pairing
breakends, and the joint VCF's **sample-column order** from it. Two runs then produce the same
variants, genotypes, filters and coordinates under different names — which propagates to every
downstream hash (the igv-report `tableJson` is what caught it).

**How to recognise it:** the bodies are identical apart from ID-like strings, or the `#CHROM` sample
columns are permuted. Compare the two VCFs with the header stripped; check `##cmdline` for the input
order. **How to fix it:** sort the grouped list — `groupTuple(sort: { it.name })` — never ignore the
file. **How to test for it:** re-running the same input proves nothing (with N samples the same order
recurs by chance); run once with the samplesheet rows **reversed**. Full lesson, and why the repo's
other `groupTuple` calls are safe: [`testing_best_practices.md`](testing_best_practices.md)
§"`groupTuple` order is not deterministic".

### 2.10 Recipe defaults that changed AFTER the baseline was cut — expected, dated differences

Not noise and not a regression: the reference outputs were produced under an older recipe. A default
change is a provenance event for every output already published (`testing_best_practices.md` §13), so
each one is listed here with its date; a comparison against anything older than the date must expect
the difference. **The reference baseline was re-cut on 2026-09-08 and carries the first two changes**;
the rows dated after it are expected differences against that baseline as well, the earlier ones
only against outputs older than it (tier-2, the pilots, the 2026-08 baselines).

| Since | Change | What differs against older outputs |
|---|---|---|
| 2026-09-04 (`948163c`) | fastp `--trim_adapter --trim_quality_3prime tail` is the default | every read-derived file: CRAMs, all VCFs, coverage, the cohort matrices; new `reports/fastp/` |
| 2026-09-08 | `hard_filter_haplotypecaller_joint` left the ALE recipe (pipeline default `false`) | the whole `hard_filtered.*` family is **absent**: `variant_calling_filtered/`, its two `tabix/*.hard_filtered.vcf.gz.tbi` indexes, and the per-sample `annotation/`, `reports/{bcftools,snpeff,vcftools}/` siblings; the MultiQC bcftools/vcftools aggregate tables lose those rows; 16 fewer tasks on the 2-sample set. The joint VCF, the soft per-sample splits and all nine cohort deliverables are unaffected |
| 2026-09-09 (`153be06`) | Tier-2 AF post-filters removed, with the `TABIX_TABIX` index step that fed them | the **`tabix/` folder is gone** — 7 fewer names on the test set: the per-sample `haplotypecaller.from_joint_calling`, `manta.diploid_sv` and `tiddit` `.vcf.gz.tbi` × 2 samples, plus `HaplotypeCaller_joint_calling_soft_filtered.vcf.gz.tbi`; the indexes the report needs are built unpublished since `a9d24e1` (`TABIX_REPORT_VCFS`, publish disabled). Nothing else moves. *(Row added 2026-09-28 from the local-e2e-vs-baseline comparison; the change predates the row.)* |
| 2026-09-23 (`7f896d8`) | Post-trim FastQC — a second FastQC pass on the fastp output, two FastQC sections in MultiQC | new `reports/fastqc/<id>/trimmed/*_trimmed_{1,2}_fastqc.{html,zip}` (8 files on the test set); the MultiQC FastQC tables and plots exist per section under anchored names (`fastqc_raw_*`, `fastqc_trimmed_*`, `multiqc_fastqc_fastqc_{raw,trimmed}.txt`) in place of the single unprefixed `fastqc_*` set of older outputs; General Stats gains the post-trim columns. Read-, alignment- and variant-derived files unchanged. *(Row added 2026-09-28, same comparison.)* |
| 2026-09-24 | MultiQC 1.25.1 → **1.35** (container pin on the 3.5.1-era module; `SAREK_MODIFICATIONS.md` → `modules/nf-core/` PATCHED) | **`multiqc/` only** — no read-, alignment- or variant-derived file moves, task count unchanged. `multiqc_data/`: `fastqc_{raw,trimmed}_top_overrepresented_sequences_table.txt` gone; `llms-full.txt`, `multiqc.parquet`, `samtools_insert_size.txt` new; `picard_histogram{,_1,_2}.txt` renamed by metric (`picard_MarkIlluminaAdapters_histogram.txt`, `picard_MeanQualityByCycle_histogram{,_1}.txt`, `picard_QualityScoreDistribution_histogram.txt`; content identical); format-only content changes in `fastp_filtered_reads_plot.txt` (+`Low Complexity`, `Too Long` columns), `multiqc_samtools_stats.txt` (+`reads_mapped_MQ1`) and `vcftools_tstv_by_count.txt` (`nan` → `None`); General Stats rows identical, +4 columns (fastp `pct_surviving` → `pct_surviving_reads` + `pct_surviving_bases`, `before_filtering_read{1,2}_mean_length`; samtools `insert_size_average`); `multiqc_snpeff.txt` same width, different column set (excluded anyway, §2.11). `multiqc_plots/`: `bcftools_stats_indel-lengths` split into `-cnt`/`-log`, `general_stats_table` and the two overrepresented tables gone, `samtools_insert_size` new (216 → 213 files). Report HTML: section `<h2>` class `mqc-module-title` → `mb-0`, ids and order unchanged; a yAMP `report_comment` at the top. **No versions line moves**: MultiQC's own version is not in `pipeline_info/nf_core_sarek_software_mqc_versions.yml` (MultiQC consumes that file; the task's `versions.yml` is unpublished), only in the excluded `multiqc_data/multiqc_software_versions.txt`. The `--title` file naming of the QC-only run is unchanged. The tables the dashboard reads (`multiqc_bcftools_stats.txt`, the sample rows of `multiqc_general_stats.txt`) are cell-identical — the dashboard did not move |
| 2026-09-24 (`a9d24e1`) | `--tools` without an annotator no longer aborts — raw VCFs indexed for the report | `mutation_reports/vcf/README.md` text (one md5) on the annotated Tier-1 recipe; no other name or content moves. *(Row added 2026-09-28, same comparison.)* |
| 2026-09-28 | `PREFLIGHT_REFERENCE`, the task-level reference preflight (`docs/usage/preflight_checks.md` → *Reference files*) | **New files only; nothing that existed moves.** `reports/preflight/preflight_reference_mqc.tsv` (deterministic — one row per check, the reference basenames in the detail text), `multiqc/multiqc_data/multiqc_yamp_preflight_reference_table.txt` and its three `multiqc_plots/{pdf,png,svg}/yamp_preflight_reference_table.*` exports; one more task (152 → 153 on the test set) and one more entry in the software-versions manifest (`PREFLIGHT_REFERENCE: gawk 5.3.0`); the MultiQC report gains a first section, *yAMP preflight: reference*. Nothing downstream consumes the task, so every other file is unchanged (e2e re-record 2026-09-28: only these lines moved) |
| 2026-09-29 | Three MultiQC reports (read-QC and alignment-QC while the run continues, complete-QC at the end) + one *yAMP input checks* table + collapsed Workflow Summary (`docs/usage/qc_first_run.md` → *The three MultiQC reports*) | **`multiqc/` and `reports/preflight/` only.** +2 tasks (153 → 155 on the test set: `MULTIQC_READ_QC`, `MULTIQC_ALIGNMENT_QC`); +364 names — `multiqc/yAMP-read-QC_multiqc_report{.html,_data/,_plots/}` (161) and `multiqc/yAMP-alignment-QC_multiqc_report…` (203), names only (content `.nftignore`d: subsets of the complete report plus the same run-dependent files); `reports/preflight/preflight_samplesheet_params_mqc.tsv` new (deterministic, md5-pinned); the reference-check table's MultiQC id `yamp_preflight_reference(_table)` → `yamp_input_checks(_table)`, so `multiqc_data/multiqc_yamp_input_checks_table.txt` and its three `multiqc_plots/{pdf,png,svg}` exports replace the `…preflight_reference…` names (5 rows: the reference row + 4 start-up checks); `preflight_reference_mqc.tsv` md5 moves (shared header text). The complete report keeps `multiqc_report.html` / `multiqc_data/` / `multiqc_plots/`; its title reads *yAMP complete-QC* and the Workflow Summary moves from second section to last (collapsed). A QC-only run no longer writes `yAMP-QC-only-run_multiqc_report*` (2026-09-24 → 09-28 outputs have it). Nothing read-, alignment-, variant- or dashboard-derived moves (e2e re-record 2026-09-29) |
| 2026-09-30 | Mutation report index rewrite + SNV / InDel events table (CHANGELOG *v1.1.0 → Added*) | **One new file only:** `mutation_reports/data/snv_indel_sites.csv` (deterministic, md5-pinned — every joint-call site with FILTER, SnpEff gene / effect / impact / HGVS, a `differs_between_samples` flag and per-sample GT / AD / DP / VAF). `mutation_reports/index.html` changes throughout (new header, cards, SNV / InDel section, copy-number tabs; name-only in the snapshot, it embeds the generation time); no other name or content moves; task count unchanged (155 on the test set). Older bundles lack the CSV and show the old index layout (e2e re-record 2026-09-30) |
| 2026-10-01 | `BUILD_CN_MATRIX` output published into `data/` instead of `data/cn_matrices/` (the index's chromosome copy-number CSV button was dead — CHANGELOG *v1.1.0 → Fixed*) | **Five paths move, content identical:** `mutation_reports/data/cn_matrices/cn_matrices/{cn_bins_continuous,cn_chr_summary_call,cn_chr_summary_germline,cn_segments_call,cn_segments_germline}.csv` → `mutation_reports/data/cn_matrices/<same name>` (the doubled directory is gone: 6 names out, 5 in; no md5 moves). These are five of the nine cohort deliverables — compare them by file name, not by path, against any older output including the reference baseline. `index.html` links the chromosome summary at the new path. Nothing else moves; task count unchanged (155 on the test set; e2e re-record 2026-10-01) |
| 2026-10-01 | `VARIANTFILTRATION_FALLBACK` runs on `biocontainers/gatk4:4.5.0.0`, the image of the other GATK steps, instead of the `gatk4_gcnvkernel` Wave image (GATK 4.6.2.0) — `SAREK_MODIFICATIONS.md` → `modules/nf-core/` PATCHED | **One versions line:** `VARIANTFILTRATION_FALLBACK: gatk4` reads `4.5.0.0` instead of `4.6.2.0` in `pipeline_info/nf_core_sarek_software_mqc_versions.yml` (and in MultiQC's software-versions table). The soft-filtered joint VCF and everything derived from it are **record-identical** — the snapshot's VCF digests did not move, and a direct comparison gave 100/100 identical records on the test set and 451/451 on the 4-sample pilot; only the `##GATKCommandLine=<ID=VariantFiltration,…>` header line names the other version. No name moves, task count unchanged (e2e re-record 2026-10-01: the versions line is the only delta) |
| 2026-11-09 | `manifest.version` `1.0.0` → `1.1.0` (release `v1.1.0`; no recipe or output change) | **One versions line:** the pipeline line reads `nnf-bright-biofoundry/ALE_Yeast: v1.1.0` instead of `v1.0.0` in `pipeline_info/nf_core_sarek_software_mqc_versions.yml` and in the MultiQC software-versions table (§2.6). No output name is added or removed |
| 2026-11-11 | The ottilie test profiles (`ottilie_test`, `_ci`, `_az`) give the reference as one GenBank (`genbank`) instead of `fasta` + `snpeff_cache` + `snpeff_db` + `report_gff3`; the contract test follows. Same genome, same reads, same recipe (CHANGELOG *Unreleased → Changed*; `genbank_reference_input.md` §7) | **14 new names:** `reference/S288C_R64_test/` (the directory, the GenBank, `.fa`, `.gff3`, `contig_manifest.csv`, `.snpeff_build.log`, `snpeff_cache/S288C_R64_test/` with its four files) and `reports/preflight/preflight_genbank_mqc.tsv`, `snpeff_build_mqc.tsv`; none removed. **Tasks 157 for 155**, and the versions manifest gains `GENBANK_REFERENCE` (python, biopython) and `SNPEFF_BUILD` (snpeff). **Annotation fields only, in every annotated VCF and what is derived from it:** the transcript id is a RefSeq accession (`NM_001180200.1` for `YDL140C_mRNA`) on all 100 cohort records; the first annotation names another gene or effect on 12 of 100 (NCBI's gene models against Ensembl's: dubious ORFs, tRNA genes, Ty ORFs, symbol against systematic name; listed in `genbank_noncoding_models.md`), so `mutation_reports/data/snv_indel_sites.csv` differs in 12 rows, the eight `reports/snpeff/**/*_snpEff.genes.txt` differ, and eight of the nine report tables differ in the gene, transcript, effect and HGVS columns. **Identical:** the cohort VCF's 100 sites, FILTER and genotypes (records compared with `ANN`, `LOF`, `NMD` stripped), the four truth SNVs' gene, effect and protein change, every CN and SV cohort CSV. **Input checks:** `preflight_reference_mqc.tsv` reads *all 4 contig name(s)* for the GFF3 row (the gene track is derived from the same four records) and SKIPPED for the cache row; the MultiQC input-checks table has ten rows for six. **Not in any hash but different:** the CRAM read groups' `DS:` names the GenBank file, the IGV gene track is the derived GFF3 (gene, mRNA, exon, CDS of the four contigs) instead of Ensembl's full-genome file, the index page's legend says *the GenBank reference marks no contig as an organelle or a plasmid*. The build log's content is run-dependent (work directory, timings): name only. A run older than this date compared with a newer one shows all of the above; to reproduce the older outputs run the test set with `-params-file tests/qc_gate_prebuilt_params.yml` |
| 2026-11-11 | **Test data `ottilie/v2`**: the test set is a new cut (SRA reads, contigs I, IV, VII, XV + Mito, a seeded 0.67 of the pairs: about 30x parent, 60x evolved; `DATA_PROVENANCE.md`). Same samples, same recipe, another input | **Every read-derived file differs from any output on `ottilie/v1`; they are not comparable file by file.** Names: none added or removed (1,029 on the contract test), tasks 157 = 157, versions manifest unchanged. Content: 129 of the snapshot's 154 file hashes move (the 25 that stay: CNVKit call statistics, antitarget files, MultiQC constants, the samplesheet input-check table, one snpEff bin); cohort VCF 101 records (86 nuclear, 15 Mito) for 100; `snv_indel_sites.csv` 103 rows for 100; SV PASS table 45 rows (12 nuclear, 33 Mito) for 13; the CN tables gain no Mito row (CNVKit's GC mask), `contig_copy_number.csv` gains one; `reference/S288C_R64_test/` holds five contigs and a `codonTable` line in the database's `snpEff.config`. Compare a run of `main` with the 2026-11-11 contract-test snapshot or a later Platform run on v2, and a `v1.1.0` run with the baselines above |

### 2.11 MultiQC's SnpEff breakdown tables — the categories of whichever report was parsed last

`multiqc/multiqc_data/snpeff_effects.txt` and `snpeff_variant_effects_region.txt` (and the plots built
from them) list a **different set of effect categories** depending on the run: 8 columns on the local
e2e (a HaplotypeCaller report's effect types), 14 on the 2026-09-08 Platform run (a Manta report's), 9
standalone (TIDDIT's) — from **identical** SnpEff summary CSVs. Cause (MultiQC 1.25.1; unchanged in
kind on 1.35 — re-verified at the 2026-09-24 bump on the same staged inputs: still one report's
categories, not the union, but a *different* report is last — 1.25.1 listed a HaplotypeCaller report's
8 effect types, 1.35 lists an SV report's 9; `modules/snpeff/snpeff.py` `parse_snpeff_log`):
the module does
`self.snpeff_section_totals[section] = dict()` **every time a file reaches a section header**, so the
totals that drive the category list are those of the *last file parsed*, and file order follows the
filesystem (ext4 locally, the Batch node's staged directory on Platform). It is **deterministic per
filesystem** (the exact local task re-run twice is byte-identical) and different across them; the cells
for shared categories agree exactly, and the general SnpEff table (`multiqc_snpeff.txt`) is
cell-identical. Not a pipeline defect and not a deliverable; excluded from the e2e snapshot. Upstream
report pending (roadmap). Verified 2026-09-09 on the re-cut comparison.

### 2.12 MultiQC 1.35 log noise — `mqc_colour` lines

`multiqc/multiqc_data/multiqc.log` (and the task's stderr) on 1.35 carries 96 lines of
`mqc_colour | Error converting color '55,126,184' to RGB: input #55,126,184 is not in #RRGGBB format`
(eight distinct RGB triplets). MultiQC-internal — the same lines appear with `assets/multiqc_config.yml`
removed (measured 2026-09-23) — and the report, its tables and the exit code are unaffected. Not ours
to fix; do not chase them when reading a log.

---

## 3. Method: comparing two runs directly

Three tiers, cheapest first. Do not skip to hashing everything — most differences are explained at
tier 1 or 2.

### Tier 1 — names

Which files exist on each side. Catches missing outputs, the failure that matters most.

```bash
az storage blob list -c <container> --prefix <run>/ --account-name <acct> --auth-mode login \
  --num-results 10000 --query "[].{n:name,s:properties.contentLength}" -o json > run.json
```

Then set-difference the names. Expect differences only in `pipeline_info/` (§2.7). **Anything else
present on one side only is a real finding.**

### Tier 2 — sizes

`contentLength` is free (already in the listing) and rules out most files without downloading anything.
Equal size is not proof of equality, but **different size is proof of difference** — and the *magnitude*
of the delta usually identifies the class (1–7 bytes → §2.2; tens of KB on a PDF → §2.4).

### Tier 3 — hashes, on the files that must be identical

Download only the deliverables from §1 and `md5sum` them.

> ⚠️ **`contentMd5` is NOT populated on blobs published by Nextflow** — verified 0/534. Azure stores it
> only when the uploader supplies it, and Nextflow's publish path does not. Any comparison plan built on
> "read `Content-MD5` from the blob listing" **will silently compare nothing**: every value is `null`,
> so a naive equality test reports zero differences. Download and hash instead.

### The failure mode to design against

A check that asserts on **exit status** rather than on **content** produces false confidence. This has
already happened here once: a staging test passed because the command exited 0 while zero files had
actually arrived. **Assert on what landed** — counts, sizes, hashes — never on the exit code alone.

---

## 4. Implications for nf-test design

- **Snapshot the deliverables, ignore the renders.** [`tests/.nftignore`](../../tests/.nftignore) already
  excludes `multiqc/multiqc_plots/**`, `pipeline_info/*`, `csv/*.csv`, `annotation/**/*.vcf.gz` and the
  rest of the classes above. This page is the *why* behind those entries — consult it before adding or
  removing one.
- **Prefer content assertions over byte snapshots** for anything in §2. Assert on variant counts, on
  parsed CSV values, on `tableJson` — not on file bytes.
- **A new ignore entry needs a stated cause.** If you cannot name which class in §2 it belongs to, the
  difference is probably a real bug, and ignoring it hides the bug permanently.
- **Review the `.snap` diff as source code.** `--update-snapshot` re-records *every* failing snapshot,
  so a genuine regression sitting next to an intended change is silently blessed. See
  [`testing_best_practices.md` §10](testing_best_practices.md).

---

## 5. Open item

Everything above is done by hand. A run-comparison helper implementing tiers 1–3 with the
normalisations in §2 would make cloud-vs-local comparison repeatable rather than a one-off. **No such
script exists yet** — deliberately not referenced by path here, so nothing points at a file that isn't
there. Until it is written, budget an hour and follow this page.
