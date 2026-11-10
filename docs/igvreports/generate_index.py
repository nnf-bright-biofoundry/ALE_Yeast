#!/usr/bin/env python3
"""
Multi-Caller Mutation Report Index Generator

Reads MultiQC summary TSVs and generates a rich static HTML dashboard
using Jinja2 templates with Tabulator.js tables. Links to existing
igv-reports HTML files for alignment drill-down.

Optionally includes CN heatmaps and SV cohort matrices when
--cnv-sv-data-dir is provided (expects CSV files from cn_cohort_matrix.py
and sv_cohort_matrix.py).

Usage (standalone):
    python generate_index.py \
        --multiqc-dir output_all/multiqc/multiqc_data \
        --output docs/igvreports/demo/index.html \
        --sample-reports-dir docs/igvreports/demo/samples \
        --cohort-report docs/igvreports/demo/cohort_report.html

Usage with CN/SV data:
    python generate_index.py \
        --multiqc-dir output_ottilie/multiqc/multiqc_data \
        --output docs/igvreports/ottilie_4samples/index.html \
        --cnv-sv-data-dir docs/igvreports/ottilie_4samples/data

Usage (from Nextflow GENERATE_INDEX process):
    Called with paths resolved by the workflow.
"""

import argparse
import csv
import gzip
import json
import re
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
from jinja2 import Environment, FileSystemLoader

# ---------------------------------------------------------------------------
# Caller suffix mapping: MultiQC sample name suffix -> display name
# Longest suffixes first so greedy matching works correctly.
# ---------------------------------------------------------------------------
CALLER_SUFFIXES = [
    ("haplotypecaller.from_joint_calling.hard_filtered", None),  # skip hard-filtered rows
    ("haplotypecaller.from_joint_calling", "HaplotypeCaller"),  # soft-filtered (all non-ref variants)
    ("freebayes.quality_filtered.normal", None),  # skip filtered rows
    ("manta.diploid_sv", "Manta"),
    ("deepvariant", "DeepVariant"),
    ("freebayes", "FreeBayes"),
    ("cnvcall", "CNVKit"),
    ("tiddit", "TIDDIT"),
]

# Which callers to include in the POC dashboard
TARGET_CALLERS = {"HaplotypeCaller", "CNVKit", "TIDDIT", "Manta"}


# ---------------------------------------------------------------------------
# Page constants. The QC thresholds are mirrored by params.report_qc_* (nextflow.config, hidden on the
# launch form); GENERATE_INDEX hands the live values over as qc_thresholds.json, these defaults serve a
# standalone render. cohort_cov_frac 0.33 (not 0.5): at 0.5 the pilot's parent strain, 43x against a
# cohort median of 86.5x, was flagged although 43x is ample for haploid yeast (2026-10-06).
# ---------------------------------------------------------------------------
QC_THRESHOLD_DEFAULTS = {
    "cov_pass": 30, "cov_fail": 15,          # median coverage, x
    "breadth_pass": 95, "breadth_fail": 90,  # % of the genome at >= 20x
    "map_pass": 95, "map_fail": 90,          # % reads mapped
    "dup_pass": 20, "dup_fail": 40,          # % duplicates (lower is better)
    "cohort_cov_frac": 0.33,                 # warn below this share of the cohort's median coverage
    "min_dp": 8,                             # amber depth in the SNV / InDel events table
}
CN_THRESHOLDS = {"loss": -0.4, "gain": 0.3, "amp": 2.3, "deep_loss": -1.0}  # log2; the page's colours and the counts here
# Contig manifest types (reference/<db>/contig_manifest.csv, written by the --genbank route's extract task from the
# file's qualifiers) that are NOT multi-copy. Every other type (an /organelle value such as mitochondrion, plasmid)
# is graded in the Whole chromosomes table against the cohort median of its fold change, not against 1. Without a
# manifest (the pre-built route: a FASTA names no organelle) the list is empty and every contig, the mitochondrion
# included, is graded against 1; there is no guessing from contig names (decision 2026-11-09).
SINGLE_COPY_TYPES = {"chromosome", "other"}
IGV_LOCUS_TEMPLATE = "samples/{sample}_hc_report.html?locus={chrom}:{pos}"  # custom_template_sample.html reads ?locus=
TOOL_LINKS = {  # the header's caller line
    "HaplotypeCaller": ("GATK HaplotypeCaller", "https://gatk.broadinstitute.org/hc/en-us/articles/360037225632-HaplotypeCaller"),
    "CNVKit": ("CNVKit", "https://cnvkit.readthedocs.io/"),
    "Manta": ("Manta", "https://github.com/Illumina/manta"),
    "TIDDIT": ("TIDDIT", "https://github.com/SciLifeLab/TIDDIT"),
    "SnpEff": ("SnpEff", "https://pcingola.github.io/SnpEff/"),
}


def parse_sample_caller(name: str) -> tuple[str | None, str | None]:
    """Extract (sample_id, caller_display_name) from a MultiQC sample name.

    Examples:
        'A0-F0-I1-R1.cnvcall' -> ('A0-F0-I1-R1', 'CNVKit')
        'A0-F0-I1-R1.haplotypecaller.from_joint_calling' -> ('A0-F0-I1-R1', 'HaplotypeCaller')
        'HaplotypeCaller_joint_calling_soft_filtered' -> (None, None)  # not a per-sample row
    """
    for suffix, display in CALLER_SUFFIXES:
        if name.endswith("." + suffix):
            sample_id = name[: -(len(suffix) + 1)]
            return sample_id, display
    return None, None



# ---------------------------------------------------------------------------
# Data loading from MultiQC TSVs
# ---------------------------------------------------------------------------

def load_bcftools_stats(multiqc_dir: Path) -> pd.DataFrame:
    """Load and parse multiqc_bcftools_stats.txt.

    Returns DataFrame with columns:
        sample, caller, n_records, n_snps, n_indels, tstv
    """
    path = multiqc_dir / "multiqc_bcftools_stats.txt"
    df = pd.read_csv(path, sep="\t")

    rows = []
    for _, row in df.iterrows():
        sample_id, caller = parse_sample_caller(row["Sample"])
        if sample_id is None or caller is None:
            continue
        if caller not in TARGET_CALLERS:
            continue
        rows.append({
            "sample": sample_id,
            "caller": caller,
            "n_records": int(row.get("number_of_records", 0)),
            "n_snps": int(row.get("number_of_SNPs", 0)),
            "n_indels": int(row.get("number_of_indels", 0)),
            "tstv": float(row.get("tstv", 0)),
        })
    return pd.DataFrame(rows)


