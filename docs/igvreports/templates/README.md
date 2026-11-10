# yAMP mutation report: the `index.html.j2` contract

`index.html.j2` is the template of the mutation report's `index.html`, rendered by `../generate_index.py` (process `GENERATE_INDEX`). Tabulator 6.3 is inlined from `vendor/`, the data is injected as JSON; one offline HTML file, no CDN. The design was handed over on 2026-10-06 as `report.html.j2`, restyled to the agreed mockup (`Mutation Report.dc.html` in the design project), and adapted here. This file is the contract between the renderer and the template: the context below is what `template_context()` builds.

## How it is rendered
1. `generate_index.py` loads the MultiQC tables, the prepared cohort VCF and the CN / SV CSVs as before (`build_context()`), then maps them onto the context below (`template_context()`), and renders with `autoescape=True` (the template marks the inlined Tabulator files `| safe` and injects data with `| tojson`).
2. `summary_data[].breadth_20x_pct` comes from MultiQC general stats (`mosdepth-20_x_pc`, a whole percent); no extra process input.
3. `qc_thresholds` are the `params.report_qc_*` values, written by the module to `qc_thresholds.json` (`--qc-thresholds`); `QC_THRESHOLD_DEFAULTS` in the script apply to a standalone render. `cn_thresholds` are the script's constants, shared with its Summary counts.
4. The per-sample IGV locus URL (`igv_locus_template`, `?locus=chrom:pos`) is handled by `custom_template_sample.html`; the link is shown only for non-reference genotypes.
5. A render needs no network; `load_web_fonts` stays `False` (decided 2026-10-06).
6. Methods holds the eight sections of the previous template's Methodology after *QC thresholds*. Keep the *SV event matrix* section in sync with `docs/variant-calling/sv_merge.md` (a Jinja comment says so).
7. `SNV_TABLE_MAX_ROWS` is 1000; the renderer passes `counts.snv_listed` / `snv_coding` / `snv_all` / `snv_max_rows`, `snv_single_sample` and `snv_has_ann`, so the page prints the full numbers and says when the table is cut. Since 2026-10-07 every PASS row ships, each with `differs`; the rows sort differing first, so a cut costs shared rows before differing ones.

