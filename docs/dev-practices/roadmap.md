# ALE pipeline roadmap (post-v1.0.0 future work)

Ad-hoc future-work items migrated from the old `TODO.md` at v1.0.0. Priorities are `[high|med|low]`.
Full project history lives in `git log` and `CHANGELOG.md`; resolved items are summarized at the bottom.

> For the **test-coverage** target (the four nf-test layers over our custom code, ploidy 1/2/3
> scenarios, per-custom-module tests), see `testing_best_practices.md` §11 — the target lives there
> and is not duplicated here. This file carries only the prioritized *scheduling* item for it
> (under Robustness / infrastructure).

---

## Read preprocessing — FASTQ QC & trimming

> Full audit, Trimmomatic design and the four integration blockers:
> [`fastq_preprocessing_audit.md`](fastq_preprocessing_audit.md). Everything here defaults to **off** —
> the Azure baseline at `az://aletest/ottilie-azurebatch-out/` was produced with no trimming at all,
> so any change that alters the reads reaching bwa-mem invalidates byte-comparison against it.

- ~~**[med] Expose fastp quality trimming.**~~ **Done 2026-09-02** (audit doc §2; user page
  `docs/usage/read_preprocessing.md`): four steps — `trim_adapter` (alias `trim_fastq`) +
  `adapter_sequence[_r2]`, `trim_quality_3prime tail|right` + `trim_quality_5prime` + shared mean/window,
  `filter_quality` (on, as upstream) + thresholds; gate extended; poly-G auto-detection off unless
  `trim_nextseq`. Defaults unchanged; recommended opt-in recipe `--trim_adapter --trim_quality_3prime tail`.
  **Default since 2026-09-04**; Azure baseline re-cut + 4-sample pilot re-check pending (Seqera comparison).
- **[med] Add Trimmomatic as an alternative trimmer (`--trimmer fastp|trimmomatic`).** Requested by the
  team for parity with their existing setup. The nf-core module exists but four things collide with a
  sarek 3.5.1 fork: its versions come via a **topic channel**, not `versions.yml`, so it would be absent
  from provenance; it has **no adapter-FASTA input**, so `ILLUMINACLIP` cannot stage a file on Azure
  Batch; **fastp is also the FASTQ splitter**, which Trimmomatic cannot replace; and Trimmomatic applies
  steps in command-line order while the module puts `ext.args2` first. Wrap the choice in a local
  `subworkflows/local/fastq_trim/` so `workflows/sarek/main.nf` (already the heaviest rebase surface —
  see `SAREK_MODIFICATIONS.md`) gains one include and one call. **Settle first whether this is a
  production option or a one-off benchmark** — see the doc's open decisions.
- **[low] Preprocessing audit defects.** (a) and (b) closed 2026-09-02 with the trimming design
  (`trim_nextseq` texts fixed and it now also disables fastp's auto-detection at 0; split-only runs are a
  pure splitter). Remaining: (c) `save_trimmed_fail` is hardcoded `false` at `workflows/sarek/main.nf`,
  so reads dropped by `filter_quality`/`length_required` can't be inspected.
- ~~**[med] No test coverage of the preprocessing path.**~~ **Done 2026-09-02**:
  `tests/fastp_preprocessing.nf.test` runs the real `FASTP` module under `conf/modules/trimming.config`
  on a committed 1 000-pair fixture — one case per preprocessing step (adapter, alias, poly-G, quality
  both ends, filter off, filter thresholds, split-only), exact counts pinned. The `ottilie_e2e` route
  runs with the default recipe (`--trim_adapter --trim_quality_3prime tail`) since 2026-09-04.

## Variant calling — HaplotypeCaller

- **[low] Rename `SPLIT_JOINT_VCF` → `SPLIT_HAPLOTYPECALLER_JOINT_VCF`** (cosmetic). The subworkflow
  (`subworkflows/local/split_joint_vcf/`, workflow `SPLIT_JOINT_VCF`) is HaplotypeCaller-specific but
  named generically. A rename touches the dir, the workflow name, the imports in
  `bam_variant_calling_germline_all/main.nf`, and the schema doc — defer unless already editing the area.
- **[med] Joint-germline filter strategy + flag fixed / convergent mutations.** Refine the soft-filter
  thresholds on the joint HC VCF (`VARIANTFILTRATION_FALLBACK`, `conf/modules/joint_germline.config`) and
  add flags for *fixed* (≈100% AF) and *convergent* (recurrent across independent lineages) mutations —
  the key selective signals in an ALE experiment. Evidence now exists for the retune: on Ottilie Tier 2
  only **4 of the 9 declared filters ever fire** (MQ/SOR/QD/FS); the other five tag nothing. Handle
  `QUAL_filter` separately — it is redundant *by construction*, not by threshold (GenotypeGVCFs'
  default `-stand-call-conf 30` already removes everything it targets; observed min QUAL 30.14), so it
  should be dropped or re-tied to `stand-call-conf` rather than retuned. Per-filter counts and the
  RankSum annotation-coverage gap: `docs/variant-calling/haplotypecaller/SOFT_FILTER_HAPLOTYPECALLER_JOINT.md`.

## Variant calling — Mutect2 (Tier 2)

- **[med] Rename filtered VCF → `filter_annotated`.** `conf/modules/mutect2.config:48` uses
  `ext.prefix = {"${meta.id}.mutect2.filtered"}`; rename to `…mutect2.filter_annotated` for consistency
  with HaplotypeCaller's `…_soft_filtered` (both are soft filters that annotate FILTER, not remove).
  Check downstream refs + docs after renaming.
- **[med] Yeast-tuned Mutect2 params.** With no germline resource (custom yeast genome), consider adding
  to `conf/modules/mutect2.config`: `--max-population-af 1.0` (allow any AF — important for evolution),
  `--af-of-alleles-not-in-resource 1/(ploidy·N)`, `--initial-tumor-lod 0.5–1.0` (catch low-freq early),
  `--downsampling-stride 1` (small genome). See the GATK Mutect2 docs. Investigation-heavy — validate on
  the benchmark set.
- **[low] More stringent Mutect2 filtering options.** Mutect2 yields ~30% more variants than FreeBayes;
  TLOD/AF-difference/depth thresholds could tighten. Deprioritized — the ALE strategy keeps more calls
  and ranks for fixed/convergent rather than hard-pruning.

## Variant calling — FreeBayes (Tier 2)

- **[med] Joint FreeBayes population calling.** Add a `--joint_freebayes` param + a
  `subworkflows/local/bam_joint_calling_freebayes/` (bcftools merge of individual germline VCFs), mirroring
  the HaplotypeCaller joint pattern in `bam_variant_calling_germline_all/main.nf`. Filter individuals
  first, then merge, so allele frequencies are population-correct.
- ~~**[med] FreeBayes AF miscalculation for multi-allelic sites (real bug).**~~ **Moot 2026-09-09:** the
  filter subworkflow was removed (archived at tag `tier2-tools-archive`, `docs/archive/tier2/`). Kept as a
  note for anyone restoring it: After `bcftools norm -m-`
  splits a multi-allelic record, `AO` is split per row but `RO` is not, so `AF = AO/(AO+RO)` uses a wrong
  denominator. Fix: compute `AF = sum(AO)/(sum(AO)+RO)` **before** splitting, then split. See
  `subworkflows/local/vcf_filter_freebayes/`.
- **[low] FreeBayes population table / single-VCF report.** Aggregate all samples' FreeBayes output into
  one population VCF/table for cross-sample comparison.

## CNV — Control-FREEC (Tier 2) / CNVKit

- **[low] Control-FREEC yeast `cf_window` tuning.** `nextflow.config` sets `cf_window = null` (auto). Tune
  `window` / `breakpointthreshold` for small yeast chromosomes. Coupled with the ploidy=1 item below.
- ~~**[low] Investigate ASSESS_SIGNIFICANCE skip for ploidy=1.**~~ **Moot 2026-09-09:** the Control-FREEC
  germline mode and the ploidy-1 skip were reverted to pristine sarek 3.5.1 (archived at tag
  `tier2-tools-archive`, `docs/archive/tier2/`). The `cf_window` item above is likewise dormant. Was: `conf/modules/controlfreec.config:19` skips
  it for haploid samples (Control-FREEC emits empty `*_CNVs`, R script fails). Determine whether this is
  inherent (no gain/loss relative to a haploid baseline) or a window/config issue that yeast-tuned
  parameters would resolve.

## CNV — contig-level copy number and the mitochondrial genome