def get_joint_vcf_variant_count(multiqc_dir: Path) -> int | None:
    """Extract variant count from the joint HaplotypeCaller VCF in MultiQC.

    Looks for 'HaplotypeCaller_joint_calling_soft_filtered' in bcftools stats.
    Returns the number_of_records, or None if not found.
    """
    path = multiqc_dir / "multiqc_bcftools_stats.txt"
    if not path.exists():
        return None
    df = pd.read_csv(path, sep="\t")
    joint_rows = df[df["Sample"].str.contains("joint_calling_soft_filtered", na=False)]
    if joint_rows.empty:
        return None
    return int(joint_rows.iloc[0].get("number_of_records", 0))


def get_joint_vcf_pass_count(joint_vcf: Path | None) -> int | None:
    """Count PASS variants in the joint VCF using bcftools."""
    if joint_vcf is None or not joint_vcf.exists():
        return None
    import subprocess
    try:
        result = subprocess.run(
            ["bcftools", "view", "-f", "PASS", "-H", str(joint_vcf)],
            capture_output=True, text=True, timeout=60,
        )
        return result.stdout.count("\n")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


# ---------------------------------------------------------------------------
# SNV / InDel events table (from the prepared cohort VCF: post-norm, FILTER promoted, FORMAT/VAF)
# ---------------------------------------------------------------------------
IMPACT_RANK = {"HIGH": 0, "MODERATE": 1, "LOW": 2, "MODIFIER": 3}
SNV_TABLE_MAX_ROWS = 1000  # rows shipped in the page; sorted differing first, then impact, then position before the cut
                           # (300 until 2026-10-06; the page prints the full counts and says when the table is cut)


def _display_sample(vcf_name: str, known: list[str]) -> str:
    """Map a VCF sample column (Sarek names it <experiment>_<sample>) to the Samples-table id."""
    best = None
    for s in known:
        if (vcf_name == s or vcf_name.endswith("_" + s)) and (best is None or len(s) > len(best)):
            best = s
    return best or vcf_name


def _alleles(gt: str) -> list[str]:
    return re.split(r"[/|]", gt) if gt else ["."]


def _is_called(gt: str) -> bool:
    return any(a != "." for a in _alleles(gt))


def _has_alt(gt: str) -> bool:
    return any(a not in (".", "0") for a in _alleles(gt))


def _is_ref(gt: str) -> bool:
    return _is_called(gt) and all(a in ("0", ".") for a in _alleles(gt))


def _short_allele(a: str, n: int = 8) -> str:
    return a if len(a) <= n else f"{a[:n]}\u2026({len(a)})"


def _first_ann(info: str, alt: str) -> dict | None:
    """SnpEff's ANN entry for this row's ALT (SnpEff orders entries most-severe first)."""
    m = re.search(r"(?:^|;)ANN=([^;]*)", info)
    if not m:
        return None
    entries = [e.split("|") for e in m.group(1).split(",")]
    chosen = next((e for e in entries if e and e[0] == alt), entries[0])

    def field(i: int) -> str | None:
        return chosen[i] if len(chosen) > i and chosen[i] else None

    return {"effect": field(1), "impact": field(2), "gene": field(3), "hgvs_c": field(9), "hgvs_p": field(10)}