## Context
```python
ctx = dict(
  report=dict(
    title="yAMP mutation report", pipeline_name="yAMP", version="1.0.0",
    run_name="special_lumiere", started="2026-10-02 12:42 UTC", generated="2026-10-02 13:05",
    commit="51356a5e43…", commit_url="https://github.com/…/commit/…", branch="main",
    nextflow_version="25.10.4", seqera_run_id="15SDWs75bsHeyg", seqera_url="https://cloud.seqera.io/…",
    session_id="da63393b-…", output_dir="az://aletest/seqera-runs/…",   # any of these may be None
    report_dir=None,   # the bundle's own folder, only when report_outdir moved it out of <outdir>/mutation_reports; shown as a "report" row
  ),
  tools=[  # header caller line
    dict(label="SNV/InDel", links=[dict(name="GATK HaplotypeCaller", url="…")]),
    dict(label="CNV",       links=[dict(name="CNVKit", url="…")]),
    dict(label="SV",        links=[dict(name="Manta", url="…"), dict(name="TIDDIT", url="…")]),
    dict(label="annotation",links=[dict(name="SnpEff", url="…")]),
  ],
  multiqc_href="multiqc_report.html",
  load_web_fonts=False,        # True = IBM Plex from Google Fonts; False = system fallback (offline-safe)
  tabulator_css="<contents of tabulator.min.css>",
  tabulator_js="<contents of tabulator.min.js>",

  samples=["CBR110-15-R3a", "NODRUG-GM2"],   # display order everywhere
  chromosomes=["I", "II", …, "Mito"],         # contig order for sorting (optional): the reference's contig manifest when the run had one (--genbank route), else the order of first appearance in the cohort VCF, else the TIDDIT table's rows; all three are reference (.fai) order
  multi_copy_contigs=["Mito"],                # coloured vs the cohort median of their fold change, not vs 1: the contigs whose manifest `type` is neither `chromosome` nor `other` (an /organelle value such as mitochondrion, or plasmid). [] without a manifest (pre-built route: a FASTA names no organelle), and then every contig, Mito included, is coloured vs 1; the legend and Methods say which applied. No name list, no template fallback (2026-11-09; was mito_contigs=["Mito","chrM","MT"])
  igv_locus_template="samples/{sample}_hc_report.html?locus={chrom}:{pos}",

  qc_thresholds=dict(cov_pass=30, cov_fail=15, breadth_pass=95, breadth_fail=90,
                     map_pass=95, map_fail=90, dup_pass=20, dup_fail=40,
                     cohort_cov_frac=0.5, min_dp=8),
  cn_thresholds=dict(loss=-0.4, gain=0.3, amp=2.3, deep_loss=-1.0),   # log2

  counts=dict(snv_called=100, snv_pass=83,   # sites in the prepared cohort VCF, and PASS among them
              snv_listed=24, snv_coding=5,   # rows of the differing views BEFORE the cut (PASS sites that differ between samples; with one sample, every PASS site it carries) and the HIGH + MODERATE ones among them
              snv_all=83,                    # rows of the All PASS sites view before the cut = every PASS site (None with one sample: no such view)
              snv_max_rows=1000),            # the renderer's cap (SNV_TABLE_MAX_ROWS, raised from 300 on 2026-10-06): snv_rows is the first snv_max_rows rows, differing first, then by impact and position
  snv_single_sample=False,   # True = one sample in the run: lede, toggle and Summary row say "PASS sites it carries" instead of "differ between samples"
  snv_has_ann=True,          # False = no SnpEff: gene columns and the Protein-changing toggle are hidden; a cohort opens on the differing sites (toggle: Differ between samples / All PASS sites), one sample on every row

  summary_data=[ {  # one per sample — existing fields + breadth_20x_pct
    "sample", "median_coverage", "breadth_20x_pct", "mapped_pct", "mapped_reads_m", "dup_pct",
    "hc_variants", "cnvkit_events", "manta_svs", "manta_pass", "tiddit_svs", "tiddit_pass",
    "igv_link", "cnvkit_igv_link", "manta_igv_link", "tiddit_igv_link" } ],
  snv_rows=[ {  # every PASS site (one sample: every PASS site it carries), the first snv_max_rows of them, differing first; the counts above carry the full numbers
    "differs",  # bool: at least one called sample carries the ALT and at least one is called REF (no-reads samples count as neither); the Protein-changing and All differing views filter on it; rows without it are treated as differing
    "chrom", "pos", "ref", "alt", "change", "gene", "effect", "impact", "hgvs_p", "orig_alt",
    "filter"?,  # optional, defaults to PASS
    "<sample>_gt", "<sample>_ad", "<sample>_dp", "<sample>_vaf" } ],
  sv_rows=[ { "chrom", "pos", "chrom2", "end", "svtype", "svlen", "<sample>": "Manta"|"TIDDIT"|"Manta+TIDDIT"|"-" } ],
  contig_cn_rows=[ { "chromosome", "<sample>_fold_change", "<sample>_log2",
                     "<sample>_tiddit_ploidy", "<sample>_n", "<sample>_median_cov" } ],   # TIDDIT, incl. Mito
  cn_chr_rows=[ { "chromosome", "length", "<sample>_fold_change", "<sample>_log2" } ],     # CNVKit
  cn_reg_rows=[ { "chromosome", "start", "end", "chr_length", "<sample>_fold_change", "<sample>_log2" } ],  # CNVKit collapsed windows, all of them
  downloads=dict(),  # optional path overrides: snv_csv, snv_vcf, sv_csv, sv_vcf, contig_cn_csv, cn_chr_csv, cn_win_csv, cohort_igv (default cohort_report.html), cn_full_csv (default data/cn_cohort_full.csv, the uncollapsed bin matrix)
)
```
Set `snv_rows` / `sv_rows` to `None` (and leave all three CN lists empty) to hide a section. Section numbers and nav update to match.