- **[done 2026-08-27] Surface per-contig copy number in the report** — `BUILD_CONTIG_CN` +
  `bin/contig_copy_number.py` → `data/contig_copy_number.csv` (ratio = TIDDIT Ploidy ÷ samplesheet n)
  and a "Contig Copy Number" table + Methods entry in `index.html`. Original note: TIDDIT
  `<sample>.tiddit.ploidies.tab` — `Ploidy`/`Mean_coverage` per contig. Found
  2026-08-27: the pilot's one unmatched truth event (`Doxorubicin16-R2b Mito:53278`) is a
  whole-mtDNA loss (TIDDIT ploidy 10.1 → 0.34) plus an intra-Mito depletion/amplification — a
  coverage-only event with **no mappable breakpoints** (the clip pile-ups are Nextera adapter
  read-through), so no SV caller can ever report it, while the number that shows it is already
  computed and never displayed. The same table shows the chr I duplication (1.28) at a glance.
  Details: `docs/benchmarking/ottilie_xenobiotic_ale/04_validate/pilot_results_v2/NOTES.md`.
- **[low] CNVKit excludes the mitochondrial contig by design** — `cnvlib/params.py` GC mask
  0.30–0.70, not overridable; yeast mtDNA is 17 % GC, so all 17 Mito bins are dropped at `fix` in
  every sample. Options: a dedicated per-kb mtDNA depth-ratio track in the report, or a patched
  `params.py` in a custom container (not recommended). Do not expect CNVKit output for `Mito`.
- **[low] `delly cnv` as a second read-depth CNV opinion** (companion to the Delly SV item under
  SV below). Segments with per-sample `FORMAT/CN`, emitted as `SVTYPE=CNV` BCF — it belongs beside
  `cn_segments_*.csv` / `cn_cohort_matrix.csv` (BCF → the same segment schema), **not** in the SV
  merge. Needs a mappability map for the custom yeast genome (a prep step like the SnpEff cache);
  can take Delly's own SV BCF (`-l`) to refine breakpoints. Check before relying on it for Mito:
  whether its GC correction keeps the ~17 % GC contig (CNVKit's does not), and whether its
  baseline-ploidy option honours `meta.ploidy` — that would make it the first CNV tool here to do so.

## SV — Manta + TIDDIT → SURVIVOR → cohort matrix

- **[medium] Replace the SURVIVOR merge chain, raredisease-style: joint Manta → SVDB — DONE 2026-08-31.**
  Step 1 (joint Manta + split) landed 2026-08-28; step 2 (SVDB replaces SURVIVOR) landed 2026-08-31 in
  two commits: the chain wired additively (`0bc42a9`, with the SVDB-vs-Jasmine bench committed at
  `04_validate/sv_merge_bench/` — SVDB chosen over Jasmine, which drops FORMAT/FT and mangles types),
  then the matrix rewrite + SURVIVOR retirement. Final recipe (all deviations from the raredisease
  blueprint bench-verified): `convertInversion` → breakend-pair collapse in EVERY input (svdb merges
  raw mate pairs asymmetrically) → svdb across samples → svdb `--no_intra --same_order
  --bnd_distance 2000 --priority manta,tiddit` across callers; PASS view by input pre-filtering
  (`--pass_only` does NOT drop non-PASS records); sample-column guard (`--same_order` trusts
  positions, not names). Mechanics: `docs/variant-calling/sv_merge.md`. Original decision record
  follows. Decided
  2026-08-27 after reviewing upstream: Sarek 3.10.0/dev has no joint germline Manta and uses SVDB only
  for somatic TIDDIT; **nf-core/raredisease** is the blueprint — one joint Manta run per case, TIDDIT
  per sample merged across samples with `SVDB_MERGE --same_order`, then `SVDB_MERGE --pass_only
  --priority <caller,...>` across callers. SVDB is type-strict by default, `--no_intra` forbids
  within-file clustering (the swallowing trigger), matching is reciprocal overlap / `--bnd_distance`,
  provenance lands in `INFO/set`+`VARID`, and the module is already in this repo (used by the somatic
  TIDDIT path). This supersedes the PSV / per-type-merge plan below. Do it in two steps:
  - **Step 1 — joint Manta + per-sample split — DONE 2026-08-28** (`dfe266b` `--joint_manta`, upstream-shaped
    per-patient grouping; `b9d4f42` per-sample split with hom-ref drop + `FT`→`FILTER`; on in the ottilie
    profiles). **Not yet the settled ALE default — see the loss audit below.** Original plan follows.
  - **Step 1 (plan) — joint Manta + per-sample split (~1 day).** The nf-core `manta/germline` module already
    accepts a CRAM list (`input.collect{"--bam ${it}"}`); only `bam_variant_calling_germline_manta`
    feeds it one sample. Mirror the HC joint pattern (`id:'joint_sv_calling', patient:'all_samples'`),
    then generalise `SPLIT_JOINT_VCF` to emit per-sample Manta VCFs so every downstream consumer is
    unchanged. **Spike 2026-08-27 on the 2-sample test CRAMs (19 s):** 18 records, all PASS, all 14
    breakends mate-paired, every per-sample call recovered, no sample-specific event (consistent with
    the truth set). Joint genotyping recovered the ADH1↔AUS1 inversion in CBR110-15-R3a as `0/1` with
    8 supporting pairs — per-sample Manta had not called it there — so presence/absence becomes a
    genotype with evidence rather than a merge miss. Haploid samples genotype `1/1` for clean events
    (XV:722249 DEL, VII:530034 INS) and `0/1` for the cassette-junction breakends (ref reads present
    at ADH1); treat GT as presence/absence, not zygosity. Coordinates are re-estimated from pooled
    reads (e.g. 349,748 → 349,693), identical across samples by construction.
  - **Step 1b — joint Manta calling configuration — DECIDED 2026-08-28: keep Manta's defaults; expose
    the alternative as `--manta_high_sensitivity` (default false: `--exome` + `graphNodeMaxEdgeCount=0`).**
    Rationale: joint calling's noise reduction is wanted (same experience as HC joint); at the PASS level
    the defaults cost one shared background insertion, one cassette junction and two 8-pair breakends;
    the switch is there for datasets where an amplified-region junction is the hypothesis. Original notes: Loss audit on the
    4-sample pilot (`04_validate/pilot_results_v2/NOTES.md` → "Joint Manta vs per-sample Manta";
    `run_manta_joint_audit_pilot.sh <MODE>`): at Manta defaults the joint run drops the strongest
    junctions in the data (the `MaxDepth`-tagged ADH1-cassette breakends, 170–505 split reads — Manta's
    pooled-depth discovery skip, `maxDepthFactor`, only switchable via `--exome`) and a shared 343-bp
    insertion (`graphNodeMaxEdgeCount = 10`, the ADH1 hub has 15 partners). With `--exome` +
    `graphNodeMaxEdgeCount = 30` (≡ 0 on the pilot; Manta config ini via the module's unused `config` input) 57/62
    per-sample PASS records are found, 4 events lost (one strong, Doxorubicin-only, 4× depth), and the
    parent's whole engineered background becomes visible (per-sample Manta had hidden it — NODRUG had 8
    records). Options: (a) adopt both settings for the joint run, drop per-sample Manta — recommended;
    (b) (a) plus keep a per-sample run as a union safety net; (c) `--exome` for per-sample calling too.
    Any of them is a calling-parameter change: pilot truth-set validation + snapshot re-record as its own
    commit. Also worth carrying into the SVDB rewrite: per-sample PR/SR (or AF) into the long-format SV
    table — the matrix cell `Manta` hides a 20 % vs 100 % allele fraction.
  - **Priority order — DECIDED 2026-08-28: `--priority manta,tiddit`** (raredisease puts tiddit first).
    SVDB's first-listed tag wins: the merged record keeps that caller's POS/END/SVTYPE, the other
    caller's coordinates surviving in `INFO/<tag>_POS`/`_INFO` (verified in the spike). Manta first
    because its breakpoints are split-read derived and precise where TIDDIT's are depth/pair-derived
    ranges — worked example, the same XV DEL in the 2-sample set: Manta `722249-722439`
    (`CIGAR=1M190D`, `HOMLEN=7`), TIDDIT `722257-722440` (`REGIONA=722180,722257`,
    `REGIONB=722440,722517`). SURVIVOR's "last file wins" rule put TIDDIT's `722257` in today's
    matrix; under this order the matrix will show Manta's. With Delly later the order becomes
    `manta,delly,tiddit` (Delly is also split-read/paired-end, TIDDIT stays last).
  - **Step 2 — SVDB for TIDDIT-across-samples and Manta+TIDDIT (report side).** Retires
    `SURVIVOR_SV_MERGE`, `SURVIVOR_COHORT_MERGE`, `proximity_match`/`MAX_DIST` and most of
    `sv_cohort_matrix.py` (becomes a parse of `INFO/set` + FORMAT/GT). Spike first: `svdb --merge
    --no_intra --priority manta,tiddit` on the current raw VCFs; confirm the XV:722 kb DEL survives as
    DEL in both samples and read the emitted tags. Jasmine (`jasminesv` module exists) is the
    fallback merger if SVDB disappoints.
- **[superseded by the above — kept for context] Derive SV-matrix cells from the cohort VCF's `PSV` instead of `proximity_match`.**
  Found 2026-08-26: SURVIVOR (`take_type=1` notwithstanding) can fold a PASS deletion into a
  breakend-derived INV/TRA cluster seeded by a junk non-PASS breakend within `max_dist`; the
  matrix's svtype check then blanks that sample (`union` mode on ottilie, chr XV ~722 kb — CBR110's
  two-caller, 112-split-read DEL shows `-`). The cohort VCF already carries the answer per sample
  (`PSV` = caller vector, plus `TY`/`CO`/`ID`/`QV`), so cells can be decoded directly, retiring the
  proximity heuristic and its 1 kb gate. Pair with a long-format companion CSV (event × sample ×
  caller, with each caller's own breakpoints from the per-sample VCF `CO`) so per-caller coordinates
  are exported — today the CSV shows only SURVIVOR's representative record. Decide at the same time
  whether raw `union` mode should drop non-PASS breakends first or be retired. Worked example +
  options: `docs/variant-calling/sv_merge.md` § "Known issue — revisit". Schema change → e2e snapshot
  re-record.
- **[low] Collapse Manta breakend pairs (TRA/INV) into one matrix row** with a `breakend_pair`
  flag; today each such event occupies two mirror rows (documented in the report Methodology).
- **[low] Delly SV (`delly call`) as a third caller — keep the SVDB refactor Delly-ready.** Delly's
  germline recipe (call per sample → `delly merge` sites → re-genotype every sample at the merged
  sites with `-v` → `bcftools merge` → `delly filter -f germline`) already yields a cohort BCF with
  every sample genotyped at every candidate, i.e. the same property joint Manta buys. It genotypes
  with a diploid model (no ploidy flag) and carries per-sample `FORMAT/FT` — exactly the two rules
  the generalised Manta split needs (hard-coded `0/0`+`./.` hom-ref pattern, FT → FILTER). Two
  choices to make *while* doing the SVDB refactor so Delly later is a config entry, not a rewrite:
  key the split rules on `meta.variantcaller` / `ext.args` rather than on "manta"; and group N
  callers into `SVDB_MERGE --priority manta,delly,tiddit` via a caller list instead of the current
  Manta+TIDDIT `join` by `meta.id`. Whatever grouping is chosen for joint Manta (per `experiment`
  vs all samples) applies unchanged to Delly's merge/genotype step. With three callers, the TIDDIT
  sensitivity question gains a majority-vote option on the `INFO/set` count. Spike items: BCF →
  VCF before SVDB; confirm SVDB parses Delly's BND representation (`CHR2`/`POS2` + breakend ALT);
  check `delly filter -f germline`'s cohort thresholds (fraction genotyped, alt-AF — tuned for human
  cohorts) on a 2–4 sample ALE cohort. nf-core ships `delly/call` (with the `-v` sites input);
  `merge`/`filter`/`cnv`/`classify` would be local modules on the same biocontainer.