def load_snv_table(prepared_vcf: Path | None, known_samples: list[str],
                   max_rows: int = SNV_TABLE_MAX_ROWS, csv_path: Path | None = None) -> dict | None:
    """Read the prepared cohort VCF once: site counts for the card, the rows of the events table and,
    when csv_path is given, a CSV of EVERY site (FILTER kept, annotation, per-sample GT / AD / VAF).

    Rows: every PASS site (since 2026-10-07; only the differing ones before). Each row carries
    `differs` = at least one called sample has the ALT and at least one is called REF; the page's
    default views filter on it and its *All PASS sites* view shows the rest too: the strain background
    every sample shares, and carried sites with no comparator. A sample with no reads at the site (AD
    sums to 0) is neither carrier nor REF: its VAF is None (the table says "no reads", the CSV leaves
    VAF empty and keeps the caller's GT verbatim) and the rule ignores it, as it ignores a missing
    genotype. So a carried site where every other sample has no reads is NOT differing. On the test
    strain those are the engineered cassette junctions (PDR15, VMR1, HIS3, CAN1): HaplotypeCaller
    assembled the soft-clipped junction reads in one sample and left a DP 0 reference block in the
    others (measured 2026-10-07), so the carrier pattern is a calling artefact, not a mutation. With a
    single sample every PASS site it carries is kept. Multi-allelic sites arrive split one row per allele (INFO/ORIG_ALT): a sample
    called for the other allele is 0 on this row, and fill-tags' VAF counts REF + this allele only,
    so the row carries the original alleles for a marker in the table and a column in the CSV. Rows are
    sorted differing first, then by SnpEff impact (when annotated), contig order and position, and cut
    at max_rows, so the cut never drops a differing row to keep a shared one.
    Pure Python (gzip + str.split): the report container has no bcftools.
    """
    if prepared_vcf is None or not Path(prepared_vcf).exists():
        return None
    opener = gzip.open if str(prepared_vcf).endswith(".gz") else open
    samples: list[str] = []
    chrom_order: dict[str, int] = {}
    total = n_pass = 0
    has_ann = False
    base: list[dict] = []
    csv_fh = writer = None
    with opener(prepared_vcf, "rt") as fh:
        for line in fh:
            if line.startswith("##"):
                if line.startswith("##INFO=<ID=ANN,"):
                    has_ann = True
                continue
            if line.startswith("#"):
                samples = [_display_sample(n, known_samples) for n in line.rstrip("\n").split("\t")[9:]]
                if csv_path is not None:
                    Path(csv_path).parent.mkdir(parents=True, exist_ok=True)
                    csv_fh = open(csv_path, "w", newline="")
                    writer = csv.writer(csv_fh)
                    writer.writerow(["chrom", "pos", "ref", "alt", "filter", "multiallelic_site_alleles", "gene",
                                     "effect", "impact", "hgvs_c", "hgvs_p", "differs_between_samples"]
                                    + [f"{s}_{k}" for s in samples for k in ("GT", "AD", "DP", "VAF")])
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) < 10:
                continue
            total += 1
            chrom_order.setdefault(f[0], len(chrom_order))
            fmt = f[8].split(":")
            gt_i = fmt.index("GT") if "GT" in fmt else None
            ad_i = fmt.index("AD") if "AD" in fmt else None
            dp_i = fmt.index("DP") if "DP" in fmt else None
            vaf_i = fmt.index("VAF") if "VAF" in fmt else None
            gts, ads, dps, vafs, depths = [], [], [], [], []
            for cell in f[9:]:
                parts = cell.split(":")
                gt = parts[gt_i] if gt_i is not None and gt_i < len(parts) else "."
                ad = parts[ad_i] if ad_i is not None and ad_i < len(parts) else "."
                dp = parts[dp_i] if dp_i is not None and dp_i < len(parts) else "."
                dps.append(int(dp) if dp.isdigit() else None)
                raw = parts[vaf_i] if vaf_i is not None and vaf_i < len(parts) else "."
                depth = sum(int(x) for x in ad.split(",") if x.isdigit()) if ad not in (".", "") else None
                if depth == 0:
                    raw = "."               # no reads: no fraction (fill-tags writes 0); the genotype stays as called
                gts.append(gt)
                ads.append(ad)
                depths.append(depth)
                try:
                    vafs.append(round(float(raw), 3))
                except ValueError:
                    vafs.append(None)
            called = [g for g, d in zip(gts, depths) if _is_called(g) and d != 0]
            carried = any(_has_alt(g) for g in called)
            differs = carried and any(_is_ref(g) for g in called)
            ann = _first_ann(f[7], f[4]) if has_ann else None
            m_orig = re.search(r"(?:^|;)ORIG_ALT=([^;]+)", f[7])
            orig_alt = None
            if m_orig:
                parts_o = m_orig.group(1).split("|")           # CHR|POS|REF|ALT1,ALT2|USED_ALT_IDX
                if len(parts_o) >= 4 and "," in parts_o[3]:
                    orig_alt = f"{parts_o[2]} > {parts_o[3].replace(',', ' / ')}"
            if writer is not None:
                writer.writerow(
                    [f[0], f[1], f[3], f[4], f[6], orig_alt]
                    + [ann[k] if ann else None for k in ("gene", "effect", "impact", "hgvs_c", "hgvs_p")]
                    + [("yes" if differs else "no") if len(samples) > 1 else ""]
                    + [v for gt, ad, dp, vaf in zip(gts, ads, dps, vafs)
                       for v in (gt, ad, "" if dp is None else dp, "" if vaf is None else vaf)]
                )
            if f[6] != "PASS":
                continue
            n_pass += 1
            if len(samples) <= 1 and not carried:
                continue
            row = {
                "chrom": f[0], "pos": int(f[1]), "ref": f[3], "alt": f[4],
                "differs": differs if len(samples) > 1 else carried,   # one sample: every kept row is a carried site
                "change": f"{_short_allele(f[3])} > {_short_allele(f[4])}",
                "orig_alt": orig_alt,
                "gene": ann["gene"] if ann else None,
                "effect": ann["effect"].replace("_", " ") if ann and ann["effect"] else None,
                "impact": ann["impact"] if ann else None,
                "hgvs_p": ann["hgvs_p"] if ann else None,
            }
            for s, gt, ad, dp, vaf in zip(samples, gts, ads, dps, vafs):
                row[f"{s}_gt"] = gt
                row[f"{s}_ad"] = ad
                row[f"{s}_dp"] = dp
                row[f"{s}_vaf"] = vaf
            base.append(row)
    if csv_fh is not None:
        csv_fh.close()
    base.sort(key=lambda r: (0 if r["differs"] else 1, IMPACT_RANK.get(r["impact"], 4),
                             chrom_order.get(r["chrom"], 10**6), r["pos"]))
    selected = [r for r in base if r["differs"]]      # the differing views' rows (one sample: every row)
    candidate = sum(1 for r in selected if r["impact"] in ("HIGH", "MODERATE")) if has_ann else None
    return {
        "samples": samples, "rows": base[:max_rows],
        "total": total, "pass": n_pass,
        "listed": len(selected),              # rows of the differing views before the cut, whatever the sample count
        "all_listed": len(base) if len(samples) > 1 else None,   # rows of the All PASS sites view before the cut
        "contigs": list(chrom_order),         # the VCF's contig order, for the page's sort
        "differing": len(selected) if len(samples) > 1 else None,
        "candidate": candidate, "has_ann": has_ann,
        "single_sample": len(samples) <= 1,
        "truncated": len(base) > max_rows, "shown": min(len(base), max_rows),
    }


def load_pass_stats(pass_stats_files: list[Path] | None) -> dict[tuple[str, str], dict]:
    """Load PASS filter stats TSVs into a lookup dict.

    Returns {(sample, caller): {"total": int, "pass": int}}
    """
    if not pass_stats_files:
        return {}
    import csv
    lookup = {}
    for path in pass_stats_files:
        if not path.exists():
            continue
        with open(path) as f:
            reader = csv.DictReader(f, delimiter="\t")
            for row in reader:
                key = (row["sample"], row["caller"])
                lookup[key] = {"total": int(row["total"]), "pass": int(row["pass"])}
    return lookup


def load_general_stats(multiqc_dir: Path, known_samples: set[str] | None = None) -> pd.DataFrame:
    """Load multiqc_general_stats.txt, keeping only sample-level rows.

    Sample-level rows have no space+dot suffix (e.g., 'A0-F0-I1-R1').
    Per-lane rows look like 'A0-F0-I1-R1 .Lane 1 Read1'.
    Per-caller rows look like 'A0-F0-I1-R1 .cnvkit'.

    If known_samples is provided, use it to filter. Otherwise fall back to
    pattern matching (no spaces + ALE naming or known_samples).
    """
    path = multiqc_dir / "multiqc_general_stats.txt"
    df = pd.read_csv(path, sep="\t")

    # Exclude rows with spaces (per-lane, per-caller breakdown rows)
    no_space = ~df["Sample"].str.contains(" ", na=False)

    if known_samples:
        # Use the known sample set from bcftools stats
        mask = no_space & df["Sample"].isin(known_samples)
    else:
        # Fallback: ALE pattern only
        mask = no_space & df["Sample"].str.match(r"^A\d+-F\d+-I\d+-R\d+$", na=False)

    df = df[mask].copy()
    df = df.rename(columns={"Sample": "sample"})

    # Select relevant columns (they may have module prefixes)
    cols = {
        "sample": "sample",
        "gatk4_markduplicates_mark_duplicates-PERCENT_DUPLICATION": "dup_pct",
        "samtools_flagstat_stats-reads_mapped_percent": "mapped_pct",
        "mosdepth-median_coverage": "median_coverage",
        "mosdepth-20_x_pc": "breadth_20x_pct",   # share of the genome at >= 20x (MultiQC's coverage columns, whole percent)
        "samtools_flagstat_stats-reads_mapped": "mapped_reads",
    }
    available = {k: v for k, v in cols.items() if k in df.columns}
    df = df[list(available.keys())].rename(columns=available)

    # Convert numeric columns
    for col in ["dup_pct", "mapped_pct", "median_coverage", "mapped_reads", "breadth_20x_pct"]:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    return df


