#!/usr/bin/env python
"""Regenerate the synthetic GenBank fixtures of tests/genbank_reference.nf.test and tests/snpeff_build.nf.test.

Run in the pipeline's BioPython container from the repo root (deterministic: seeded random sequences,
BioPython 1.81 writer, the date field is fixed by SeqIO):

    docker run --rm -u $(id -u):$(id -g) -v $PWD:/r -w /r quay.io/biocontainers/biopython:1.81 \
        python -I tests/fixtures/genbank/make_fixtures.py tests/fixtures/genbank

mito_ncbi.gbff is the real NC_001224 record of the NCBI S288C R64 assembly (data/ottilie/S288C_reference/
S288C_R64.gbff, cut at the record terminator); mito_ncbi.gbff.gz is its gzip. Both are inputs here, not
outputs. What this script derives, and why each exists, is in tests/fixtures/README.md.
"""
import re, random, sys
F = sys.argv[1]
# ---- lab-style draft from the NCBI Mito record: LOCUS mito_draft, no ACCESSION/VERSION, /chromosome="M"
#      on the source feature (snpEff would name the contig "M" without the VERSION rewrite), no
#      /transl_table and no /translation (a draft annotated by a gene caller that writes neither)
txt = open(f'{F}/mito_ncbi.gbff').read()
out = []
skip_translation = False
for l in txt.splitlines():
    if skip_translation:
        # continuation lines of a multi-line /translation are 21 spaces + residues (no '/');
        # a new qualifier (21 spaces + '/') or a new feature (5 spaces + type) ends it
        if l.startswith('                     ') and not l.startswith('                     /'):
            continue
        skip_translation = False
    if l.startswith('LOCUS'):
        l = l.replace('NC_001224  ', 'mito_draft ', 1)
    if l.startswith('ACCESSION') or l.startswith('VERSION') or l.startswith('DBLINK'):
        continue
    if '/transl_table=' in l:
        continue
    if l.startswith('                     /translation='):
        skip_translation = not l.rstrip().endswith('"')
        continue
    if l.startswith('                     /organelle='):
        out.append(l); out.append('                     /chromosome="M"'); continue
    out.append(l)
open(f'{F}/mito_draft.gb', 'w').write('\n'.join(out) + '\n')
print('mito_draft: translations left', open(f'{F}/mito_draft.gb').read().count('/translation='), 'transl_table left', open(f'{F}/mito_draft.gb').read().count('/transl_table'))

# ---- the NCBI Mito record renamed by a user to LOCUS chrM, everything else kept (ACCESSION, VERSION
#      NC_001224.1, /transl_table=3, /translation): snpEff stores the contig as "M" (it strips a
#      leading "chr"), the codonTable line is keyed on the LOCUS name chrM, and a VCF with CHROM chrM
#      must still annotate with the mitochondrial code (measured 2026-11-09; pinned by
#      tests/snpeff_codon_table.nf.test and tests/genbank_reference.nf.test)
out = []
for l in txt.splitlines():
    if l.startswith('LOCUS'):
        l = l.replace('NC_001224', 'chrM     ', 1)
    out.append(l)
open(f'{F}/mito_chrM.gbff', 'w').write('\n'.join(out) + '\n')
print('mito_chrM:', [l for l in out if l.startswith('LOCUS') or l.startswith('VERSION')])

# ---- synthetic two-record file (BioPython-written, deterministic)
from Bio.Seq import Seq
from Bio.SeqRecord import SeqRecord
from Bio.SeqFeature import SeqFeature, SimpleLocation, CompoundLocation
from Bio import SeqIO
random.seed(11)
def rnd(n): return ''.join(random.choice('ACGT') for _ in range(n))
def orf(n_codons):   # ATG + random sense codons (no stop) + TAA
    stops = {'TAA','TAG','TGA'}
    body = []
    while len(body) < n_codons - 2:
        c = rnd(3)
        if c not in stops: body.append(c)
    return 'ATG' + ''.join(body) + 'TAA'
