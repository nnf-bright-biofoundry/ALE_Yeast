#!/usr/bin/env python
"""
SV Cohort Matrix — build the cohort-level wide-format SV table from an
SVDB cross-caller cohort VCF (SVDB_MERGE_CALLERS output).

Each row is one SV event (breakend pairs already collapsed upstream), columns are
samples, cells show which caller(s) support the event in that sample:
Manta / TIDDIT / Manta+TIDDIT / '-'.

Cells are a DETERMINISTIC PARSE of the merged VCF — no proximity matching. The rules
(verified in docs/benchmarking/ottilie_xenobiotic_ale/04_validate/sv_merge_bench/, F7):

  - INFO/manta_POS present   <=> Manta contributed to the record; the FORMAT columns
    then belong to Manta (priority caller), so a sample's Manta cell = its GT carries
    an alt allele (and, in the pass view, FORMAT/FT == PASS — the record-level FILTER
    is PASS by construction there, but a weak genotype must not be read as support).
  - INFO/tiddit_POS present  <=> TIDDIT contributed. Per-sample TIDDIT support comes
    from the propagated per-input keys `<sample>.tiddit_SAMPLE` (union view) /
    `<sample>.tiddit.pass_SAMPLE` (pass view): the key exists iff that sample's TIDDIT
    VCF contained the call. For TIDDIT-only records the FORMAT columns are TIDDIT's
    across-samples merge, and per-sample GT is used directly.

Record coordinates are the priority caller's (Manta when it contributed); the other
caller's live in INFO/<tag>_POS and are not re-derived here.

Rows are in reference order: the contig order of the reference's .fai (= the FASTA's, = the
GenBank's record order on the --genbank route), then pos. Nothing is sorted by name; a contig
the .fai lacks (none in practice: the VCF's contigs are the reference's) goes last, by name.

Usage (from BUILD_SV_MATRIX):
    sv_cohort_matrix.py --cohort-vcf sv_cohort_merged_union.vcf.gz \
        --samples CBR110-15-R3a NODRUG-GM2 --fai reference.fa.fai \
        --csv sv_cohort_matrix_union.csv [--pass-view]
"""

import argparse
import csv
import gzip
import re
import sys
from pathlib import Path

BND_MATE_RE = re.compile(r"[\[\]]([^\[\]:]+):(\d+)[\[\]]")
TIDDIT_SAMPLE_KEY_RE = re.compile(r"^(.+)\.tiddit(?:\.pass)?_SAMPLE$")


def open_vcf(path):
    return gzip.open(path, "rt") if str(path).endswith(".gz") else open(path)


def gt_has_alt(gt):
    return any(a not in ("0", ".", "") for a in re.split(r"[/|]", gt))


