#!/usr/bin/env python
"""Derive the pipeline's reference inputs from one GenBank file.

One parse of the GenBank produces everything the pipeline needs from a reference, with ONE contig
name everywhere (the LOCUS name; docs/dev-practices/genbank_reference_input.md §3):

  <db>.fa                 FASTA, LOCUS headers, records in file order
  <db>.gff3               gene track for the mutation report (gene > mRNA > exon/CDS with Parent and
                          phase); nothing annotates from it
  contig_manifest.csv     one row per record: LOCUS, VERSION, length, sequence md5, type, chromosome,
                          transl_table, order; header with the file name and its sha256 (§5.2)
  <db>/genes.gbk          the copy snpEff builds from: every record's VERSION set to its LOCUS name,
                          inserted when the file has none. snpEff names contigs from VERSION, then the
                          /chromosome qualifier, then LOCUS (measured, §3.2); VERSION wins, so the cache
                          name equals LOCUS in every variant. The user's file is never touched.
  <db>/snpEff.config      the per-genome config: the .genome line plus one codonTable line per contig
                          whose /transl_table is not 1 (§4). snpEff ignores /transl_table and keeps no
                          genetic code in a built database; this line, read at annotation time, is the
                          only carrier.
  expected_cache_contigs.txt  the contig names snpEff will store, one per line, for the build task's
                          second gate. snpEff simplifies a chromosome name before storing it (measured
                          2026-11-02 on 18 spellings, snpEff 5.1 ChromosomeSimpleName): leading zeros,
                          then a leading "chromosome" / "chromo" / "chr" (any case) and an underscore
                          after it, repeated; a name that would become empty is kept ("chr" stays
                          "chr"). So LOCUS chrB is stored as B, chr01 as 1. A VCF's CHROM is simplified
                          the same way at annotation time, so every output keeps the LOCUS name and
                          still annotates. A record with no feature at all is dropped by the build
                          ("Remove empty chromosomes"; one source feature is enough to keep it).
  preflight_genbank_mqc.tsv   verdict rows for the "yAMP input checks" MultiQC table (§5.5), same id
                          and header as bin/preflight_reference.sh; keep the three copies identical.

Verdicts (console lines only for WARN and ERROR, nothing on a clean file; exit 65 on ERROR so the
module's errorStrategy stops the run; the table is written first):
  GenBank contig identifiers   OK    always, unless an ERROR below. Records without a versioned
                                     accession (VERSION missing or equal to LOCUS: the normal output
                                     of SnapGene, Benchling or Prokka, a first-class input) are listed
                                     in a note: a database registration matches them by sequence md5
                                     from the contig manifest. No console line
                               ERROR two records resolve to the same LOCUS, or to the same name once
                                     snpEff has simplified it (chr1 and 1 would be merged in the cache);
                                     a LOCUS with a colon, pipe, whitespace or a GFF3/VCF reserved
                                     character; a record without sequence
  GenBank genetic code         OK    every contig with CDS states one /transl_table
                               WARN  an organelle contig (/organelle in its source feature) whose CDS
                                     state no /transl_table: the standard code is assumed and the run
                                     proceeds (decision 2026-11-02), but organelles rarely use it. On
                                     any other contig a missing qualifier IS the standard code, by the
                                     INSDC rule that /transl_table=1 may be omitted (every nuclear CDS
                                     of NCBI's S288C file omits it), so nothing is said
                               ERROR a contig whose CDS state different tables; a table snpEff has no
                                     codon table for

Usage: genbank_to_reference.py --genbank ref.gbff[.gz] --db <name> [--outdir .] [--source-name ref.gbff]
"""

import argparse
import csv
import gzip
import hashlib
import io
import os
import re
import sys
from collections import OrderedDict
from urllib.parse import quote

from Bio import SeqIO

PREFIX = "[yAMP preflight]"

# NCBI /transl_table number -> snpEff codon table name (the `codon.<Name>` entries of snpEff 5.1's
# bundled snpEff.config, listed 2026-11-02; the numbers are NCBI's genetic-code identifiers). Numbers
# missing here (7, 8, 17-20, 24-33) are ones snpEff 5.1 does not define: an ERROR, not a guess.
CODON_TABLES = {
    1: "Standard",
    2: "Vertebrate_Mitochondrial",
    3: "Yeast_Mitochondrial",
    4: "Mold_Mitochondrial",
    5: "Invertebrate_Mitochondrial",
    6: "Ciliate_Nuclear",
    9: "Echinoderm_Mitochondrial",
    10: "Euplotid_Nuclear",
    11: "Bacterial_and_Plant_Plastid",
    12: "Alternative_Yeast_Nuclear",
    13: "Ascidian_Mitochondrial",
    14: "Alternative_Flatworm_Mitochondrial",
    15: "Blepharisma_Macronuclear",
    16: "Chlorophycean_Mitochondrial",
    21: "Trematode_Mitochondrial",
    22: "Scenedesmus_obliquus_Mitochondrial",
    23: "Thraustochytrium_Mitochondrial",
}