- **[low] Cohort all-class mutation table (CSV, deliberately not a VCF).** One cohort object holding
  SNV/INDEL + SV + CNV per sample is what ALE work actually consumes — breseq's genome-diff
  (`gdtools COMPARE`) and ALEdb-style mutation tables hold every class in one record type. Decided
  2026-08-27: deliver this as a table, not a merged VCF. An all-class multi-sample VCF is spec-valid
  and has precedent (1000 Genomes phase 3 integrated set; GATK-SV's SV+CNV cohort VCF), but SNV+SV
  in one file is rare in practice — incompatible INFO/FORMAT schemas (`AD/DP/PL` vs
  `PR/SR/END/CIPOS`), header clashes on `bcftools concat -a`, and class-specific filtering/annotation
  — so per-class cohort VCFs stay the machine-readable deliverable (joint HC exists; SVDB cohort
  arrives with the SV refactor; CNVKit has `cnvkit.py export vcf` if ever needed). The table is a
  long-format union of the existing per-class cohort matrices (event × sample × class × caller ×
  evidence) once SV and SNV share identical sample columns — i.e. after joint Manta + SVDB. One
  substantive rule to settle: small indels (~8–50 bp) can appear in both HaplotypeCaller and Manta,
  so the union needs a dedup/precedence rule or it double-counts.

## Robustness / infrastructure

- **[low, breseq held] breseq receives untrimmed reads under the default recipe.** Found 2026-09-24
  while gating breseq for `--qc_only`: `reads_for_breseq` in `workflows/sarek/main.nf` tests the
  deprecated `trim_fastq` (and `split_fastq`), not the fastp gate (`trim_adapter || trim_quality_*`),
  so with today's defaults breseq gets `reads_for_fastp` — the raw reads — despite the "trimmed
  FASTQs" comment. Harmless while breseq is held (AMP-v1 merger question in CLAUDE.md); fix = test the
  same condition as the fastp block, validated by a breseq run (no test covers breseq today).
- **[med] Preflight, second tranche** (cut from the 2026-09-23 minimal version, design in the
  QC-first plan): an always-written MultiQC custom-content table of the `[yAMP preflight]` lines
  ("0 deviations" when clean); further warnings — `status = 1`, ploidy > 2 (vcftools skipped),
  `wes`, custom `intervals` / `no_intervals`, `aligner != bwa-mem`; schema-overlay `exists` on
  `dict`, `intervals`, `report_gff3`. Unverified and therefore not implemented: an error for
  `sample == experiment` or names unsafe as `@RG SM` (no measured failure).

- **[med] `generate_mutation_report.nf` CRAM suffixes are wrong for 2 of 3 preprocessing layouts.**
  The standalone launcher rebuilds channels by *discovering published files*, so it hard-codes the
  publish directory and filename suffix. Only the branch ALE actually uses is correct:

  | `cram_subdir` | Sarek publishes | launcher expects | |
  |---|---|---|---|
  | `mapped` | `<id>.sorted.cram` (`BAM_TO_CRAM_MAPPING`, `conf/modules/markduplicates.config`) | `.cram` | ❌ |
  | `markduplicates` | `<id>.md.cram` | `.md.cram` | ✅ (the ALE path) |
  | `recalibrated` | `<id>.recal.cram` (`conf/modules/recalibrate.config`) | `.cram` | ❌ |

  Harmless today — every ALE run sets `skip_tools = 'baserecalibrator'` (mandatory: no known-sites
  VCFs for the custom genome), so only the middle branch is reachable. It becomes a **silent**
  failure the moment BQSR is enabled or markduplicates skipped: the glob matches nothing, so IGV
  alignment tracks vanish from the reports with no error. Fix the `cram_suffix` map alongside any
  work that enables BQSR. **The inline path (`workflows/sarek/main.nf`) is unaffected** — it passes
  `cram_variant_calling`, which Sarek points at the right CRAMs for any preprocessing configuration
  (`workflows/sarek/main.nf` ~L586-644). Warning comment is in the launcher at the branch itself.
- **[med, only if restarts become supported] Starting from a later step via `<outdir>/csv/*.csv` loses
  the ALE samplesheet columns.** Upstream sarek publishes restart samplesheets (`csv/mapped.csv`,
  `csv/markduplicates_no_table.csv`, …) for `--step markduplicates|variant_calling|annotate`. The fork
  never adapted that path, and nothing exercises it (no launcher, test or benchmark passes `--step` or
  a `csv/` input). *Measured* 2026-09-15 by parsing the ottilie test run's own
  `csv/markduplicates_no_table.csv` through `assets/schema_input.json` (nf-schema 2.2.1, Nextflow
  25.10.4): every sample comes back as `patient:[]`, `ploidy:2`, `clonal_or_population:clonal`, where the
  original samplesheet gives `patient:Ottilie_test`, `ploidy:1`. Two independent causes:
  1. **Schema** — `experiment` is declared with `"meta": ["patient"]` *after* `patient`
     (`assets/schema_input.json`); nf-schema writes `[]` for an absent column, so a sheet with a
     `patient` header (upstream's convention and what the writers emit) loses its grouping key. Renaming
     the header to `experiment` restores it (*measured*). The `experiment → patient` remap in
     `subworkflows/local/utils_nfcore_sarek_pipeline/main.nf` never fires — no `meta.experiment` key
     exists.
  2. **Writers** — the five `subworkflows/local/channel_*_create_csv` are pristine upstream and write
     `patient,sex,status,sample,…`; `ploidy` and `clonal_or_population` fall back to the schema defaults.
     Ploidy 2 then reaches HaplotypeCaller (`--sample-ploidy`), TIDDIT (`-n`), the split-joint-VCF
     non-ref filter and the contig copy-number table (*inferred* from the consumers; no restart run was
     made). `clonal_or_population` is inert on the Tier-1 recipe (only the opt-in joint hard filter and
     breseq read it).
  **Not a problem for `-resume`**, which re-reads the original samplesheet and only reuses cached tasks.
  Fix when wanted: give `experiment` its own meta key so the remap becomes live and `patient` headers
  keep working; make the writers emit `experiment,…,ploidy,clonal_or_population`; add a parse-level
  nf-test (original sheet, `patient`-header sheet, pipeline-written restart CSV); e2e re-record (CSV
  contents change) plus one `--step variant_calling` run compared record-for-record with the one-shot
  joint VCF; list `assets/schema_input.json`, the remap and the five writers in
  [`SAREK_MODIFICATIONS.md`](SAREK_MODIFICATIONS.md). Until then a user who restarts from these CSVs
  must add the `experiment`, `ploidy` and `clonal_or_population` columns by hand.
  *Cause of (1) confirmed 2026-09-21 (measured):* nf-schema fills `meta` in declaration order and
  writes `[]` for an absent column, so of the two properties sharing `"meta": ["patient"]` the last
  declared wins — swapping them in a scratch copy of the schema flips which header works. The fix is
  one meta key on `experiment`, not a search-and-replace of `patient` through the code.
- **[med] `PREFLIGHT_SNPEFF` — functional check of the snpEff cache before annotation.** Parked
  2026-09-21 when the reference preflight for the QC-first run was cut down to contig names;
  `PREFLIGHT_REFERENCE` shipped 2026-09-28 with that one check (FASTA vs `report_gff3` contig names,
  gawk only — `docs/usage/preflight_checks.md`). The cache is a binary file, so its contig
  namespace cannot be compared cheaply, and a cache built with a different snpEff version fails only
  at annotation time — or annotates nothing, silently, on a contig mismatch. Design: a task in the
  pinned snpEff 5.1 container asserts `<cache>/<snpeff_db>/snpEffectPredictor.bin` exists (this also
  closes the cloud-path gap in `annotation_cache_initialisation`, since `az://` is staged inside a
  task), builds a one-record-per-contig VCF from the FASTA headers, runs
  `snpEff -dataDir … -noStats -noLog <db>` and greps for `ERROR_CHROMOSOME_NOT_FOUND`. Severity:
  **error when no contig is found, warn + list when some are missing** (engineered strains carry
  extra contigs legitimately — same rule as `build_snpeff_cache.sh`). Wiring rules as for
  `PREFLIGHT_REFERENCE`: not an input to anything downstream (no task-hash change),
  `errorStrategy = 'terminate'` in its own config block, its own MultiQC custom-content row, and added
  to the `--qc_only` allow-list test. Skipped when `snpeff` is not in `tools`.
- **[low] More reference preflight checks — one row each in `PREFLIGHT_REFERENCE`'s table.** Decided
  2026-09-28: ship the one check that is silent today, add the rest as real input errors show up. Each
  candidate is a function in `bin/preflight_reference.sh`, a verdict row and a fixture pair under
  `tests/fixtures/preflight_reference/`: FASTA syntax (duplicate or empty header names, CRLF line
  endings, empty sequences — today these fail in reference preparation within minutes, less clearly);
  a user-supplied `--fasta_fai` / `--dict` against the FASTA (names and lengths — today a stale one fails
  inside GATK after alignment, or silently restricts calling when it lists a subset of the contigs);
  a partial naming mismatch (`Mito` vs `chrM` with the chromosomes matching) or FASTA contigs without
  annotation — today visible only as the note in the OK row, since a GFF3 with more contigs than the
  FASTA is the test set's own situation and must stay quiet.
- **[low] `generate_mutation_report.nf` has no automated test coverage.** `tests/ottilie_e2e.nf.test`
  runs `main.nf` (the inline, channel-based path); nothing under `tests/` exercises the standalone
  launcher. Its *whole* risk surface is filesystem-layout assumptions — the CRAM suffixes above plus
  the annotated-vs-raw VCF suffix map (`sfx`) — which is exactly the class of bug an e2e on the
  inline path cannot catch. Belongs with the per-module test work in the test-coverage target
  ([`testing_best_practices.md`](testing_best_practices.md) §11).
- **[med] Better exception handling in `samplesheet_to_channel`.** The bare
  `input_sample.filter{…}.ifEmpty{ error(…) }` at
  `subworkflows/local/samplesheet_to_channel/main.nf:146-166` surfaces a misleading "sample-sheet only
  contains normal-samples" error when the *real* cause is an upstream schema/config failure. Wrap with a
  contextual error (Option 3 in the diagnostic guide). **The debugging guide is preserved at
  [`troubleshooting.md`](troubleshooting.md).**
- **[low] Sample-table "starting strain" column.** Add a column naming the ancestral strain per sample;
  test that one ancestral name (e.g. `A0-F0-I1-R1`) can map to multiple samples across different
  experiments.
- **[low] Seqera launchpad schema polish.** ~~Drop `cf_ploidy` from `params_seqera_test.yml`~~ (file removed 2026-09-09; the generated Launchpad box has no `cf_*`) (schema default
  is 2 and it's ignored at runtime — ploidy comes from the sample table); set `"hidden": true` in
  `nextflow_schema.json` for `ascat_ploidy`, `ascat_purity`, `cf_window` (not used for yeast).
- **[low] SURVIVOR SV-merge input-sort guard.** `modules/local/survivor_sv_merge` and
  `survivor_cohort_merge` assume coordinate-sorted Manta/TIDDIT input but don't enforce it — the POSIX
  `sort` runs *after* `SURVIVOR merge`, so an unsorted input could silently produce a bad merge. Add a
  sort/validation before the merge. (Found in the SV-merge code audit.)
- **[med, post-1.0.0] Build out nf-test coverage over custom code (all four layers).** v1.0.0 ships two
  owned tests (`ottilie_e2e` pipeline + `split_joint_vcf` subworkflow); the 19 `modules/local/` and the
  other custom subworkflows have no isolated coverage, so a regression only surfaces as a diff in the e2e
  snapshot. Target, priorities and per-layer candidates are in `testing_best_practices.md` §11 — the
  VQSR-fallback pair (`VARIANTFILTRATION_FALLBACK` ext.args, 2026-10-19 + the three-tier output selection in
  `bam_joint_calling_germline_gatk`, 2026-10-16), whose failure modes are silent and unreachable by the e2e
  snapshot, is done; next the rest of the process layer, then subworkflow, then ploidy 1/2/3 pipeline scenarios (these want
  the CI item below to land first). Also decide the fixtures convention (committed-small vs. Azure Blob)
  before `tests/fixtures/` grows.
- **[low] 12 "Dependency … not found" warnings on every nf-test run.** Five vendored nf-core module
  test files declare `setup {}` blocks that run a *sibling* module to manufacture their input, and
  none of those siblings is installed:

  | Warning source (× test cases) | Missing sibling |
  |---|---|
  | `spring/decompress` (×4) | `spring/compress` |
  | `sentieon/bwamem` (×5) | `sentieon/bwaindex` |
  | `sentieon/haplotyper` | `sentieon/qualcal` |
  | `fgbio/callmolecularconsensusreads` | `fgbio/sortbam` |
  | `ngscheckmate/ncm` | `bedtools/makewindows` |

  **Inherited, not fork damage** — all five siblings are equally absent from upstream nf-core/sarek
  3.5.1 (verified 2026-07-30 against the `sarek-compare` worktree). `nf-core modules install` vendors
  a module's `main.nf` *and* its test file but resolves only runtime deps, not test-only ones; sarek
  needs the module and never the sibling. Cosmetic: the warnings come from nf-test's dependency-graph
  pass over all 93 `modules/**/*.nf.test`, which runs regardless of `testsDir "tests"`, and none of
  those tests execute. Fix options all have costs — installing the siblings adds five unused modules;
  deleting the vendored `tests/` dirs breaks the deliberate 0-diff-vs-upstream stance that keeps
  re-forks cheap. **Recommend leaving it** unless the noise starts masking real warnings; revisit at
  the next sarek rebase, when upstream may have resolved it. Documented as expected in
  [`../usage/new_machine_setup.md`](../usage/new_machine_setup.md) § Troubleshooting.
- **[low, post-1.0.0] Adopt incremental nf-test (`--changed-since`) in CI.** The `triggers` change-detection
  deps are already declared on `tests/nf-test-ottilie.config` (2026-07-24), so the ottilie suite re-runs
  when `nextflow.config` / `conf/test/ottilie_test.config` / `tests/.nftignore` / the ottilie configs change.
  Wiring `nf-test test --changed-since <ref>` into CI is deferred to the post-1.0.0 CI/cloud-portability work
  (same bucket as the blob-URL `ottilie_test_ci` profile + GitHub Actions). Until then a plain
  full `nf-test test` is the gate and `triggers` is inert.

- **[med] Learn from upstream's validation tooling before building our own CI.** Upstream sarek
  (https://github.com/nf-core/sarek/tree/3.10.0) validates every change with a `pre-commit` config
  (`.pre-commit-config.yaml`: prettier, editorconfig, nf-core lint hooks) and GitHub Actions workflows
  (`.github/workflows/`: nf-test per changed component via `--changed-since`, lint, schema checks,
  `nf-core pipelines lint`). Inspect which of these transfer to this fork before designing CI, in
  particular how they decide which tests to run for a change — that is the general form of the local
  commit gate added 2026-09-04 (`bin/check_snapshot_staged.sh`: an output-affecting path must ship the
  re-recorded e2e snapshot or a `Snapshot: unchanged` trailer, plus a `Module test: <name> green` line
  per mapped unit test; its two known path gaps are listed under *The commit gate* in
  `testing_best_practices.md` §12). The gate is a stop-gap for a single developer; CI is where the tests should
  actually run. ⚠️ **Prerequisite for any `nf-core pipelines lint` / `schema lint` step in that CI:** the
  lint currently aborts on `split_fastq` because of an nf-core/tools bug, not a schema defect — see the
  `split_fastq` item under *Deployment — Seqera launch UI / schema* (report upstream first; the overlay
  workaround there is the fallback if the fix has not shipped by the time CI needs the gate).
- **[med] CI shape: which test layer runs where, and what each reads (decided 2026-10-19, not built).**
  Settled while making the `VARIANTFILTRATION_FALLBACK` test self-contained (`d60829f`: the test set's
  reference committed bgzipped under `tests/fixtures/reference/`, 1.2 MB, so a module test no longer
  needs `data/ottilie/`). The layout copies upstream sarek 3.10.0, whose `conf/test.config` and
  `tests/nextflow.config` still read small test data from `raw.githubusercontent.com/nf-core/test-datasets/`
  while iGenomes, the annotation caches and the full-size inputs sit on anonymous S3
  (`aws.client.anonymous = true`); unchanged since the 3.5.1 base, so it survives a rebase. For this fork:
  - **Module and subworkflow tests run on every PR from `tests/fixtures/` only**: no download, no
    credentials, no dataset version. Rule: a process or workflow test may depend on nothing outside the
    repo. Ceiling to write into `tests/fixtures/README.md`: about 1–2 MB per file, a few MB in total;
    anything larger goes to the public blob with a download step, not into git. This half-answers the
    fixtures convention question in the coverage item above (committed-small for the module layer).
  - **The e2e contract test runs on a schedule or on pushes to `main`**, reading the 2-sample set
    (FASTQs, reference, SnpEff cache, about 400 MB) from the public blob — `download_test_data.sh`
    (no credentials) or the streaming `ottilie_test_ci` profile via `bin/test_ottilie_blob.sh`, which
    untars only the SnpEff cache (a directory parameter cannot come from a URL). Fits a standard
    GitHub runner (the nf-test resource config caps at 4 CPUs / 14 GB; about 14 min here); too slow
    for every PR. Cache the dataset by version on the runner.
  - **Prerequisite: make the e2e's data base a parameter** (the upstream `pipelines_testdata_base_path`
    idiom) instead of the URLs hard-coded in the `ottilie_test_ci` profile, so a CI job or another site
    points at a mirror without editing the profile. Host second: the public blob stays for now; a
    GitHub-hosted mirror in our own org (Release assets, up to 2 GB a file, no git bloat) would drop
    the Azure account as a dependency. nf-core's own `test-datasets` repository is not the target: it is
    curated for nf-core components, and this strain-specific set serves none; GitHub also throttles
    anonymous `raw.githubusercontent.com` reads, which is why some sites run their own S3 mirror.
  - **Image pulls are the real CI cost**, not fixture size: the module tests pull the GATK image, the
    e2e pulls every image. Cache images before worrying about data.
  - **The commit gate becomes CI's job**: the PR workflow runs the mapped module tests (the gate's
    TESTMAP and the `triggers` lists already encode which test a path owns; `--changed-since` is the
    item above), the scheduled job runs the e2e against the snapshot.
- **[med] Review and decide how coverage is reported (opened 2026-10-19).** The measurement exists
  (`tests/nf_coverage.sh`, `nextflow_code_coverage.md`); how its result reaches a reader is undecided.
  Prompted by rendering the 2026-10-19 run (`d3dc805`, `output_coverage_d3dc805/`) once for someone
  outside the project. What a run already writes: JaCoCo binary (`all.exec`) and XML (`xml/`, hashed
  Groovy class names, what SonarQube / Codecov ingest), `lcov.info` (same data on real file paths, 246
  files; the handoff format for `genhtml`, editor gutters and Codecov), and the script's own text report
  (`tables.txt`, `levels.txt`, `uncovered.txt`, `unique.txt`, `coverage.tsv`) with the fork-only filtering
  the docs quote. Decide, in this order:
  - **Which headline.** The project's is fork code only, from `tables.txt` (522 / 920 branches on
    2026-10-19). A `genhtml` index reports *all* code including pristine sarek (62.4 % lines there) and
    an lcov branch rate on a different denominator (24.5 %) that is not comparable to the JaCoCo
    per-jump count. Any published page must print the fork-only line beside it or readers will quote
    the wrong number (§13 of `testing_best_practices.md`: a number names its script and run).
  - **Which rendering.** Options: `genhtml` static HTML (done once: 930 pages, 13 MB, opens from disk,
    per-line colouring, the subworkflow page shows the 4/4 output-selection lines directly); Codecov or
    similar from `lcov.info` (trend and PR comments, an external service and token); or the text tables
    alone in a CI job summary. Static HTML as a workflow artifact or GitHub Pages is the offline route
    the CI item above assumes.
  - **The renderer dependency.** `genhtml` (lcov 2.5) is not in `environment.yml`; the 2026-10-19 render
    used a throwaway conda env (`lcov-tmp`). Either add `lcov` to the spec so local and CI renders match,
    or treat it as a CI-only `apt` install and document the local command. lcov 2.x needs
    `--ignore-errors inconsistent,unused,category,negative,mismatch,source` on this data (lines hit
    with no branch evaluated: Groovy constant conditions).
  - **Recording per run.** Today each measurement gets a dated *Results* section in
    `nextflow_code_coverage.md` by hand, naming its run directory; the 2026-10-19 run is not yet written
    up. Decide whether that stays the record (fits §13) or a generated trend replaces it once CI runs
    the measurement, and what the run-directory naming is (`output_coverage_<commit>` was used today;
    `output_coverage/` and a dated form exist too).

- **[low, tooling] Commit gate: install the git `commit-msg` hook; make the Claude hook fail honestly.**
  Found 2026-10-19 while committing `f3e9109`: `bin/hook_git_commit_gate.sh` (the Claude Code
  PreToolUse adapter) reads the `-F <path>` literally from the command text, so a message path passed
  through a shell variable (`M=…; git commit -F "$M"`) is invisible to it; it then runs
  `bin/check_snapshot_staged.sh` with an empty message and prints three `BLOCKED` lines claiming the
  trailers are missing when they are not. Same blind spot for `-m` messages. Structural: a hook that
  sees only command text cannot expand a variable that text defines. Two parts, both tooling only (no
  behaviour path, drift check only):
  1. Install the git hook the gate script was written for, `ln -s ../../bin/check_snapshot_staged.sh
     .git/hooks/commit-msg` (not installed on the dev VM as of 2026-10-19): git passes the assembled
     message file as `$1`, whatever the command form, and commits made outside Claude Code are gated
     too. Per clone (`.git/hooks` is not versioned), so add the line to
     `docs/usage/new_machine_setup.md`. The Claude hook stays as the early warning.
  2. In `hook_git_commit_gate.sh`, after `msg_file` is resolved: if it is neither `-` nor readable,
     exit 2 with "cannot read the commit message from the command text (-F <token>); name the path
     literally, or install the git commit-msg hook", instead of running the gate on an empty message.
     Not worth it: parsing `-m "…"` from command text (multi-line quoting is fragile; the git hook
     covers it).

## Documentation

- **[low] Single-source the report Methodology + SV maintainer doc (option B).** The user-facing
  methodology lives in `docs/igvreports/templates/index.html.j2` (§ "SV event matrix"); the
  maintainer mechanics doc for the SURVIVOR internals is `docs/variant-calling/sv_merge.md`. The two
  are kept in **sync by hand** (a "keep in sync" note in each). Future: factor the methodology into a
  shared Jinja `{% include %}` partial so GENERATE_INDEX can render both the report section **and** a
  `mutation_reports/README.md` from one source.

### igvreports follow-ups (migrated from `docs/igvreports/README.md` TODO, 2026-07)

- **[low] (igvreports) Upgrade to igv-reports >= 1.15.0 for the Tabulator template.** The nf-core module
  ships v1.12.0, which lacks the `--tabulator` flag; v1.15.0+ adds a filterable/sortable Tabulator template
  (closest UX to BreSeq's mutation table). Override the module container to >= 1.15.0 (or a custom image),
  then add `--tabulator --filter-config filter_config.yaml` to `ext.args`. (Largely superseded by the custom
  templates in `generate_demo_reports.nf`; revisit only if reverting to the built-in template.)
- **[low] (igvreports) Add per-sample allele frequency.** HaplotypeCaller emits `FORMAT/AD` but not AF.
  Pre-process the VCF with `bcftools +fill-tags -- -t FORMAT/AF` (adds `AF = AD[alt]/(AD[ref]+AD[alt])`)
  before igvreports and expose it via `--sample-columns … AF`. Alternatives: SnpSift or dashboard-side compute.
- **[low] (igvreports) Review INFO columns for ALE relevance.** Current: `FILTER AC AF AN DP FS MQ QD SOR`.
  Consider adding `ExcessHet BaseQRankSum MQRankSum ReadPosRankSum` (QC), dropping `AN` (constant for joint
  calling) and `AC` (redundant with per-sample GT), and deciding INFO-level vs per-sample `AF`.
- **[low] (igvreports) Demo reports missing soft-filter INFO columns.** `generate_demo_reports.nf` uses
  `--info-columns ANN VCF_FILTER ORIG_ALT AC AF DP QD MQ`, but the joint-germline soft filter
  (`VARIANTFILTRATION_FALLBACK`, `conf/modules/joint_germline.config`) also evaluates `FS SOR MQRankSum
  ReadPosRankSum` — without these columns reviewers can't see *why* a variant was flagged. Add them to
  `--info-columns` in both `IGVREPORTS_COHORT`/`IGVREPORTS_SAMPLE` and to the filter config YAML.
- **[low] (igvreports) Review and deliver SV IGVReports.** A pilot SV report exists for the Marko benchmark
  (`docs/benchmarking/marko_sv/generate_igvreport.sh`): SNP/InDel from HaplotypeCaller + SV from the SURVIVOR
  union VCF. Review output, refine columns/flanking, and integrate SV IGVReports into the main pipeline.
- **[low] (igvreports) CRAM-track feasibility on D4as (16 GB).** Full-cohort CRAM embedding OOMs; to make
  with-CRAM runs viable, pre-filter to PASS-only (`bcftools view -f PASS`), limit to 2–3 key samples
  (ancestral + 1–2 evolved), and use `--subsample 0.5 --flanking 200`.

### igvreports dashboard follow-ups (migrated from the igvreports reporting plan, 2026-07)

- **[low] (igvreports reporting plan) Shared template extraction.** Factor shared CSS/JS (theme system,
  Tabulator config, badge definitions) out of the IGV dashboard and Marko SV report into a reusable partial
  (Jinja `{% include %}` or a standalone `dashboard_base.css`/`.js`). Only worthwhile if a third dashboard
  is planned.
- **[low] (igvreports reporting plan) CSV/VCF download links over `file://`.** The SV Ensemble table's
  download buttons only trigger a save dialog over HTTP; via `file://` a click opens the file in a new tab.
  Fix via a local HTTP server, JS Blob-based download, or accept current behavior for local use.
- **[low] (igvreports reporting plan) Benchmarking re-run.** Update the adipic-acid benchmarking scripts from
  the AF 90% → 80% threshold (see `docs/benchmarking/adipic_acid_ale/README.md` TODO).
- **[low] (igvreports reporting plan) `COUNT_VARIANTS` cleanup.** Remove the dead `COUNT_VARIANTS` process and
  the `--variant-counts-json` parameter from `generate_demo_reports.nf` (replaced by the MultiQC source).
- **[med] (igvreports reporting plan) Fix GENERATE_INDEX race condition.** In `generate_demo_reports.nf`,
  `GENERATE_INDEX` runs `generate_index.py` before the `samples/` symlinks exist, so the NF-generated index
  has null `igv_link` values (broken sample click-through). Currently worked around by a standalone
  `generate_index.py` call at the end of `generate_ottilie_reports.sh`. Fix: create symlinks before the
  Python call inside the process, or pass sample-report paths as explicit process inputs.

## Onboarding — a test run anyone can launch (public repo)

Public since 2026-09-04, so someone registering the repo on their own Seqera workspace, AWS Batch or
HPC must be able to run the contract test with no credentials of ours and no pre-launch step. The
data side is solved: the 2-sample set (402 MB) is on the public account `aletestdatapublic` (anonymous
read, SHA256SUMS, per-file https samplesheet). One blocker remains: `snpeff_cache` is a *directory*
param and Nextflow's http provider cannot stage a directory, so `ottilie_test_ci` relies on a local
untar by `bin/test_ottilie_blob.sh`, which a Platform head job never runs (the run aborts in
`ANNOTATION_CACHE_INITIALISATION`).

**Current-stage workaround (no code change, documented in README "Running the SnpEff cache from cloud
storage"):** build the cache with the module's snpEff 5.1, upload the `<snpeff_db>/` directory to your own
`az://` / `s3://` / `gs://` bucket, and pass it as `--snpeff_cache`; every other test input streams from
the public https URLs. This is how our own Launchpad entry runs today. It does not give a zero-edit
`-profile test` launch from a stranger's Launchpad — they still need a bucket and two typed fields.

Background (2026-09-04 review of upstream): sarek's cache pain is four things — `snpeff_db` naming
churn (3.2.0, #1014); two layouts (`<db>/` local vs `<db>/<db>/` cloud, #1122 — the nf-core
`utils_annotation_cache` that replaced the local subworkflow in 3.9.0 applies the doubled key to EVERY
s3/az/gs URL, so our flat az:// layout breaks at the next rebase); path validation on cloud paths (we
patched it; upstream dropped schema validation in 3.10.0, #2184); and the snpEff version lock (a 5.2
cache is refused by the 5.1 container, #1654; sarek master pins 5.4.0c). The snpEff download host died
2025-08 (#1980), moved twice, and is now an AWS bucket. All four are about caches built outside the
pipeline; none is about the transport.

- **[high] Accept a tarball for `--snpeff_cache`, keeping directories as they are.** Sarek's own
  precedent: `--chr_dir` takes a `.tar.gz` via `UNTAR` (`prepare_genome/main.nf`), ASCAT resources take
  `.zip`. Placement (so it survives the 3.9.0+ rebase — see `ale_sarek_upgrade_runbook.md` → *Known
  Rebase Hazards: SnpEff cache*): an **additive** `subworkflows/local/` file (UNTAR + fail-fast unless
  the unpacked tree holds `<snpeff_db>/snpEffectPredictor.bin`, emits `[meta, dir]`) plus ~8 lines in
  `main.nf` keyed on the `snpeff_enabled` boolean the cache subworkflow already takes; **not** inside
  `annotation_cache_initialisation`, which upstream deletes. Drop `format: directory-path` from the
  schema entry via the overlay (upstream did the same). Validation: the e2e is unaffected
  (`ottilie_test` passes a directory) — add a short nf-test for the new subworkflow using the 6 MB
  runtime cache as fixture. `snpeff_cache.tar.gz` (10.5 MB) is already published; republish
  it flat (database directory at the top level) and trimmed to the runtime files
  (`snpEffectPredictor.bin`, `sequence*.bin`, `snpEff.config` — 6 MB, verified 2026-09-04 to annotate the
  truth SNVs), named with the snpEff version. Same cache, same snpEff 5.1, so the snapshot holds. Fork
  feature: upstream's subworkflow has no tarball support.
- **[high] Rebind `-profile test` to the public https profile.** Today `test` is upstream's human test.
  Self-contained: data URLs, tarball cache, and its own `process.resourceLimits` (upstream
  `conf/test.config` uses 4 cpus / 15 GB / 1 h). `ottilie_test` (local data) stays for the nf-test.
  **Flip the `snpeff_cache` default to null, in BOTH places, plus a guard.** (i) `nextflow.config`:
  `snpeff_cache = null` (upstream's own `conf/test.config` already does this) — the inherited
  `s3://annotation-cache/snpeff_cache/` is never right for a custom yeast genome and fails deep in the
  run on Azure. (ii) Schema: remove the `default` key via the overlay (extend `apply_schema_overlay.py`
  with a "remove keys" list rather than editing the schema directly; upstream 3.10.0 still ships the
  s3 default). The two must move together — nf-core lint's `nextflow_config` test compares config
  defaults against schema defaults, and Platform injects the *schema* default over profile values
  (`azure_batch_execution.md` §13), which is what would kill a profile-only Launchpad run elsewhere.
  (iii) Guard in `samplesheet_to_channel` (already ALE-modified): if `tools` contains `snpeff` and
  neither `snpeff_cache` nor `download_cache` is set, error "Please specify --snpeff_cache (a directory;
  az://, s3:// or gs:// prefixes are accepted) or --download_cache" — name only the forms accepted at
  the time (add ".tar.gz" in the tarball commit, not before). Today only the reverse check exists
  (cache without `snpeff_db`), so a missing cache would
  reach `SNPEFF_SNPEFF` with no `-dataDir` and snpEff would try its dead download host. Behaviour
  change → e2e contract test in the same commit (every ottilie profile sets `snpeff_cache`, so the
  snapshot should be unchanged). Acceptance: a Launchpad launch with an EMPTY params box picks up the
  profile's `snpeff_cache`; `nextflow run … --tools snpeff` without a cache fails at launch with that
  message.
- **[med] Standalone SnpEff cache builder, then plug in.** `build_snpeff_cache.nf` beside
  `generate_mutation_report.nf`: FASTA + GFF3 or GenBank in, versioned tarball out (consumed by the
  tarball item above), same `snpeff:5.1` container. Acceptance tests: chromosome-name overlap between
  FASTA and annotation (sarek #415 — silent empty output otherwise), CDS/protein check from derived
  sequences (errors < 2–3 %, snpEff docs), load + one-variant-per-gene smoke annotation, version stamp.
  Replaces the two manual scripts (`process_genbank_auto.sh`, `build_snpeff_cache.sh`; user page
  `docs/usage/prepare_reference.md`) and their Ensembl ID-prefix sed fixes. No nf-core `snpeff/build`
  module exists (checked 2026-09-04). When stable, call the module from the main pipeline when a GFF3 is
  given instead of a cache. Removes the naming/layout/version failures by construction; GFF-quality
  failures remain, which is what the tests are for.
- **[med] The GenBank → GFF3 converter in `process_genbank_auto.sh` is lossy** (measured 2026-09-08 on the
  4-chromosome S288C test GenBank; documented in `docs/usage/prepare_reference.md`). It writes every
  feature as one flat line: no gene → mRNA → CDS `Parent` links, no CDS phase, and the 5,281 `/gene=`
  symbols are dropped (`ID=locus_tag`, `Name=product`). snpEff invents one transcript per CDS
  (`WARNING_TRANSCRIPT_NOT_FOUND … Created transcript`), collapses the 83 multi-exon CDS to a single span,
  and names genes `YDL140C` where the Ensembl cache says `RPO21`. Against the Ensembl-built cache on the
  100-variant contract-test VCF: 89 same primary effect, 92 same impact, 4/4 truth SNVs identical —
  tolerable for a near-intronless yeast, wrong for an intron-rich genome. Fix (either): emit
  gene/mRNA/exon/CDS with `Parent` and phase from the location parts (BioPython `CompoundLocation`) and
  `Name` from `/gene`; or let snpEff read the GenBank directly (`snpEff build -genbank`), which is what
  the standalone builder above should do, retiring the converter.
- **[med] Freeze and mirror the published test data.** `publish_test_data.sh` republishes `ottilie/v1`
  in place; bump the prefix on any change (SHA256SUMS already covers it). The host is one institution's
  account with 7-day soft delete — add a DOI'd mirror (Zenodo, free, versioned) and document
  `OTTILIE_BLOB_BASE` as the switch. Egress per external run is ~0.4 GB, negligible.
- **[low] `--download_cache` is inherited but dead on snpEff 5.1** (its built-in host was deprecated
  2025-08). The stock `R64-1-1.105` exists and, fetched from snpEff's current AWS host, matches our
  cache in 90/100 ANN strings on the test VCF (differences only in Gene_Name/Gene_ID for tRNAs), so it
  would drift the snapshot. Revisit at the sarek rebase (snpEff 5.4.0c; check the cache compatibility
  window first).
- **[med — before the next sarek rebase] Two SnpEff-cache rebase hazards, written up in
  `ale_sarek_upgrade_runbook.md` → *Known Rebase Hazards: SnpEff cache*.** (1) snpEff 5.1 → 5.4.0c
  invalidates every 5.1-built cache: rebuild all caches, re-record the e2e snapshot. (2)
  `annotation_cache_initialisation` is deleted upstream in 3.9.0; its nf-core replacement applies the
  `<db>/<db>/` key to every cloud URL and keeps the directory check, so our flat `az://` cache dirs
  (`ottilie_test_az`, `ottilie_pilot_az`, Launchpad box) fail unless the cloud-path skip is ported as a
  subworkflow patch — or the caches move to tarballs, which is what the tarball item above buys: a patch
  to drop instead of a patch to port. Also re-apply the schema `default` removal for `snpeff_cache`
  after taking the upstream schema (3.10.0 still ships the s3 default).
- **Decided against: test data inside the repo** (`assets/` or raw GitHub). Two FASTQs exceed GitHub's
  100 MB cap, LFS pointers are not fetched by Nextflow, every Seqera clone would drag 400 MB, and nf-core
  keeps test data out of pipeline repos for these reasons. A 6 MB runtime-only cache under `assets/` is
  proven stageable (GENERATE_INDEX's `report_templates_dir` is a `projectDir` directory and ran on both
  Platform runs) but the tarball item makes it unnecessary; the Launchpad cannot browse repo files anyway,
  so a profile has to set the path either way.

## Deployment — Seqera launch UI / schema

**Policy (decided 2026-07-22): curate the surface, not the code.** Upstream sarek ships many tools
and ~141 params ALE doesn't use. Do **NOT** delete upstream calling paths or params to simplify —
that edits upstream files and creates a rebase patch that conflicts on every future sarek upgrade
(see `ale_sarek_upgrade_runbook.md`). Leave the code **inert** (a tool runs only if `--tools` names
it) and control what the user *sees* via `nextflow_schema.json` — which is exactly what the Seqera
launch form renders. Mark advanced/Tier-2 params `"hidden": true` (already done for 22/141 —
`institutional_config_options` + `generic_options`); hidden params still work (CLI / params-file /
"show hidden fields" toggle), they're just out of the default view. Ties to
[[prefer-isolated-config-over-shared]].

- **[v1.0.0 — before release] Mutation-report params: schema + defaults (rescoped 2026-07-23).** Only
  the 2 params a user actually sets get **schema** entries; the fixed-default machinery params are kept
  out of the UI via the **ignore list** (a config param absent from the schema still WARNs even with a
  default — so the ignore list, not omission, is what keeps it clean). Plan:
  - **SHOWN in schema:** `generate_reports` (in `variant_calling`, next to the other ALE toggles;
    default `true`); `report_gff3` (in `reference_genome_options`, next to `genbank` — per-genome
    annotation *file* for the report gene track; help_text notes the report purpose).
  - **`genbank` → flip `hidden: true`** — breseq-only (Tier-2), keep out of the Tier-1 form.
  - **`validation.defaultIgnoreParams` +=** `report_container`, `report_outdir`, `report_filter_config`,
    `report_cohort_template`, `report_sample_template`, `report_index_script`, `report_templates_dir`
    (out of UI, no WARN).
  - **`nextflow.config`:** `generate_reports` false→true; real `${projectDir}/docs/igvreports/…` defaults
    on the 5 static file params (read via `file(params.X)` with no null guard → would `file(null)`-break
    at `generate_reports=true`; assets git-tracked → resolve on Seqera); remove dead `report_multiqc_path`.
  - **`ottilie_test.config`:** remove `report_multiqc_path`; drop the 5 static overrides (now == defaults).
  - Validate with `nf-core pipelines schema lint` + e2e re-run.
- **[low] MultiQC SnpEff breakdown tables show only the last-parsed report's categories — report
  upstream.** `parse_snpeff_log` resets `snpeff_section_totals[section]` at every file's section
  header (MultiQC 1.25.1; **still present in v1.35 — the version the pipeline pins since 2026-09-24, re-verified on our inputs at the bump — and on `main`**), so `snpeff_effects` /
  `snpeff_variant_effects_region` list the effect types of whichever CSV came last in filesystem
  order — 8 columns locally, 14 on Azure Batch, from identical inputs (`output_comparison.md`
  §2.11, found 2026-09-09). Cosmetic for us (excluded from the snapshot; shared cells identical),
  but a real bug for anyone reading those plots. Fix upstream = accumulate totals across files
  (`setdefault`). After the v1 release, with the nf-core/tools item below.
- **[low] The `split_fastq` schema-lint error is an nf-core/tools bug — report it upstream; work around
  it only when nf-core lint becomes a CI gate.** `nf-core pipelines schema lint` (and therefore
  `nf-core pipelines lint`) aborts with *"Default parameters are invalid: 50000000 is valid under each
  of {'type':'integer'}, {'type':'integer','minimum':250}"*. **Root cause (established 2026-09-08):**
  the schema is fine — `split_fastq`'s `oneOf` (`{minimum:250}` / `{minimum:0,maximum:0}`, byte-identical
  to upstream sarek 3.5.1) validates correctly under plain `jsonschema` (50000000 and 0 accepted, 100
  rejected). nf-core's `validate_default_params` first passes the schema through `strip_required()`
  (`nf_core/pipelines/schema.py`), which drops every key whose value is *falsy* — so `"minimum": 0` and
  `"maximum": 0` vanish, the "exactly 0" branch collapses to a bare `{"type":"integer"}`, the default now
  matches both branches, and `oneOf` fails. The quoted subschemas in the message are the stripped ones,
  which is why they match nothing in the file. Still present in nf-core/tools 4.1.0; no issue found in
  nf-core/tools or sarek (searched 2026-09-08). **Runtime nf-schema validation is unaffected** (reads the
  real file; verified with `-preview` at 0 / 100 / 1000), so nothing in the pipeline is wrong.
  - **Option 1 (do first, any time):** file the bug on nf-core/tools — the fix is keeping zero-valued keys
    in `strip_required` (`0 == False` in Python, so `y is False` does not rescue an integer 0). Every
    pipeline with a `minimum: 0`/`maximum: 0` inside a `oneOf` hits it.
  - **Option 2 (prerequisite for the CI item — do NOT do it before then):** if nf-core lint must pass as a
    CI gate before the upstream fix ships, override the zero branch via `conf/schema_overlay.yml`
    `property_overrides` as `{"type":"integer","minimum":0,"exclusiveMaximum":1}` — same runtime meaning,
    survives the stripping because `1` is truthy. Needs a comment naming this item, `--check` green, and
    the three `-preview` values above; schema-only, no e2e. It diverges from upstream in a way that
    looks odd on a sarek rebase, which is why it waits for a real need.
- **[med, post-1.0.0] Full launch-form curation.** `hidden: true` on the advanced/Tier-2 tool params
  (ascat_*, sentieon_*, mutect2/controlfreec extras, tumor-only knobs); set Tier-1 defaults
  (`--tools snpeff,cnvkit,tiddit,manta,haplotypecaller`, joint-germline + report flags on) so a user
  can launch with minimal edits; tidy `$defs` groups. Validate with a Seqera launch preview. **Keep
  `--tools` free-text (do NOT add an `enum`)** — an enum must be re-applied on every rebase and can
  reject valid upstream tool combos; default it to Tier-1 and document Tier-2 as advanced/unvalidated
  instead of hard-blocking it.
- **[open — USER CHECK, minutes] Eyeball the launch form after the 2026-09-09/10 schema changes.**
  No re-registration needed: the form reads `nextflow_schema.json` from `main` (pushed through
  `fd722ca`). Open the Launchpad entry `yAMP-ottilie-test-az` (id `166797736834160`; named `yAMP` since 2026-10) and confirm:
  (a) section order is Input/output → Reference genome → Main options → Variant calling → Read
  preprocessing → Alignment (`group_order` in `conf/schema_overlay.yml`; since 2026-10-05 the order is
  Input/output → Reference genome → Main options (`qc_only`, `tools`) → Read preprocessing →
  Alignment → Variant calling); (b) the read-preprocessing
  figure renders in the "Read preprocessing" group description and in the `trim_adapter` /
  `trim_quality_3prime` tooltips — if the group-description image does not render, drop that link
  from `group_overrides` (keep the tooltip links and the user-page figures); (c) `filter_quality`'s
  text reads "counted base by base … mean quality is never used". Record the outcome here or in
  `deploy/azure/seqera-sp/RUNBOOK.md`, then delete this item.
- **[low, post-1.0.0, user-feedback-gated] Trim the Read preprocessing group on the launch form.**
  All 17 fastp params are deliberately visible (decided 2026-09-02, reaffirmed 2026-09-10) so a user
  can review the ALE default recipe and adapt the trimming to their library — the step-numbered group
  description, figure and tooltips exist for that review. Once real launches show which knobs nobody
  touches, hide those via the overlay's `visible` allowlist (`conf/schema_overlay.yml`; drop from the
  list, regenerate, `--check`; schema-only, no e2e). Likely candidates: the four `clip_*`,
  `trim_quality_mean`/`_window`, `filter_quality_phred`/`_percent`, `length_required`, `trim_nextseq`,
  `adapter_sequence_r2` — leaving the six switches (`trim_adapter`, `adapter_sequence`,
  `trim_quality_3prime`/`_5prime`, `filter_quality`, `save_trimmed`). Do NOT hide the whole group, and
  note there is no schema key for a collapsed group (nf-schema spec checked 2026-09-10): `hidden: true`
  per param is the only lever, and it also drops the param from plain `--help` (`--help_full` shows it).
  Power users bypass the form anyway via a params file (user page planned: `docs/usage/launch_params_file.md`).
- ~~**[low] Decide whether the Seqera GitHub credential stays now that the repo is public (checked 2026-10-09).**~~
  **Decided 2026-10-26: dropped.** No GitHub credential; the public repo clones anonymously (verified by
  run `4tiNtBjO5ozg2y`), the PAT entry left `bin/check_credential_expiry.sh`, the RUNBOOK's *GitHub PAT*
  section records the way back (an org-owned token or GitHub App) should the launch form ever hit the
  anonymous rate limit. Deleting the unused workspace credential and revoking the token are tidy-up.
  *2026-10-23, repo transferred to `nnf-bright-biofoundry/ALE_Yeast`:* the credential's `baseUrl` still
  names the old handle, so it matches nothing, and a fine-grained PAT is owner-scoped, so the token
  cannot be re-pointed. The *Drop* case below is in effect; a replacement needs a token whose resource
  owner is the new org (`RUNBOOK.md` 2026-10-23 entry).
  The fine-grained PAT `github_ALE_Yeast_finegrained` (personal account, was due to expire 2027-08-07, revoked 2026-10-26; record in
  `deploy/azure/seqera-sp/RUNBOOK.md` → *GitHub PAT*) was needed to clone a *private* repository;
  `nnf-bright-biofoundry/ALE_Yeast` has been public since 2026-09-04. *Measured 2026-10-09:* the unauthenticated
  GitHub API reports `visibility: public` and an anonymous `git ls-remote` lists every branch; Seqera's
  Git docs say a public pipeline launches from its URL and that GitHub credentials only raise the GitHub
  API rate limit; the `yAMP` Launchpad entry binds no GitHub credential (Platform matches one by base URL
  at form render and launch), so removing it needs no re-registration; the credential's `lastUsed` stamp
  advances on every form render, so Platform does use it today. Trade-off. *Keep*: one rotation a year
  plus the person-tied dependency the RUNBOOK open item describes (a lapsed token fails every launch in
  the shared workspace). *Drop*: nothing expires, but the form's GitHub API calls go unauthenticated from
  Seqera Cloud's shared egress IPs (60 requests per hour per IP, shared with other customers), so a form
  render or launch can fail intermittently with a rate-limit error outside our control. The head job's
  clone is unaffected either way: anonymous HTTPS from the Batch node's own IP. Recommended default: keep
  it until a real rate-limit failure or the next rotation, whichever comes first. If dropping: delete the
  credential in the workspace, render the form, run one QC-only launch, then update
  `bin/check_credential_expiry.sh`, `CLAUDE.md` (Cloud execution) and the RUNBOOK's *GitHub PAT* section;
  the org-owned GitHub App open item closes with it.
- **[post-1.0.0] Cherry-pick `worktree-seqera-cloud` into `main`** once the Seqera cloud run is
  validated. Not a strict/clean merge — cherry-pick the cloud-specific changes as needed. The branch
  lives on `nnf-bright-biofoundry/ALE_Yeast`; don't merge before cloud validation (avoids pulling unvalidated
  cloud-path changes into `main`). Carried over from an earlier, now-removed release-planning doc.

---

## Resolved (folded into v1.0.0)

One-liners for traceability; full detail in `git log` / `CHANGELOG.md`.

- **SPLIT_JOINT_VCF debug logging** → `log.debug` (commit `2a01a57`).
- **SPLIT_JOINT_VCF TBI emit** — emits `tbi`, consumer uses a proper channel join (dropped the
  `file("${vcf}.tbi")` workaround).
- **`hard_filter_/split_haplotypecaller_joint_vcf` param init** — both default `= false` in `nextflow.config`.
- **FilterMutectCalls channel join** without germline-resource/PoN (commit `fc13aa2`).
- **Control-FREEC germline mode** — `bam_variant_calling_germline_controlfreec/` added + wired in (Apr 2026).
- **YAML `load()` ambiguity** — explicit `FileInputStream` in `utils_nfcore_pipeline`.
- **v0.1.0-alpha release prep** — tag + `README`/`CHANGELOG`/`LICENSE` present; superseded by the v1.0.0 CHANGELOG.
- **Variant Analysis Dashboard as a NF process** — *obsolete*: the `bin/` dashboard scripts were removed
  (commit `95923fc`); superseded by `subworkflows/local/mutation_report/` + `modules/local/generate_index/`.
- **`cram_variant_calling_status_normal` "smarter fix"** — *obsolete*: decision to keep the hard-coded
  all-samples-as-normal approach (confirmed optimal for ALE).
- **SV/CN caller ploidy support** — Tiddit (`-n ${meta.ploidy}`, `tiddit.config`), CNVKit (call+export),
  Control-FREEC; documented under `docs/variant-calling/{tiddit,cnvkit}/*_ploidy_behavior.md`. Manta has
  no ploidy CLI param (SV detection is ploidy-agnostic) — N/A, not a gap.
- **Population SV + CN cohort tables** — `build_sv_matrix`+`survivor_cohort_merge` →
  `sv_cohort_matrix_union{,_pass}.csv`; `build_cn_matrix`+`build_cn_cohort` → `cn_cohort_{full,collapsed}.csv`
  (MUTATION_REPORT deliverables). Feature done; dedicated docs = `docs/variant-calling/sv_merge.md` (SV merge) and
  `docs/variant-calling/cnvkit/cnvkit_cn_calculation.md` (CN matrices).
- **CNVKit results in MultiQC** — documented in `docs/archive/cnvkit/CNVKIT_MULTIQC_INTEGRATION.md`
  (resolved; slated for archive in the docs-consolidation step).