def parse_records(vcf_path, samples, pass_view):
    """Yield one matrix-row dict per VCF record."""
    columns = None
    with open_vcf(vcf_path) as fh:
        for line in fh:
            if line.startswith("##"):
                continue
            if line.startswith("#CHROM"):
                columns = line.rstrip("\n").split("\t")[9:]
                # map sample id -> VCF column index (columns are '<patient>_<sample>' or '<sample>')
                col_of = {}
                for s in samples:
                    for i, c in enumerate(columns):
                        if c == s or c.endswith("_" + s):
                            col_of[s] = i
                            break
                    else:
                        sys.exit(f"ERROR: no VCF sample column matches '{s}' in {columns}")
                continue
            fields = line.rstrip("\n").split("\t")
            info = dict(kv.split("=", 1) if "=" in kv else (kv, "1")
                        for kv in fields[7].split(";"))

            chrom, pos, alt = fields[0], int(fields[1]), fields[4]
            # TIDDIT subtypes DUP:TANDEM / DUP:INV are both copy-gains; the matrix uses the
            # parent class (the exact subtype stays in the cohort VCF's tiddit_INFO).
            svtype = info.get("SVTYPE", ".").replace("DUP:TANDEM", "DUP").replace("DUP:INV", "DUP")
            svlen = abs(int(float(info.get("SVLEN", 0))))
            if svtype == "BND":
                m = BND_MATE_RE.search(alt)
                chrom2 = m.group(1) if m else chrom
                end = int(m.group(2)) if m else pos
                svlen = 0
            else:
                chrom2 = info.get("CHR2", chrom)
                end = int(info.get("END", pos + svlen))

            has_manta = "manta_POS" in info
            has_tiddit = "tiddit_POS" in info
            tiddit_samples = {m.group(1) for k in info
                              if (m := TIDDIT_SAMPLE_KEY_RE.match(k))}

            fmt_keys = fields[8].split(":")
            gt_i = fmt_keys.index("GT")
            ft_i = fmt_keys.index("FT") if "FT" in fmt_keys else None

            row = {"chrom": chrom, "pos": pos, "chrom2": chrom2, "end": end,
                   "svtype": svtype, "svlen": svlen}
            for s in samples:
                sample_fmt = fields[9 + col_of[s]].split(":")
                gt = sample_fmt[gt_i] if gt_i < len(sample_fmt) else "./."
                callers = []
                if has_manta:
                    # FORMAT belongs to Manta; pass view additionally requires FT PASS
                    ok = gt_has_alt(gt)
                    if ok and pass_view and ft_i is not None and ft_i < len(sample_fmt):
                        ok = sample_fmt[ft_i] == "PASS"
                    if ok:
                        callers.append("Manta")
                    # TIDDIT support for this sample comes from the propagated keys.
                    # <sample>.tiddit key naming assumes sample ids without dots before
                    # '.tiddit' — true for ALE sample ids.
                    if has_tiddit and s in tiddit_samples:
                        callers.append("TIDDIT")
                else:
                    # TIDDIT-only record: FORMAT columns ARE the TIDDIT merge
                    if gt_has_alt(gt):
                        callers.append("TIDDIT")
                row[s] = "+".join(callers) if callers else "-"
            yield row


def load_contig_order(fai_path):
    """Contig names in .fai order (samtools faidx writes them in FASTA order)."""
    with open(fai_path) as f:
        return [line.split("\t")[0] for line in f if line.strip()]


def contig_sort_key(order):
    """Sort key: position in the .fai, then (last) the name for a contig the .fai lacks."""
    index = {c: i for i, c in enumerate(order)}
    return lambda chrom: (index.get(chrom, len(order)), chrom)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cohort-vcf", required=True,
                        help="SVDB cross-caller cohort VCF (.vcf or .vcf.gz)")
    parser.add_argument("--samples", required=True, nargs="+",
                        help="Sample ids, in the desired column order")
    parser.add_argument("--fai", required=True,
                        help="Reference .fai: its contig order is the row order")
    parser.add_argument("--csv", required=True, help="Output CSV path")
    parser.add_argument("--pass-view", action="store_true",
                        help="Apply the per-sample FT gate (union_pass matrix)")
    args = parser.parse_args()

    samples = args.samples
    print(f"Samples: {', '.join(samples)}")

    order = load_contig_order(args.fai)
    print(f"Reference: {args.fai} ({len(order)} contigs)")
    chrom_key = contig_sort_key(order)
    rows = list(parse_records(args.cohort_vcf, samples, args.pass_view))
    rows.sort(key=lambda r: (chrom_key(r["chrom"]), r["pos"], r["end"], r["svtype"]))
    print(f"Cohort events: {len(rows)}")

    out_path = Path(args.csv)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = ["chrom", "pos", "chrom2", "end", "svtype", "svlen"] + samples
    with open(out_path, "w", newline="") as f:
        # lineterminator: csv defaults to \r\n; these CSVs are LF like every other output
        writer = csv.DictWriter(f, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)

    n_present = lambda r: sum(1 for s in samples if r[s] != "-")
    print(f"Shared events (2+ samples): {sum(1 for r in rows if n_present(r) > 1)}")
    print(f"Private events (1 sample): {sum(1 for r in rows if n_present(r) == 1)}")
    print(f"Output: {out_path}")


if __name__ == "__main__":
    main()