# Characters an identifier may not contain: whitespace, colon and pipe break samtools region strings,
# the SV mate parser and the IGV cross-links; the rest are GFF3 / VCF field separators.
BAD_ID_CHARS = re.compile(r"[\s:|;=,&<>]")

MQC_HEADER = """# id: 'yamp_input_checks'
# section_name: 'yAMP input checks'
# description: "What the pipeline checked before aligning any read (docs/usage/preflight_checks.md): the samplesheet and the parameters when the run starts, the reference files in its first task. A failed check stops the run before any report is written, so this table lists what passed (OK) and what was flagged (WARN); WARN lines are also printed on the console with the [yAMP preflight] prefix."
# plot_type: 'table'
# pconfig:
#     id: 'yamp_input_checks_table'
#     namespace: 'yAMP input checks'
#     sort_rows: false
# headers:
#     status:
#         title: 'Status'
#         description: 'OK, WARN or SKIPPED (an ERROR stops the run)'
#     detail:
#         title: 'Detail'
#         description: 'What was checked and what was found'
Check\tstatus\tdetail
"""


SNPEFF_PREFIXES = ("chromosome", "chromo", "chr")


def snpeff_simple_name(name):
    """The name snpEff 5.1 stores for a chromosome (ChromosomeSimpleName), as measured 2026-11-02."""
    n = name.strip()
    while True:
        before = n
        n = n.lstrip("0") or n
        low = n.lower()
        for p in SNPEFF_PREFIXES:
            if low.startswith(p) and len(n) > len(p):
                n = n[len(p):]
                break
        n = n.lstrip("_") or n
        if n == before:
            break
    return n or name


class Verdicts:
    def __init__(self):
        self.rows = []
        self.errors = 0

    def add(self, status, check, detail):
        self.rows.append((check, status, detail))
        if status == "WARN":
            print(f"{PREFIX} WARN  {check}: {detail}")
        elif status == "ERROR":
            print(f"{PREFIX} ERROR {check}: {detail}")
            print(f"{PREFIX} ERROR {check}: {detail}", file=sys.stderr)
            self.errors += 1

    def write(self, path):
        with open(path, "w") as fh:
            fh.write(MQC_HEADER)
            for check, status, detail in self.rows:
                fh.write(f"{check}\t{status}\t{detail}\n")


def open_text(path):
    with open(path, "rb") as fh:
        magic = fh.read(2)
    if magic == b"\x1f\x8b":
        return gzip.open(path, "rt")
    return open(path, "r")


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def gff_escape(value):
    # GFF3 column 9: percent-encode the reserved characters, keep spaces readable.
    return quote(str(value), safe=" !$()*+./?@[]^_{}~")


# ----------------------------------------------------------------------------------------------
# Pass 1: the raw text, record by record. Needed for the VERSION rewrite (BioPython's writer would
# reformat the file) and to know whether a record HAS a VERSION line (BioPython fills record.id
# from ACCESSION or LOCUS when it has none).
# ----------------------------------------------------------------------------------------------
def rewrite_versions(text):
    """Return (rewritten text, {LOCUS: VERSION token or ''}) with VERSION := LOCUS in every record."""
    out = []
    versions = OrderedDict()
    locus = None
    has_version = False
    accession_idx = None
    record_start = 0

    def close_record(end):
        nonlocal has_version, accession_idx
        if locus is not None and not has_version:
            insert_at = accession_idx + 1 if accession_idx is not None else record_start + 1
            out.insert(insert_at, f"VERSION     {locus}")

    for raw in text.splitlines():
        if raw.startswith("LOCUS "):
            locus = raw.split()[1]
            has_version = False
            accession_idx = None
            record_start = len(out)
            versions.setdefault(locus, "")
            out.append(raw)
        elif raw.startswith("ACCESSION "):
            accession_idx = len(out)
            out.append(raw)
        elif raw.startswith("VERSION ") and locus is not None:
            token = raw.split()[1] if len(raw.split()) > 1 else ""
            versions[locus] = token
            has_version = True
            out.append(f"VERSION     {locus}")
        elif raw.strip() == "//":
            close_record(len(out))
            out.append(raw)
            locus = None
        else:
            out.append(raw)
    if locus is not None:  # file without a closing //
        close_record(len(out))
    return "\n".join(out) + "\n", versions