# ---------------------------------------------------------------------------
# CN/SV data loading from cohort matrix CSVs
# ---------------------------------------------------------------------------

def _get_sample_columns(headers: list[str], suffix: str) -> list[str]:
    """Extract sample names from column headers ending with a given suffix."""
    samples = []
    for h in headers:
        if h.endswith(suffix):
            name = h[: -len(suffix)]
            if name not in samples:
                samples.append(name)
    return samples


def load_cn_chr(path: Path) -> dict | None:
    """Load chromosome-level CN summary CSV. Display value is log2 ratio."""
    if not path.exists():
        return None
    with open(path) as f:
        rows = list(csv.DictReader(f))
    if not rows:
        return None
    samples = _get_sample_columns(list(rows[0].keys()), "_log2")
    out = []
    for r in rows:
        entry = {"chromosome": r["chromosome"], "length": int(r.get("length", 0))}
        # Skip rows where all sample values are empty (e.g. Mito)
        has_data = False
        for s in samples:
            log2_raw = r.get(f"{s}_log2", "")
            if log2_raw:
                has_data = True
                entry[f"{s}_log2"] = round(float(log2_raw), 4)
            else:
                entry[f"{s}_log2"] = None
            fc = r.get(f"{s}_fold_change", "")
            entry[f"{s}_fold_change"] = round(float(fc), 2) if fc else None
        if not has_data:
            continue
        out.append(entry)
    change_count = sum(
        1 for r in out
        if any(_has_cn_change(r.get(f"{s}_log2", 0) or 0) for s in samples)
    )
    return {"rows": out, "samples": samples, "row_count": len(out),
            "change_count": change_count}


def load_contig_cn(path: Path) -> dict | None:
    """Load the contig copy-number CSV (from TIDDIT per-contig coverage, contig_copy_number.py)."""
    if not path.exists():
        return None
    with open(path) as f:
        rows = list(csv.DictReader(f))
    if not rows:
        return None
    samples = _get_sample_columns(list(rows[0].keys()), "_log2")
    out = []
    for r in rows:
        entry = {"chromosome": r["chromosome"]}
        for s in samples:
            log2_raw = r.get(f"{s}_log2", "")
            entry[f"{s}_log2"] = round(float(log2_raw), 4) if log2_raw else None
            fc = r.get(f"{s}_fold_change", "")
            entry[f"{s}_fold_change"] = round(float(fc), 2) if fc else None
            tp = r.get(f"{s}_tiddit_ploidy", "")
            entry[f"{s}_tiddit_ploidy"] = round(float(tp), 2) if tp else None
            cov = r.get(f"{s}_median_cov", "")
            entry[f"{s}_median_cov"] = round(float(cov), 1) if cov else None
            n = r.get(f"{s}_n", "")
            entry[f"{s}_n"] = float(n) if n else None
        out.append(entry)
    # Same thresholds as the CNVKit tables (log2 < -0.4 loss, > 0.3 gain)
    change_count = sum(
        1 for r in out
        if any(_has_cn_change(r.get(f"{s}_log2", 0) or 0) for s in samples)
    )
    return {"rows": out, "samples": samples, "row_count": len(out), "change_count": change_count}


def load_contig_manifest(path: Path | None) -> list[dict] | None:
    """Rows of the reference's contig manifest (contig, version, length, md5, type, chromosome, transl_table, order),
    in file order = the GenBank's record order; the '#' header lines are skipped. None without a manifest."""
    if path is None or not path.exists():
        return None
    with open(path) as f:
        rows = list(csv.DictReader(line for line in f if not line.startswith("#")))
    return rows


def multi_copy_contigs(manifest: list[dict] | None) -> list[str]:
    """The contigs the Whole chromosomes table grades against the cohort median (SINGLE_COPY_TYPES excluded)."""
    return [r["contig"] for r in (manifest or []) if (r.get("type") or "other") not in SINGLE_COPY_TYPES]


def load_cn_regions(path: Path) -> dict | None:
    """Load collapsed CN region matrix CSV. Display value is log2 ratio."""
    if not path.exists():
        return None
    with open(path) as f:
        rows = list(csv.DictReader(f))
    if not rows:
        return None
    samples = _get_sample_columns(list(rows[0].keys()), "_log2")
    out = []
    for r in rows:
        start = int(r.get("start", 0))
        end = int(r.get("end", 0))
        chr_len = r.get("chr_length")
        entry = {
            "chromosome": r["chromosome"],
            "start": start,
            "end": end,
            "chr_length": int(chr_len) if chr_len else None,
            "span_kb": round((end - start) / 1000, 1),
        }
        for s in samples:
            entry[f"{s}_log2"] = round(float(r.get(f"{s}_log2", 0)), 4)
            fc = r.get(f"{s}_fold_change", "")
            entry[f"{s}_fold_change"] = round(float(fc), 2) if fc else None
        out.append(entry)
    # Windows where any sample crosses the shared thresholds (log2 < -0.4 loss, > 0.3 gain): the card number.
    change_count = sum(
        1 for r in out
        if any(_has_cn_change(r.get(f"{s}_log2", 0) or 0) for s in samples)
    )
    return {"rows": out, "samples": samples, "row_count": len(out), "change_count": change_count}


