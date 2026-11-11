#!/usr/bin/env python
"""Truth gate of the ottilie test set: does a pipeline run on a cut still show what the set is for?

Run after generate_test_data.sh and one pipeline run on its output:

    python check_test_data_truth.py <pipeline outdir> [--fastq-dir data/ottilie/fastq_test]

Checks, all read from the run's published files (standard library only):

  1. the run read exactly the FASTQs of the cut: read pairs per sample in the fastp reports equal
     the pair counts in <fastq-dir>/CUT_PARAMETERS.tsv, and the files still have the recorded md5;
  2. the four published SNVs of CBR110-15-R3a are PASS in the cohort table, carried by the evolved
     sample and not by the parent;
  3. the chr I gain: evolved fold change at least 1.2 on chr I, every other nuclear contig of both
     samples between 0.9 and 1.1, in the CNVKit table and in the TIDDIT contig table;
  4. the SV floor: every junction record of test_set_sv_floor.tsv is in the joint Manta VCF with
     FILTER PASS and a non-reference genotype in both samples (they are the strain's engineered
     cassette junctions, present in parent and evolved alike);
  5. the mitochondrial contig is in the contig manifest, typed as an organelle.

On success it writes <fastq-dir>/TRUTH_GATE.txt (the FASTQ md5s and the measured values).
publish_test_data.sh refuses a set without that file, or with one written for other FASTQs.
Exit status 1 and no file when any check fails.
"""
import argparse
import csv
import datetime
import gzip
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]

EVOLVED, PARENT = "CBR110-15-R3a", "NODRUG-GM2"
TRUTH_SNVS = [  # Ottilie et al. 2022, Sup Data 4 (data/ottilie/pilot_truth_set.csv)
    ("IV", 205738, "C", "A", "RPO21"),
    ("IV", 1184212, "G", "T", "TRR1"),
    ("VII", 233903, "G", "A", "ROG1"),
    ("XV", 639861, "G", "T", "YRR1"),
]
GAIN_CONTIG, GAIN_MIN = "I", 1.2
NEUTRAL = (0.9, 1.1)
NUCLEAR = ["I", "IV", "VII", "XV"]
SV_TOLERANCE = 30  # bp, on a breakpoint position

failures, notes = [], []


def check(ok, text):
    (notes if ok else failures).append(("OK    " if ok else "FAIL  ") + text)
    print(("  OK    " if ok else "  FAIL  ") + text)


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(line for line in f if not line.startswith("#")))


