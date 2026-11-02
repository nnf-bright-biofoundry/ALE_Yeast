# CNVKit names chromosome X by its literal name: what that does to yeast outputs

**Measured 2026-11-02** in the pipeline's own container, `quay.io/biocontainers/cnvkit:0.9.11--pyhdfd78af_0`
(the image of `modules/nf-core/cnvkit/reference`; `cnvkit/batch` runs the same CNVKit in a mulled image), by
reading `cnvlib/` as installed. Written for the GenBank reference work (`docs/dev-practices/genbank_reference_input.md`,
decision 16), where contig names change from Ensembl's roman numerals to the GenBank LOCUS names. No code or
config change follows from it; this note is the record.

## The rule

- **Naming.** `cnary.py`, `chr_x_label`: a contig is "chromosome X" when its name is exactly `X`, or `chrX` when the
  first contig's name starts with `chr`; "Y" and `chrY` likewise. Nothing else is looked at. So yeast chromosome X
  under roman names (`X`) is seen as the sex chromosome; under NCBI LOCUS names it is `NC_001142` and the rule
  never fires. A lab GenBank with a record named `X` or `chrX` triggers it again.
- **The sex guess.** `guess_xx` compares X (and Y) coverage with the autosomes: X at the autosomal level reads as
  female, X at half the level as male. Yeast has no `Y`, and a euploid yeast chromosome X sits at the autosomal
  level, so the normal verdict is female.

## What the guess changes, and what it does not

Checked by grepping every use of `guess_xx`, `shift_xx`, `chr_x_filter` and `is_haploid_x_reference`:

| Step | Uses the guess? | Effect on yeast |
|---|---|---|
| `reference` (flat, built without `-y`) | `expect_flat_log2`: only a `Y` contig is set to single copy | none, no `Y` |
| `fix` | no | `.cnr` unaffected |
| `segment` | no | `.cns` unaffected |
| `call --filter ci` (no `--purity`) | `absolute_threshold` → `_reference_copies_pure`: halves the reference copies for `Y`, and for `X` only with `-y` | none without `-y` |
| `batch --diagram` | **yes**: `shift_xx` adds 1 to chromosome X log2 when the sample is guessed male | the diagram PDF only |
| `export vcf` | **yes**: `segments2vcf` takes the expected copy number of X as 1 for a guessed-male sample | the CNVKit VCF only |

So the files the Tier-1 deliverables read (`.cnr`, `.cns`, the fold-change matrices of `cnvkit_cn_calculation.md`,
the dashboard) never see the guess. Two outputs do: the per-sample diagram PDF and the CNVKit VCF export.

## When it bites

A genuine loss of chromosome X in a diploid strain, log2 near minus 1, is exactly the signature `guess_xx` reads
as male. For that sample the CNVKit VCF reports the single copy as the expected state and the diagram shifts the
chromosome back to 0: the real event disappears from those two outputs, while the fold-change matrices still
show it. Under roman names this is live today; under LOCUS names it is moot for NCBI files.

## Parameters the pipeline exposes

None of CNVKit's sex controls. `conf/modules/cnvkit.config` passes `--method wgs --diagram --scatter` to batch
and `--filter ci` to call; `wes` switches the method; `cnvkit_reference` admits a pre-built reference. CNVKit's
`--sample-sex female` (batch and export) would pin the guess and remove the artefact, one `ext.args` addition if
ever wanted. The 4-chromosome test set (I, IV, VII, XV) cannot show any of this; the next full-genome pilot can.