def load_sv_matrix(path: Path) -> dict | None:
    """Load SV cohort matrix CSV."""
    if not path.exists():
        return None
    with open(path) as f:
        rows = list(csv.DictReader(f))
    if not rows:
        return None
    fixed_cols = {"chrom", "pos", "chrom2", "end", "svtype", "svlen"}
    samples = [h for h in rows[0].keys() if h not in fixed_cols]
    out = []
    for r in rows:
        entry = {
            "chrom": r["chrom"],
            "pos": int(r.get("pos", 0)),
            "chrom2": r.get("chrom2", ""),
            "end": int(r.get("end", 0)),
            "svtype": r.get("svtype", ""),
            "svlen": int(r.get("svlen", 0)),
        }
        for s in samples:
            entry[s] = r.get(s, "-")
        out.append(entry)
    both_caller_count = sum(
        1 for r in out
        if any("Manta+TIDDIT" in r.get(s, "") for s in samples)
    )
    return {"rows": out, "samples": samples, "row_count": len(out),
            "both_caller_count": both_caller_count}


def _has_cn_change(log2: float) -> bool:
    """Return True if log2 ratio indicates a CN change (CN_THRESHOLDS, the same values the page colours with)."""
    return log2 < CN_THRESHOLDS["loss"] or log2 > CN_THRESHOLDS["gain"]




def load_cnv_sv_data(data_dir: Path) -> dict:
    """Load all CN/SV data from a directory. Returns dict for template context."""
    cn_chr = load_cn_chr(data_dir / "cn_chr_summary_germline.csv")
    cn_reg = load_cn_regions(data_dir / "cn_cohort_collapsed.csv")
    contig_cn = load_contig_cn(data_dir / "contig_copy_number.csv")
    sv_pass = load_sv_matrix(data_dir / "sv_cohort_matrix_union_pass.csv")
    sv_all = load_sv_matrix(data_dir / "sv_cohort_matrix_union.csv")

    summary = {}
    if sv_pass:
        summary["sv_pass_count"] = sv_pass["row_count"]
    if sv_all:
        summary["sv_all_count"] = sv_all["row_count"]

    # Check for downloadable SV files (CSV + VCF)
    sv_downloads = {}
    for key, csv_name, vcf_name in [
        ("pass", "sv_cohort_matrix_union_pass.csv", "sv_cohort_merged_union_pass.vcf.gz"),
        ("all", "sv_cohort_matrix_union.csv", "sv_cohort_merged_union.vcf.gz"),
    ]:
        csv_path = data_dir / csv_name
        vcf_path = data_dir / vcf_name
        if csv_path.exists():
            sv_downloads[f"{key}_csv"] = f"data/{csv_name}"
        if vcf_path.exists():
            sv_downloads[f"{key}_vcf"] = f"data/{vcf_name}"

    # Check for downloadable CN files (CSV). The link is where the file is PUBLISHED in the bundle; the
    # chromosome summary is staged flat here but published with its siblings under data/cn_matrices/.
    cn_downloads = {}
    for key, csv_name, link in [
        ("regions", "cn_cohort_collapsed.csv", "data/cn_cohort_collapsed.csv"),
        ("chr", "cn_chr_summary_germline.csv", "data/cn_matrices/cn_chr_summary_germline.csv"),
        ("matrix", "cn_cohort_full.csv", "data/cn_cohort_full.csv"),
        ("contig", "contig_copy_number.csv", "data/contig_copy_number.csv"),
    ]:
        csv_path = data_dir / csv_name
        if csv_path.exists():
            cn_downloads[key] = link

    return {
        "cn_chr": cn_chr,
        "cn_reg": cn_reg,
        "contig_cn": contig_cn,
        "sv_pass": sv_pass,
        "sv_all": sv_all,
        "sv_downloads": sv_downloads,
        "cn_downloads": cn_downloads,
        "cnv_sv_summary": summary,
    }


# ---------------------------------------------------------------------------
# Context building for Jinja2 template
# ---------------------------------------------------------------------------

def discover_igv_reports(sample_reports_dir: Path | None) -> dict[str, dict[str, str]]:
    """Find existing igv-reports HTML files.

    Returns {sample_id: {"hc": path, "cnvkit": path, "manta": path, ...}}.
    """
    if sample_reports_dir is None or not sample_reports_dir.is_dir():
        return {}
    links: dict[str, dict[str, str]] = {}
    caller_suffixes = ["hc", "cnvkit", "manta", "tiddit"]
    for f in sorted(sample_reports_dir.glob("*_report.html")):
        name = f.stem.replace("_report", "")
        rel = f"samples/{f.name}"
        matched = False
        for caller in caller_suffixes:
            if name.endswith(f"_{caller}"):
                sample_id = name[: -(len(caller) + 1)]
                links.setdefault(sample_id, {})
                links[sample_id][caller] = rel
                matched = True
                break
        if not matched:
            # Fallback for legacy reports without caller suffix
            links.setdefault(name, {})
            links[name]["hc"] = rel
    return links