# plasmidA: 2400 bp. CDS1 + strand 101..400 (100 codons, table 11). CDS2 - strand, join of two exons
# (intron 1201..1260): exon parts 1001..1200 and 1261..1460, codon_start 1. CDS3 + strand 1801..2101
# with codon_start=2 (phase 1): 300 bp starting one base early.
seqA = rnd(100) + orf(100) + rnd(600)                       # 1..1000
cds2 = orf(133)                                             # 399 bp -> two exons 200 + 199
intron = 'GT' + rnd(56) + 'AG'
rc2 = str(Seq(cds2).reverse_complement())
seqA += rc2[:200] + intron + rc2[200:] + rnd(2400 - 1000 - 200 - 60 - 199)
seqA = seqA[:1800] + 'G' + orf(100) + seqA[1800 + 301:]
seqA = seqA[:2400]
recA = SeqRecord(Seq(seqA), id='plasmidA', name='plasmidA', description='synthetic test plasmid')
recA.annotations.update(molecule_type='DNA', topology='circular', data_file_division='SYN')
recA.features.append(SeqFeature(SimpleLocation(0, 2400, 1), type='source', qualifiers={'organism': ['synthetic construct'], 'mol_type': ['genomic DNA'], 'plasmid': ['pTest']}))
def gene_cds(loc, tag, gene, table, codon_start=1):
    recA.features.append(SeqFeature(loc, type='gene', qualifiers={'gene': [gene], 'locus_tag': [tag]}))
    q = {'gene': [gene], 'locus_tag': [tag], 'codon_start': [str(codon_start)], 'product': [f'{gene} protein']}
    if table: q['transl_table'] = [str(table)]
    recA.features.append(SeqFeature(loc, type='CDS', qualifiers=q))
gene_cds(SimpleLocation(100, 400, 1), 'TST_001', 'tstA', 11)
gene_cds(CompoundLocation([SimpleLocation(1260, 1459, -1), SimpleLocation(1000, 1200, -1)]), 'TST_002', 'tstB', 11)
gene_cds(SimpleLocation(1800, 2101, 1), 'TST_003', 'tstC', 11, codon_start=2)
# chrB: 1500 bp, one CDS with NO transl_table (standard assumed -> WARN), source with /chromosome="B"
seqB = rnd(200) + orf(150) + rnd(1500 - 200 - 450)
recB = SeqRecord(Seq(seqB), id='chrB', name='chrB', description='synthetic test chromosome')
recB.annotations.update(molecule_type='DNA', topology='linear', data_file_division='SYN')
recB.features.append(SeqFeature(SimpleLocation(0, 1500, 1), type='source', qualifiers={'organism': ['synthetic construct'], 'mol_type': ['genomic DNA'], 'chromosome': ['B']}))
recB.features.append(SeqFeature(SimpleLocation(200, 650, 1), type='gene', qualifiers={'gene': ['tstD'], 'locus_tag': ['TST_004']}))
recB.features.append(SeqFeature(SimpleLocation(200, 650, 1), type='CDS', qualifiers={'gene': ['tstD'], 'locus_tag': ['TST_004'], 'codon_start': ['1'], 'product': ['tstD protein']}))
SeqIO.write([recA, recB], f'{F}/synthetic_two_records.gb', 'genbank')
# duplicate LOCUS: plasmidA twice
SeqIO.write([recA, recA], f'{F}/synthetic_duplicate_locus.gb', 'genbank')
# mixed tables: plasmidA with CDS3 on table 4
import copy
recM = copy.deepcopy(recA)
for f in recM.features:
    if f.type == 'CDS' and f.qualifiers['locus_tag'] == ['TST_003']: f.qualifiers['transl_table'] = ['4']
SeqIO.write([recM], f'{F}/synthetic_mixed_tables.gb', 'genbank')
# name collision: LOCUS chr1 and LOCUS 1 are both stored as "1" by snpEff (it strips the chr prefix)
seqC = rnd(100) + orf(50) + rnd(100)
recs = []
for nm in ('chr1', '1'):
    r = SeqRecord(Seq(seqC), id=nm, name=nm, description='synthetic name collision')
    r.annotations.update(molecule_type='DNA', topology='linear', data_file_division='SYN')
    r.features.append(SeqFeature(SimpleLocation(0, 350, 1), type='source', qualifiers={'organism': ['synthetic construct'], 'mol_type': ['genomic DNA']}))
    r.features.append(SeqFeature(SimpleLocation(100, 250, 1), type='CDS', qualifiers={'locus_tag': [f'g_{nm}'], 'codon_start': ['1'], 'transl_table': ['11']}))
    recs.append(r)
SeqIO.write(recs, f'{F}/synthetic_name_collision.gb', 'genbank')
print('synthetic written')