def one(outdir, pattern):
    hits = sorted(outdir.glob(pattern))
    if len(hits) != 1:
        sys.exit(f"ERROR: expected one file matching {pattern} under {outdir}, found {len(hits)}")
    return hits[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("outdir", type=Path)
    ap.add_argument("--fastq-dir", type=Path, default=REPO / "data/ottilie/fastq_test")
    ap.add_argument("--sv-floor", type=Path, default=HERE / "test_set_sv_floor.tsv")
    args = ap.parse_args()
    out, fq = args.outdir, args.fastq_dir

    print("1. the run read the FASTQs of this cut")
    cut = {r["sample"]: r for r in csv.DictReader(open(fq / "CUT_PARAMETERS.tsv"), delimiter="\t")}
    check(set(cut) == {EVOLVED, PARENT}, f"CUT_PARAMETERS.tsv lists {sorted(cut)}")
    for sample, r in sorted(cut.items()):
        for k in ("1", "2"):
            check(md5(fq / r[f"fastq_{k}"]) == r[f"md5_{k}"], f"{r[f'fastq_{k}']} has the recorded md5")
        rep = json.load(open(one(out, f"reports/fastp/{sample}/*.fastp.json")))
        reads = rep["summary"]["before_filtering"]["total_reads"]
        check(reads == 2 * int(r["pairs"]), f"{sample}: fastp read {reads} reads, the cut holds {2 * int(r['pairs'])}")

    print("2. the four published SNVs")
    sites = {(r["chrom"], int(r["pos"]), r["ref"], r["alt"]): r for r in rows(out / "mutation_reports/data/snv_indel_sites.csv")}
    for chrom, pos, ref, alt, gene in TRUTH_SNVS:
        r = sites.get((chrom, pos, ref, alt))
        if r is None:
            check(False, f"{chrom}:{pos} {ref}>{alt} ({gene}) is not in the cohort table")
            continue
        ok = r["filter"] == "PASS" and r[f"{EVOLVED}_GT"] == "1" and r[f"{PARENT}_GT"] == "0"
        check(ok, f"{chrom}:{pos} {ref}>{alt} ({gene}): FILTER {r['filter']}, evolved GT {r[f'{EVOLVED}_GT']} "
                  f"AD {r[f'{EVOLVED}_AD']}, parent GT {r[f'{PARENT}_GT']} AD {r[f'{PARENT}_AD']}")

    print("3. the chr I gain")
    for label, path, key in (("CNVKit", "mutation_reports/data/cn_matrices/cn_chr_summary_call.csv", "chromosome"),
                             ("TIDDIT", "mutation_reports/data/contig_copy_number.csv", "chromosome")):
        table = {r[key]: r for r in rows(out / path)}
        for contig in NUCLEAR:
            if contig not in table:
                check(False, f"{label}: no row for contig {contig}")
                continue
            for sample in (EVOLVED, PARENT):
                fc = float(table[contig][f"{sample}_fold_change"])
                if contig == GAIN_CONTIG and sample == EVOLVED:
                    check(fc >= GAIN_MIN, f"{label}: {sample} chr {contig} fold change {fc:.3f} (gain, at least {GAIN_MIN})")
                else:
                    check(NEUTRAL[0] <= fc <= NEUTRAL[1], f"{label}: {sample} chr {contig} fold change {fc:.3f} (neutral)")

    print("4. the SV floor (joint Manta)")
    floor = [r for r in csv.DictReader(open(args.sv_floor), delimiter="\t")]
    records = []
    with gzip.open(one(out, "variant_calling/manta/Ottilie_test/Ottilie_test.manta.diploid_sv.vcf.gz"), "rt") as f:
        for line in f:
            if line.startswith("#"):
                continue
            c = line.rstrip("\n").split("\t")
            info = dict(kv.split("=", 1) for kv in c[7].split(";") if "=" in kv)
            mate = re.search(r"[\[\]]([^:\[\]]+):(\d+)[\[\]]", c[4])
            gts = [s.split(":")[0] for s in c[9:]]
            records.append(dict(chrom=c[0], pos=int(c[1]), svtype=info.get("SVTYPE", ""), filter=c[6],
                                mate_chrom=mate.group(1) if mate else "", mate_pos=int(mate.group(2)) if mate else 0,
                                carried=all(re.search(r"[1-9]", g) for g in gts)))
    for want in floor:
        hit = [r for r in records
               if r["chrom"] == want["chrom"] and r["svtype"] == want["svtype"]
               and abs(r["pos"] - int(want["pos"])) <= SV_TOLERANCE
               and r["mate_chrom"] == want["mate_chrom"]
               and (not want["mate_chrom"] or abs(r["mate_pos"] - int(want["mate_pos"])) <= SV_TOLERANCE)]
        name = f"{want['svtype']} {want['chrom']}:{want['pos']}" + (f" -> {want['mate_chrom']}:{want['mate_pos']}" if want["mate_chrom"] else "")
        check(bool(hit) and hit[0]["filter"] == "PASS" and hit[0]["carried"],
              f"{name}: " + ("PASS, carried by both samples" if hit and hit[0]["filter"] == "PASS" and hit[0]["carried"]
                             else (f"FILTER {hit[0]['filter']}, carried by both: {hit[0]['carried']}" if hit else "no such record")))
    extra = len(records) - len(floor)
    print(f"  note  the joint Manta VCF holds {len(records)} records, the floor lists {len(floor)}")

    print("5. the mitochondrial contig")
    manifest = {r["contig"]: r for r in rows(one(out, "reference/*/contig_manifest.csv"))}
    mito = manifest.get("Mito", {})
    check(mito.get("type") == "mitochondrion" and mito.get("transl_table") == "3",
          f"contig manifest: Mito type '{mito.get('type', 'absent')}', genetic code '{mito.get('transl_table', 'absent')}'")

    print()
    if failures:
        print(f"TRUTH GATE FAILED: {len(failures)} check(s). No stamp written; this cut must not be published.")
        sys.exit(1)
    stamp = fq / "TRUTH_GATE.txt"
    with open(stamp, "w") as f:
        f.write(f"# ottilie test set truth gate, passed {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC\n")
        f.write(f"# pipeline output checked: {out.resolve().name}\n")
        f.write(f"# joint Manta records: {len(records)} (floor {len(floor)}, {extra} more)\n")
        for sample, r in sorted(cut.items()):
            for k in ("1", "2"):
                f.write(f"md5\t{r[f'md5_{k}']}\t{r[f'fastq_{k}']}\n")
        for line in notes:
            f.write(f"check\t{line}\n")
    print(f"TRUTH GATE PASSED: {len(notes)} checks. Stamp: {stamp}")


if __name__ == "__main__":
    main()