def build_context(
    multiqc_dir: Path,
    cohort_report: Path | None,
    sample_reports_dir: Path | None,
    cnv_sv_data_dir: Path | None = None,
    multiqc_report_path: str | None = None,
    pipeline_version: str | None = None,
    snv_csv: str | None = None,
    cohort_vcf_link: str | None = None,
    output_dir: Path | None = None,
    joint_vcf: Path | None = None,
    prepared_vcf: Path | None = None,
    pass_stats_files: list[Path] | None = None,
    contig_manifest: Path | None = None,
) -> dict:
    """Build the full template context dictionary."""

    bcftools_df = load_bcftools_stats(multiqc_dir)

    # Get unique samples (sorted) from bcftools stats
    samples = sorted(bcftools_df["sample"].unique())
    callers = sorted(TARGET_CALLERS)

    # Use known samples for general stats filtering
    general_df = load_general_stats(multiqc_dir, known_samples=set(samples))

    # --- Variant counts pivot: {sample: {caller: n_records}} ---
    variant_pivot = {}
    for _, row in bcftools_df.iterrows():
        variant_pivot.setdefault(row["sample"], {})[row["caller"]] = row["n_records"]

    # --- Combined QC + variant summary table ---
    igv_links = discover_igv_reports(sample_reports_dir)

    # Build QC lookup from general_stats
    qc_lookup = {}
    for _, row in general_df.iterrows():
        qc_lookup[row["sample"]] = {
            "dup_pct": round(row.get("dup_pct", 0), 1) if pd.notna(row.get("dup_pct")) else None,
            "mapped_pct": round(row.get("mapped_pct", 0), 1) if pd.notna(row.get("mapped_pct")) else None,
            "median_coverage": int(row.get("median_coverage", 0)) if pd.notna(row.get("median_coverage")) else None,
            "mapped_reads_m": round(row.get("mapped_reads", 0), 1) if pd.notna(row.get("mapped_reads")) else None,
            "breadth_20x_pct": round(float(row.get("breadth_20x_pct")), 1) if pd.notna(row.get("breadth_20x_pct")) else None,
        }

    # Load PASS filter stats (from FILTER_PASS_VCF)
    pass_stats = load_pass_stats(pass_stats_files)

    summary_data = []
    for sample in samples:
        counts = variant_pivot.get(sample, {})
        qc = qc_lookup.get(sample, {})

        # HC variant count from MultiQC bcftools_stats (soft-filtered, all non-ref)
        hc_variants = counts.get("HaplotypeCaller", 0)

        # TIDDIT: use PASS stats if available, otherwise fall back to raw count
        tiddit_ps = pass_stats.get((sample, "tiddit"), {})
        tiddit_total = tiddit_ps.get("total", counts.get("TIDDIT", 0))
        tiddit_pass = tiddit_ps.get("pass")  # None if no pass stats

        # Manta: same PASS/all split (the Manta IGV report itself keeps all calls)
        manta_ps = pass_stats.get((sample, "manta"), {})
        manta_total = manta_ps.get("total", counts.get("Manta", 0))
        manta_pass = manta_ps.get("pass")

        entry = {
            "sample": sample,
            # QC fields
            "median_coverage": qc.get("median_coverage"),
            "breadth_20x_pct": qc.get("breadth_20x_pct"),
            "dup_pct": qc.get("dup_pct"),
            "mapped_pct": qc.get("mapped_pct"),
            "mapped_reads_m": qc.get("mapped_reads_m"),
            # Variant fields
            "hc_variants": hc_variants,
            "cnvkit_events": counts.get("CNVKit", 0),
            "tiddit_svs": tiddit_total,
            "tiddit_pass": tiddit_pass,
            "manta_svs": manta_total,
            "manta_pass": manta_pass,
            "igv_link": igv_links.get(sample, {}).get("hc"),
            "cnvkit_igv_link": igv_links.get(sample, {}).get("cnvkit"),
            "manta_igv_link": igv_links.get(sample, {}).get("manta"),
            "tiddit_igv_link": igv_links.get(sample, {}).get("tiddit"),
        }
        summary_data.append(entry)

    # --- Cohort report path ---
    cohort_link = None
    cohort_variant_count = 0
    if cohort_report and cohort_report.exists():
        cohort_link = cohort_report.name

    # Post-norm counts + the SNV/InDel events rows from the prepared VCF (match cohort report table rows)
    snv = load_snv_table(prepared_vcf, [s["sample"] for s in summary_data],
                         csv_path=(output_dir / snv_csv) if snv_csv and output_dir is not None else None)
    if snv is not None:
        cohort_variant_count = snv["total"]
        cohort_pass_count = snv["pass"]
        snv["csv_link"] = snv_csv if snv_csv else None   # relative to index.html, like multiqc_report_path
        snv["vcf_link"] = cohort_vcf_link or None
    else:
        # Fallback to pre-norm counts from MultiQC
        joint_count = get_joint_vcf_variant_count(multiqc_dir)
        if joint_count is not None:
            cohort_variant_count = joint_count
        else:
            cohort_variant_count = sum(s.get("hc_variants", 0) for s in summary_data)
        cohort_pass_count = get_joint_vcf_pass_count(joint_vcf)

    # Pre-norm count for context (shown as subtitle on card)
    cohort_prenorm_count = get_joint_vcf_variant_count(multiqc_dir)

    # --- CN/SV data (optional) ---
    cnv_sv = {}
    if cnv_sv_data_dir and cnv_sv_data_dir.is_dir():
        cnv_sv = load_cnv_sv_data(cnv_sv_data_dir)

    return {
        "title": "yAMP mutation report",
        "pipeline_version": pipeline_version,
        "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "n_samples": len(samples),
        "callers": callers,
        "cohort_link": cohort_link,
        "cohort_variant_count": cohort_variant_count,
        "cohort_pass_count": cohort_pass_count,
        "cohort_prenorm_count": cohort_prenorm_count,
        "snv": snv,
        "multiqc_report_path": multiqc_report_path,   # None = no MultiQC link (the nav shows one only when the report exists)
        "summary_data_json": json.dumps(summary_data),
        # CN/SV data (None if not provided)
        "cn_chr": cnv_sv.get("cn_chr"),
        "cn_reg": cnv_sv.get("cn_reg"),
        "contig_cn": cnv_sv.get("contig_cn"),
        "sv_pass": cnv_sv.get("sv_pass"),
        "sv_all": cnv_sv.get("sv_all"),
        "sv_downloads": cnv_sv.get("sv_downloads", {}),
        "cn_downloads": cnv_sv.get("cn_downloads", {}),
        "cnv_sv_summary": cnv_sv.get("cnv_sv_summary", {}),
        # the reference's contig manifest (--genbank route) or None: contig order + the multi-copy contigs
        "contig_manifest": load_contig_manifest(contig_manifest),
    }


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def load_run_info(path: Path | None) -> dict | None:
    """Which run produced the bundle: the JSON GENERATE_INDEX writes from the workflow's metadata.

    Returns the fields of the index's *Run* line, or None without a usable file (a standalone render).
    The Seqera run id is present only when Seqera Platform launched the run; it becomes a link only
    when the run was also given its workspace's browser URL (--seqera_workspace_url), because a run
    cannot learn that address by itself. Every field is optional.
    """
    if path is None or not Path(path).is_file():
        return None
    try:
        info = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(info, dict) or not info.get("run_name"):
        return None

    start = None
    if info.get("start"):
        try:  # Nextflow prints nanoseconds; drop the fraction, show UTC
            parsed = datetime.fromisoformat(re.sub(r"\.\d+", "", str(info["start"])).replace("Z", "+00:00"))
            if parsed.tzinfo is not None:
                parsed = parsed.astimezone(timezone.utc)
            start = parsed.strftime("%Y-%m-%d %H:%M") + (" UTC" if parsed.tzinfo is not None else "")
        except ValueError:
            start = str(info["start"])

    commit = str(info["commit_id"]) if info.get("commit_id") else None
    repository = str(info.get("repository") or "")
    seqera_id = str(info["seqera_run_id"]) if info.get("seqera_run_id") else None
    workspace_url = str(info.get("seqera_workspace_url") or "").strip()
    return {
        "name": str(info["run_name"]),
        "session": info.get("session_id"),
        "start": start,
        "commit": commit[:7] if commit else None,
        "commit_url": f"{repository.removesuffix('.git').rstrip('/')}/commit/{commit}"
                      if commit and re.match(r"https://github\.com/[\w.-]+/[\w.-]+?(\.git)?/?$", repository) else None,
        "revision": info.get("revision"),
        "nextflow": info.get("nextflow_version"),
        "seqera_id": seqera_id,
        "seqera_url": f"{workspace_url.rstrip('/')}/watch/{seqera_id}"
                      if seqera_id and re.match(r"https?://[^\s\"'<>]+$", workspace_url) else None,
    }