# ----------------------------------------------------------------------------------------------
# Pass 2: BioPython, for sequences and features.
# ----------------------------------------------------------------------------------------------
def source_type(record):
    for f in record.features:
        if f.type != "source":
            continue
        q = f.qualifiers
        if "organelle" in q:
            return q["organelle"][0].strip().lower(), q.get("chromosome", [""])[0]
        if "plasmid" in q:
            return "plasmid", q.get("chromosome", [""])[0]
        if "chromosome" in q:
            return "chromosome", q["chromosome"][0]
        return "other", ""
    return "other", ""


def feature_parts(feature):
    """Location parts in transcription order: ascending on +, descending on -."""
    parts = list(feature.location.parts)
    strand = feature.location.strand
    parts.sort(key=lambda p: int(p.start), reverse=(strand == -1))
    return parts, strand


def gff_records_for(record, locus, verdicts):
    """GFF3 lines: gene features as genes; CDS features as mRNA > exon + CDS (phase from codon_start)."""
    lines = [f"##sequence-region {locus} 1 {len(record.seq)}"]
    gene_ids = {}  # locus_tag or gene -> gene ID, to attach mRNAs
    n_auto = 0

    def ident(q, fallback):
        for key in ("locus_tag", "gene", "protein_id"):
            if key in q:
                return q[key][0]
        return fallback

    for f in record.features:
        if f.type != "gene":
            continue
        n_auto += 1
        gid = ident(f.qualifiers, f"gene{n_auto}")
        gene_ids[gid] = gid
        name = f.qualifiers.get("gene", [gid])[0]
        strand = "+" if f.location.strand != -1 else "-"
        attrs = f"ID={gff_escape(gid)};Name={gff_escape(name)}"
        if "locus_tag" in f.qualifiers and "gene" in f.qualifiers:
            attrs += f";locus_tag={gff_escape(f.qualifiers['locus_tag'][0])}"
        lines.append("\t".join([locus, "genbank", "gene", str(int(f.location.start) + 1),
                                str(int(f.location.end)), ".", strand, ".", attrs]))

    n_cds = 0
    for f in record.features:
        if f.type != "CDS":
            continue
        n_cds += 1
        q = f.qualifiers
        gid = ident(q, f"cds{n_cds}")
        name = q.get("gene", [gid])[0]
        parts, strand_int = feature_parts(f)
        strand = "+" if strand_int != -1 else "-"
        start = min(int(p.start) for p in parts) + 1
        end = max(int(p.end) for p in parts)
        if gid not in gene_ids:  # CDS without a gene feature: synthesise the gene from its span
            gene_ids[gid] = gid
            lines.append("\t".join([locus, "genbank", "gene", str(start), str(end), ".", strand, ".",
                                    f"ID={gff_escape(gid)};Name={gff_escape(name)}"]))
        tid = f"{gid}_mRNA"
        if q.get("protein_id"):
            tid = q["protein_id"][0]
        lines.append("\t".join([locus, "genbank", "mRNA", str(start), str(end), ".", strand, ".",
                                f"ID={gff_escape(tid)};Parent={gff_escape(gid)};Name={gff_escape(name)}"]))
        phase = int(q.get("codon_start", ["1"])[0]) - 1
        consumed = 0
        for i, p in enumerate(parts, 1):
            ps, pe = int(p.start) + 1, int(p.end)
            lines.append("\t".join([locus, "genbank", "exon", str(ps), str(pe), ".", strand, ".",
                                    f"ID={gff_escape(tid)}-E{i};Parent={gff_escape(tid)}"]))
            part_phase = (3 - ((consumed - phase) % 3)) % 3 if i > 1 else phase
            lines.append("\t".join([locus, "genbank", "CDS", str(ps), str(pe), ".", strand, str(part_phase),
                                    f"ID={gff_escape(tid)}-CDS;Parent={gff_escape(tid)}"]))
            consumed += pe - ps + 1
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--genbank", required=True, help="GenBank file (.gb/.gbk/.gbff, optionally gzipped)")
    ap.add_argument("--db", required=True, help="snpEff database name (= the cache directory name)")
    ap.add_argument("--outdir", default=".", help="where the outputs go (default: cwd)")
    ap.add_argument("--source-name", default=None,
                    help="file name to record in the manifest header (default: the --genbank basename)")
    args = ap.parse_args()

    src_name = args.source_name or os.path.basename(args.genbank)
    db = args.db
    out = args.outdir
    os.makedirs(os.path.join(out, db), exist_ok=True)
    verdicts = Verdicts()

    with open_text(args.genbank) as fh:
        text = fh.read()
    rewritten, versions = rewrite_versions(text)
    records = list(SeqIO.parse(io.StringIO(text), "genbank"))

    if not records:
        verdicts.add("ERROR", "GenBank contig identifiers", f"{src_name}: no GenBank record found")
        verdicts.write(os.path.join(out, "preflight_genbank_mqc.tsv"))
        sys.exit(65)

    # ---- identifiers -------------------------------------------------------------------------
    seen = OrderedDict()
    bad = []
    no_seq = []
    no_accession = []
    for rec in records:
        locus = rec.name
        seen[locus] = seen.get(locus, 0) + 1
        if BAD_ID_CHARS.search(locus):
            bad.append(locus)
        try:
            if len(rec.seq) == 0:
                no_seq.append(locus)
            else:
                str(rec.seq[:1])
        except Exception:  # Bio.Seq.UndefinedSequenceError on CONTIG-only records
            no_seq.append(locus)
        v = versions.get(locus, "")
        if v in ("", ".", locus):
            no_accession.append(locus)
    dups = [k for k, n in seen.items() if n > 1]
    simple = OrderedDict()
    for rec in records:
        simple.setdefault(snpeff_simple_name(rec.name), []).append(rec.name)
    collisions = [v for v in simple.values() if len(set(v)) > 1]
    renamed = [f"{l} as {sn}" for sn, ls in simple.items() for l in ls if l != sn]
    n = len(records)
    check = "GenBank contig identifiers"
    renamed_note = ""
    if renamed:
        renamed_note = f". snpEff stores {len(renamed)} name(s) simplified ({', '.join(renamed[:4])}{'…' if len(renamed) > 4 else ''}); VCFs, tables and reports keep the LOCUS name"
    if dups or bad or no_seq or collisions:
        parts = []
        if dups:
            parts.append(f"duplicate LOCUS name(s): {', '.join(dups)}")
        if collisions:
            parts.append("LOCUS names snpEff would store under one simplified name (it strips a leading chr/chromo/chromosome and leading zeros): " + "; ".join(" and ".join(sorted(set(v))) for v in collisions))
        if bad:
            parts.append(f"LOCUS name(s) with whitespace, colon, pipe or a GFF3/VCF reserved character: {', '.join(bad)}")
        if no_seq:
            parts.append(f"record(s) without sequence (CONTIG-only?): {', '.join(no_seq)}")
        verdicts.add("ERROR", check, f"{src_name}: {'; '.join(parts)}. The LOCUS name is the contig identifier in every output; fix the file and rerun")
    else:
        names = f"{', '.join(r.name for r in records[:6])}{'…' if n > 6 else ''}"
        if no_accession:
            # A lab-made file (SnapGene, Benchling, Prokka) is a first-class input: a note, not a warning.
            accession_note = (f"no versioned accession on {len(no_accession)} of {n} (VERSION missing or equal to LOCUS: "
                              f"{', '.join(no_accession[:8])}{'…' if len(no_accession) > 8 else ''}), as usual for a lab-made file; "
                              "a database registration matches these contigs by sequence md5 (contig_manifest.csv)")
        else:
            accession_note = "every one with a versioned accession"
        verdicts.add("OK", check, f"{src_name}: {n} record(s), contig names are the LOCUS names ({names}); {accession_note}{renamed_note}")

    if verdicts.errors:
        verdicts.write(os.path.join(out, "preflight_genbank_mqc.tsv"))
        print(f"{PREFIX} {verdicts.errors} GenBank check(s) failed, stopping the run", file=sys.stderr)
        sys.exit(65)

    # ---- genetic code per contig --------------------------------------------------------------
    tables = OrderedDict()     # locus -> set of stated tables
    has_cds = OrderedDict()    # locus -> CDS count
    for rec in records:
        stated = set()
        cnt = 0
        for f in rec.features:
            if f.type != "CDS":
                continue
            cnt += 1
            if "transl_table" in f.qualifiers:
                stated.add(int(f.qualifiers["transl_table"][0]))
        tables[rec.name] = stated
        has_cds[rec.name] = cnt
    mixed = [l for l, s in tables.items() if len(s) > 1]
    unknown = sorted({t for s in tables.values() for t in s if t not in CODON_TABLES})
    organelle = {rec.name for rec in records if source_type(rec)[0] not in ("chromosome", "plasmid", "other")}
    assumed = [l for l, s in tables.items() if not s and has_cds[l] > 0 and l in organelle]
    defaulted = [l for l, s in tables.items() if not s and has_cds[l] > 0 and l not in organelle]
    chosen = OrderedDict()     # locus -> table number or None (no CDS)
    for l, s in tables.items():
        chosen[l] = next(iter(s)) if len(s) == 1 else (1 if has_cds[l] > 0 else None)
    check = "GenBank genetic code"
    if mixed or unknown:
        parts = []
        if mixed:
            parts.append("contig(s) whose CDS state different /transl_table values: " + ", ".join(f"{l} ({', '.join(str(t) for t in sorted(tables[l]))})" for l in mixed))
        if unknown:
            parts.append(f"/transl_table value(s) snpEff 5.1 has no codon table for: {', '.join(str(t) for t in unknown)}")
        verdicts.add("ERROR", check, f"{src_name}: {'; '.join(parts)}. snpEff takes one genetic code per contig from the cache config; fix the CDS qualifiers and rerun")
    else:
        non_std = [(l, t) for l, t in chosen.items() if t not in (None, 1)]
        desc = ", ".join(f"{l}={t} ({CODON_TABLES[t]})" for l, t in non_std) if non_std else "no contig uses a non-standard code"
        n_std = sum(1 for l, t in chosen.items() if t == 1 and l not in assumed)
        std_note = f"{n_std} contig(s) standard" + (f" ({len(defaulted)} by the INSDC default, no /transl_table)" if defaulted else "")
        if assumed:
            verdicts.add("WARN", check, f"{src_name}: organelle contig(s) whose CDS state no /transl_table: {', '.join(assumed[:8])}{'…' if len(assumed) > 8 else ''}. The standard code is assumed, which organelles rarely use (yeast mitochondria: table 3); the translation of every coding variant there depends on it. Add /transl_table=N to the CDS features and rerun. Stated: {desc}; {std_note}")
        else:
            verdicts.add("OK", check, f"{src_name}: {desc}; {std_note}")

    if verdicts.errors:
        verdicts.write(os.path.join(out, "preflight_genbank_mqc.tsv"))
        print(f"{PREFIX} {verdicts.errors} GenBank check(s) failed, stopping the run", file=sys.stderr)
        sys.exit(65)

    # ---- outputs ------------------------------------------------------------------------------
    sha = file_sha256(args.genbank)
    with open(os.path.join(out, f"{db}.fa"), "w") as fa, \
         open(os.path.join(out, f"{db}.gff3"), "w") as gff, \
         open(os.path.join(out, "contig_manifest.csv"), "w", newline="") as mf:
        gff.write("##gff-version 3\n")
        mf.write(f"# genbank: {src_name}\n# sha256: {sha}\n# db: {db}\n")
        w = csv.writer(mf)
        w.writerow(["contig", "version", "length", "md5", "type", "chromosome", "transl_table", "order"])
        for i, rec in enumerate(records, 1):
            locus = rec.name
            seq = str(rec.seq).upper()
            fa.write(f">{locus}\n")
            for j in range(0, len(seq), 60):
                fa.write(seq[j:j + 60] + "\n")
            ctype, chrom = source_type(rec)
            v = versions.get(locus, "")
            t = chosen[locus]
            t_str = "" if t is None else (f"{t} (assumed)" if locus in assumed else str(t))
            w.writerow([locus, "" if v in (".", locus) else v, len(seq), hashlib.md5(seq.encode()).hexdigest(),
                        ctype, chrom, t_str, i])
            for line in gff_records_for(rec, locus, verdicts):
                gff.write(line + "\n")

    with open(os.path.join(out, db, "genes.gbk"), "w") as fh:
        fh.write(rewritten)
    with open(os.path.join(out, "expected_cache_contigs.txt"), "w") as fh:
        for rec in records:
            if rec.features:   # a record with no feature at all is dropped by snpEff's build
                fh.write(snpeff_simple_name(rec.name) + "\n")
    with open(os.path.join(out, db, "snpEff.config"), "w") as fh:
        fh.write(f"{db}.genome : {db}\n")
        for locus, t in chosen.items():
            if t not in (None, 1):
                fh.write(f"{db}.{locus}.codonTable : {CODON_TABLES[t]}\n")

    verdicts.write(os.path.join(out, "preflight_genbank_mqc.tsv"))


if __name__ == "__main__":
    main()