## What changed vs the template before 2026-10-06
- **Header:** run line plus a provenance block (commit, Nextflow/Seqera, session, output path with a Copy button, the report bundle's folder when it differs). The theme toggle and dark mode are gone (it's a light document style now).
- **Sticky section nav.**
- **Summary:** a ruled count table instead of cards, built in JS from the rows. The Samples row shows how many samples failed QC or have warnings, with a reason line for each failure. This replaces the separate failure banner.
- **Samples:** a QC status column. Pass/warn/fail colouring comes from `qc_thresholds`, which are also shown under each header. A sample below `cohort_cov_frac` × the cohort median coverage gets a warning. Mapped reads (M) and CNVKit events are kept (informational, not graded).
- **SNV / InDel:** Locus is a single column (sorts by chromosome order, then position). VAF cells also show depth, in amber below `min_dp`. Clicking a row opens a per-sample panel (GT, AD, DP, VAF, IGV link at that locus). The view toggles show counts; since 2026-10-07 a cohort has three: *Protein-changing* (opening view), *All differing*, *All PASS sites* (every PASS row: the shared strain background and the carried sites with no sample to compare against, whose other cells read *no reads*). An *IGV, all samples* button opens the cohort igv-report. Three wordings as before: cohort with SnpEff, cohort without SnpEff (no gene columns, no Protein-changing toggle, opens on the differing sites with a *Differ between samples* / *All PASS sites* toggle), one sample (every PASS site it carries; *Protein-changing* / *All PASS sites*). When the rows were cut at `snv_max_rows` the lede says so and the toggles read "N of M". The *CSV, rows shown* export carries a hidden *Differs between samples* column on a cohort.
- **SV:** the Type / Location / Length layout. New "Differ between samples" toggle.
- **Copy number:** the three tabs are gone.
  - *Whole chromosomes:* samples as rows. A source toggle switches between TIDDIT (incl. Mito) and CNVKit. A contig in `multi_copy_contigs` has its column headed *vs median* and its cells graded against the cohort median of its fold change; the event label then names the contig as is (no "chr" prefix).
  - *Changed windows:* one row per window that changed in any sample, plus a per-sample strip (values shown up to 8 samples, compact blocks with hover above that). Chromosome chips and a "hide changed in every sample" toggle.
  - The Fold change / log2 ratio toggle and "Only samples with a change" apply to both tables.
  - Downloads: TIDDIT CSV, CNVKit CSV, Windows CSV and *All bins CSV* (the uncollapsed matrix, `data/cn_cohort_full.csv`).
- **Methods:** the QC thresholds text is generated from `qc_thresholds`; the eight sections of the old Methodology follow it (filter tables, counting pipeline, SV merge, CNVKit, TIDDIT contig CN, IGV report generation, Samples table sources), with *Card counts* and *Tabs* rewritten for the new page.
- The Seqera iframe download hint is kept.

## Presentation mode (tutorials, screen sharing, slide screenshots)
- Turn it on with `report.html?present`, the **Present ⤢** link in the nav, or the **P** key (P again exits). It keeps the current `#section`.
- **Text:** larger type throughout and a wider page (max 1600 px).
- **Tables:** all at full height with every row drawn (`renderVertical: "basic"`), so a full-page or "Capture node screenshot" gets the whole table.
- **Hidden:** downloads, the copy button and the Seqera hints. The nav stops being sticky.
- **Window strip:** shows values for up to 12 samples (8 in normal mode).
- **Deep links:** use one per tutorial step, e.g. `report.html?present#cn-chr`, `#cn-win`, `#snv`. The page scrolls there after the tables render.
- **Slide captures:** set the browser window to 1600×900 at 100–125 % zoom.

## Checks
- Render with the two-sample test run (the e2e contract test does; `index.html` is name-only in its snapshot, so open the page in a browser).
- Render a run with ≥ 60 samples. Check that the window strip switches to compact blocks and the chromosome table gets a fixed height and scrolls.
- Force a QC failure (e.g. `cov_fail=50`). The Summary should show the failure line, and that sample's QC cell should be red.
- Render a full-genome bundle twice, with `--contig-manifest` (a manifest typing Mito `mitochondrion`) and without. With it the Mito column reads *vs median* and the legend names Mito; without it the legend says every contig is coloured against 1 and a Mito value of 10 shows as an amplification (done 2026-11-09 on the 4-sample pilot bundle, `index.html` of `output_ottilie_pilot_2026-09-09`).