def load_qc_thresholds(path: Path | None) -> dict:
    """QC_THRESHOLD_DEFAULTS overridden by the JSON GENERATE_INDEX writes from params.report_qc_* (a key per
    threshold, same names). A missing file or key keeps the default; whole numbers print as integers."""
    values = dict(QC_THRESHOLD_DEFAULTS)
    if path is None or not Path(path).is_file():
        return values
    try:
        given = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return values
    for key, raw in (given or {}).items():
        if key not in values or raw is None:
            continue
        try:
            v = float(raw)
        except (TypeError, ValueError):
            continue
        values[key] = int(v) if v.is_integer() and key != "cohort_cov_frac" else v
    return values


def _tool(name: str) -> dict:
    label, url = TOOL_LINKS[name]
    return {"name": label, "url": url}


def template_context(ctx: dict, run: dict | None, outdir: str | None, report_dir: str | None,
                     qc_thresholds: dict) -> dict:
    """Map the loaded data onto the template's contract (docs/igvreports/templates/README.md)."""
    summary = json.loads(ctx["summary_data_json"])
    samples = [s["sample"] for s in summary]
    snv, sv = ctx.get("snv"), ctx.get("sv_pass")
    cn_chr, cn_reg, contig = ctx.get("cn_chr"), ctx.get("cn_reg"), ctx.get("contig_cn")
    run = run or {}

    # The header's caller line names what produced something in this run.
    def used(key: str) -> bool:
        return any((s.get(key) or 0) > 0 for s in summary)
    tools = [{"label": "SNV/InDel", "links": [_tool("HaplotypeCaller")]}]
    if cn_chr or cn_reg or used("cnvkit_events"):
        tools.append({"label": "CNV", "links": [_tool("CNVKit")]})
    sv_links = [_tool(c) for c, key in (("Manta", "manta_svs"), ("TIDDIT", "tiddit_svs")) if used(key)]
    if sv_links or sv:
        tools.append({"label": "SV", "links": sv_links or [_tool("Manta"), _tool("TIDDIT")]})
    if snv and snv.get("has_ann"):
        tools.append({"label": "annotation", "links": [_tool("SnpEff")]})

    # Download links only for files that exist in the bundle; the template falls back to the bundle's
    # fixed names for the rest, so a missing optional file costs at most one dead link, never a crash.
    downloads = {}
    if snv:
        if snv.get("csv_link"):
            downloads["snv_csv"] = snv["csv_link"]
        if snv.get("vcf_link"):
            downloads["snv_vcf"] = snv["vcf_link"]
    if ctx.get("cohort_link"):
        downloads["cohort_igv"] = ctx["cohort_link"]
    sv_dl, cn_dl = ctx.get("sv_downloads") or {}, ctx.get("cn_downloads") or {}
    for key, src in (("sv_csv", sv_dl.get("pass_csv")), ("sv_vcf", sv_dl.get("pass_vcf")),
                     ("contig_cn_csv", cn_dl.get("contig")), ("cn_chr_csv", cn_dl.get("chr")),
                     ("cn_win_csv", cn_dl.get("regions")), ("cn_full_csv", cn_dl.get("matrix"))):
        if src:
            downloads[key] = src

    # Contig order for the page's sorts: the manifest's (the reference's record order, complete) when the run
    # had one, else the order the contigs first appear in the cohort VCF (reference order too), else the TIDDIT
    # table's rows (.fai order). All three are the reference's order; the first two cover every contig.
    manifest = ctx.get("contig_manifest")
    chromosomes = ([r["contig"] for r in manifest] if manifest else None) \
        or (snv or {}).get("contigs") or [r["chromosome"] for r in (contig or {}).get("rows", [])]
    return {
        "report": {
            "title": ctx["title"], "pipeline_name": "yAMP", "version": ctx.get("pipeline_version"),
            "run_name": run.get("name") or "standalone render", "started": run.get("start"),
            "generated": ctx["generated_at"],
            "commit": run.get("commit"), "commit_url": run.get("commit_url"), "branch": run.get("revision"),
            "nextflow_version": run.get("nextflow"),
            "seqera_run_id": run.get("seqera_id"), "seqera_url": run.get("seqera_url"),
            "session_id": run.get("session"), "output_dir": outdir or None, "report_dir": report_dir or None,
        },
        "tools": tools,
        "multiqc_href": ctx.get("multiqc_report_path") or None,
        "load_web_fonts": False,
        "samples": samples,
        "chromosomes": chromosomes,
        "multi_copy_contigs": multi_copy_contigs(manifest),
        # a manifest that names no multi-copy contig is not "no manifest": the legend and Methods word the two apart
        "has_contig_manifest": bool(manifest),
        "igv_locus_template": IGV_LOCUS_TEMPLATE,
        "qc_thresholds": qc_thresholds,
        "cn_thresholds": CN_THRESHOLDS,
        "counts": {
            "snv_called": snv["total"] if snv else None, "snv_pass": snv["pass"] if snv else None,
            "snv_listed": snv["listed"] if snv else None, "snv_coding": snv["candidate"] if snv else None,
            "snv_all": snv["all_listed"] if snv else None,
            "snv_max_rows": SNV_TABLE_MAX_ROWS,
        },
        "snv_single_sample": bool(snv and snv["single_sample"]),
        "snv_has_ann": bool(snv and snv["has_ann"]),
        "summary_data": summary,
        "snv_rows": snv["rows"] if snv else None,
        "sv_rows": sv["rows"] if sv else None,
        "contig_cn_rows": contig["rows"] if contig else [],
        "cn_chr_rows": cn_chr["rows"] if cn_chr else [],
        "cn_reg_rows": cn_reg["rows"] if cn_reg else [],
        "downloads": downloads,
    }


