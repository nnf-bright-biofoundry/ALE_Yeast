# GenBank route: non-coding gene models and a GenBank plausibility check

**Status: open for re-investigation after O.9** (`PLAN_next_checklist.md` §O). Written 2026-11-10 from the
review of commit `ea58d84` (the `--genbank` wiring). Nothing here blocks O.3 to O.8; it records two defects in
how the snpEff database models non-coding genes, one on each route, and a check that would have exposed them.

## 1. What was measured

Measured on 2026-11-10 (labels per `testing_best_practices.md` §13):

| Claim | Evidence | Label |
|---|---|---|
| The pre-built cache stores all **299 tRNA transcripts as `protein_coding`** with exons and no CDS | `snpEffectPredictor.bin` of `data/ottilie/S288C_reference/snpeff_cache/R64-1-1.105` (gzipped tab text): 7,127 `TRANSCRIPT` lines, 299 flagged coding without a `CDS` child; the `genes.gff` it was built from carries 299 `tRNA` transcripts with `biotype=tRNA` and exons only | measured |
| snpEff 5.1's GFF3 parser accepts the snoRNA, rRNA, snRNA and ncRNA biotypes but not `tRNA` | same file: 77 snoRNA, 24 rRNA, 6 snRNA, 18 lincRNA stored as such; the 299 tRNAs are the only non-coding transcripts stored as coding | inferred from the counts |
| On the GenBank route **120 of 2,070 genes have no transcript model** on the four test chromosomes | the database built by a full run of the test set on commit `ea58d84` with `-params-file tests/qc_gate_genbank_params.yml`: 2,070 `GENE`, 1,950 `TRANSCRIPT` lines; the record holds 74 `tRNA`, 32 `ncRNA`, 1,904 `CDS` features | measured |
| `snpEff build -genbank` makes transcripts from CDS features only | the 120 above are the tRNA and ncRNA features plus a few pseudogenes; every transcript has a CDS | inferred |
| The 12 annotation differences between the routes on the test set (88 of 100 records identical in effect and gene) are gene-model differences, none at a truth SNV, none evolved-only | record-by-record comparison of the two annotated joint VCFs (the e2e output of the same commit and the run above); the four truth SNVs annotate identically to the protein change; 11 sites are in both samples, 1 in the parent only | measured |

The 12, by cause:

- **Dubious ORFs that RefSeq dropped** (5 sites, all PASS): YAL004W over SSA1, YAL016C-B, YAR023C, YDR537C. The
  old route reported a missense change in a dubious ORF where the new one reports a synonymous change in SSA1.
  The GenBank route is right; two sites leave the dashboard's protein-changing bucket.
- **Ty retrotransposon regions** (5 sites, all MQ-filtered): Ensembl's unnamed `EXON_…` fragments against RefSeq's
  named Ty ORFs. Invisible in the PASS-only tables either way.
- **tRNA genes** (2 sites, both PASS, IV:1150910 and IV:1305680): the old route's `HIGH frameshift_variant` in
  tS(AGA)D3 and tX(XXX)D is the defect in row 1 of the table, a tRNA has no reading frame. The new route reports
  `intragenic_variant`, MODIFIER, with the tRNA's systematic id (YNCD0028W) and names the neighbouring protein
  gene first. Less wrong, but the "inside a non-coding gene" effect is gone.

## 2. What to change, after O.9

1. **Transcript models for non-coding genes in the extractor** (`bin/genbank_to_reference.py`): write a
   `transcript` plus `exon` for tRNA, rRNA, ncRNA, snoRNA, snRNA and misc_RNA features with a biotype snpEff
   parses (`ncRNA` did, `tRNA` did not; measure the mapping before relying on it), then either build from that
   GFF3 or keep `-genbank` and accept the gap. The protein check must keep working either way. Expected result:
   `non_coding_transcript_exon_variant` on the named gene; the impact stays MODIFIER, so the dashboard ordering
   does not move. Test on the Mito record (`tests/fixtures/genbank/mito_ncbi.gbff`, 24 tRNAs and 2 rRNAs).
2. **A fifth input-checks row from the extract task, "annotation model completeness"**: the feature inventory
   (CDS, mRNA, tRNA, rRNA, ncRNA, pseudogenes) and the count plus a short list of genes that got no transcript
   model, with the consequence stated ("variants inside them annotate as intragenic"). This is the row that
   would have shown both defects above. One row first, per the project's checker rule; the candidates below
   wait for a fixture each.
3. **Lineage-based plausibility, candidates only.** The header has what they need: the `ORGANISM` lineage
   (`Eukaryota` or `Bacteria`), the LOCUS topology (`linear`/`circular`), and the feature table.
   - Bacteria with a `/transl_table` other than 11; a nuclear eukaryotic contig with one other than 1.
   - A circular nuclear chromosome of a eukaryote; a linear bacterial chromosome without a reason.
   - A bacterial genome with no tRNA or rRNA feature (an incomplete annotation, not an unusual organism).
   - A eukaryote whose CDS all lack `join()` locations and whose record has no mRNA features (normal for yeast,
     a CDS-only draft for anything with introns).
   - Gene density far outside the lineage's range, a sanity bound on design-tool exports.
   The O.9 fixtures (Prokka-style bacterial record, SnapGene export) are the files these rows would fire on.

## 3. Reproducing the counts

```bash
# pre-built cache: transcripts flagged coding with no CDS child (field 9 biotype, field 10 coding flag)
zcat data/ottilie/S288C_reference/snpeff_cache/R64-1-1.105/snpEffectPredictor.bin | gawk -F'\t' \
  '$1=="TRANSCRIPT"{bt[$9]++; if($10=="true") pc[$2]=1} $1=="CDS"{cds[$3]=1}
   END{for(b in bt) print b, bt[b]; n=0; for(i in pc) if(!(i in cds)) n++; print "coding without CDS:", n}'
# GenBank route: genes without a transcript (field 3 of TRANSCRIPT = parent gene id)
zcat <outdir>/reference/S288C_R64_test/snpeff_cache/S288C_R64_test/snpEffectPredictor.bin | gawk -F'\t' \
  '$1=="GENE"{gid[$2]=1} $1=="TRANSCRIPT"{pg[$3]=1} END{n=0; for(i in gid) if(!(i in pg)) n++; print n}'
```
The `<outdir>` is a full run of the test set on the GenBank route:
`nextflow run main.nf -profile ottilie_test,azureD4as,docker --outdir <outdir>` (about 10 minutes; the profile
gives the test GenBank since 2026-11-11, before that the run needed a params file clearing the pre-built files).