TABULATOR_VENDOR_DIR = "vendor/tabulator-6.3.0"  # under the templates dir; pristine upstream files + LICENSE


def load_vendored(template_dir: Path, name: str) -> str | None:
    """A vendored Tabulator file to inline into the page, so the index needs no network.

    None when the file is absent (a templates dir without the vendor folder): the template then
    links the CDN copy as before. The trailing sourceMappingURL comment is dropped, as no map ships.
    """
    path = template_dir / TABULATOR_VENDOR_DIR / name
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8")
    return re.sub(r"\s*/[/*]# sourceMappingURL=\S+(?: \*/)?\s*$", "", text)


def render(context: dict, template_dir: Path, output_path: Path) -> None:
    """Render the Jinja2 template and write to output."""
    env = Environment(
        loader=FileSystemLoader(str(template_dir)),
        autoescape=True,  # the template marks the inlined Tabulator files | safe and injects data with | tojson
    )
    template = env.get_template("index.html.j2")
    html = template.render(
        tabulator_css=load_vendored(template_dir, "tabulator.min.css"),
        tabulator_js=load_vendored(template_dir, "tabulator.min.js"),
        **context,
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html)
    print(f"Generated: {output_path} ({len(html):,} bytes)")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate multi-caller variant dashboard index.html"
    )
    parser.add_argument(
        "--multiqc-dir", required=True, type=Path,
        help="Path to multiqc_data/ directory containing TSV summary files",
    )
    parser.add_argument(
        "--output", required=True, type=Path,
        help="Output path for the generated index.html",
    )
    parser.add_argument(
        "--cohort-report", type=Path, default=None,
        help="Path to cohort_report.html (for linking)",
    )
    parser.add_argument(
        "--sample-reports-dir", type=Path, default=None,
        help="Path to directory containing per-sample igv-reports HTML files",
    )
    parser.add_argument(
        "--templates-dir", type=Path, default=None,
        help="Path to Jinja2 templates directory (default: templates/ next to this script)",
    )
    parser.add_argument(
        "--cnv-sv-data-dir", type=Path, default=None,
        help="Directory containing CN/SV cohort matrix CSVs (from cn_cohort_matrix.py, sv_cohort_matrix.py)",
    )
    parser.add_argument(
        "--multiqc-report-path", type=str, default=None,
        help="Relative path to multiqc_report.html from the output index.html location",
    )
    parser.add_argument(
        "--joint-vcf", type=Path, default=None,
        help="Path to joint HaplotypeCaller VCF (.vcf.gz) for PASS variant counting",
    )
    parser.add_argument(
        "--prepared-vcf", type=Path, default=None,
        help="Path to prepared (post-norm) cohort VCF for accurate row counting matching cohort report table",
    )
    parser.add_argument(
        "--pass-stats", type=Path, nargs="*", default=None,
        help="PASS filter stats TSV files from FILTER_PASS_VCF (sample, caller, total, pass)",
    )
    parser.add_argument(
        "--contig-manifest", type=Path, default=None,
        help="The reference's contig_manifest.csv (reference/<db>/, --genbank route): its type column names the "
             "multi-copy contigs the Whole chromosomes table grades against the cohort median, and its row order is "
             "the page's contig order. Absent on the pre-built route: every contig is then graded against 1.",
    )
    parser.add_argument(
        "--outdir", type=str, default=None,
        help="Where the complete pipeline output lands (local path or az:// URL); printed in the header",
    )
    parser.add_argument(
        "--report-dir", type=str, default=None,
        help="Where this report bundle lands when it is not <outdir>/mutation_reports; printed next to --outdir",
    )
    parser.add_argument(
        "--run-info", type=Path, default=None,
        help="JSON written by GENERATE_INDEX from the workflow's metadata (run_name, session_id, start, commit_id, "
             "revision, repository, nextflow_version, seqera_run_id, seqera_workspace_url); printed as the Run line",
    )
    parser.add_argument(
        "--qc-thresholds", type=Path, default=None,
        help="JSON written by GENERATE_INDEX from params.report_qc_* (cov_pass, cov_fail, breadth_pass, breadth_fail, map_pass, "
             "map_fail, dup_pass, dup_fail, cohort_cov_frac, min_dp); the Samples-table grading. Defaults apply when absent.",
    )
    parser.add_argument(
        "--pipeline-version", type=str, default=None,
        help="Pipeline version shown as a chip next to the title (the workflow's manifest version); omitted when not given",
    )
    parser.add_argument(
        "--snv-csv", type=str, default=None,
        help="Write every site of the prepared cohort VCF as CSV at this path RELATIVE to the index (e.g. data/snv_indel_sites.csv); "
             "the SNV/InDel section links it",
    )
    parser.add_argument(
        "--cohort-vcf-link", type=str, default="vcf/haplotypecaller/cohort_haplotypecaller_annotated.vcf.gz",
        help="Relative link from the index to the published cohort VCF (the bundle keeps this name whether or not an "
             "annotator ran; see vcf/README.md); empty string disables the VCF button",
    )
    args = parser.parse_args()

    context = build_context(
        multiqc_dir=args.multiqc_dir,
        cohort_report=args.cohort_report,
        sample_reports_dir=args.sample_reports_dir,
        cnv_sv_data_dir=args.cnv_sv_data_dir,
        multiqc_report_path=args.multiqc_report_path,
        pipeline_version=args.pipeline_version,
        snv_csv=args.snv_csv,
        cohort_vcf_link=args.cohort_vcf_link,
        output_dir=args.output.parent,
        joint_vcf=args.joint_vcf,
        prepared_vcf=args.prepared_vcf,
        pass_stats_files=args.pass_stats,
        contig_manifest=args.contig_manifest,
    )
    context = template_context(context, run=load_run_info(args.run_info), outdir=args.outdir,
                               report_dir=args.report_dir, qc_thresholds=load_qc_thresholds(args.qc_thresholds))

    # Template directory: explicit arg or relative to this script
    template_dir = args.templates_dir or (Path(__file__).parent / "templates")
    render(context, template_dir, args.output)


if __name__ == "__main__":
    main()