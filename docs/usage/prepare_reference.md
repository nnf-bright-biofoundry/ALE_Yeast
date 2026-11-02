# Preparing a reference: FASTA, GFF3 and the SnpEff cache

What the pipeline needs from *your* genome, and the two scripted ways to produce it. Docker is the only
prerequisite for both. Everything here is what the Ottilie/S288C test data itself was built with.

## What the pipeline consumes

| Parameter | Needed? | What |
|---|---|---|
| `--fasta` | yes | Reference FASTA. `.fai`, `.dict` and the bwa-mem2 index are built in-run (seconds on yeast). |
| `--snpeff_cache` + `--snpeff_db` | yes when `snpeff` is in `--tools` (the Tier-1 recipe) | A SnpEff database **directory**: `<snpeff_cache>/<snpeff_db>/snpEffectPredictor.bin` plus `sequence*.bin` and `snpEff.config`; `--snpeff_db` is that directory's name. There is **no default**: omitting it fails at launch with `Please specify --snpeff_cache …`. |
| `--report_gff3` | optional | GFF3 for the gene track in the igv-reports dashboard. Without it the reports have no gene track. An uncompressed file whose name ends in `.gff3` or `.gff`: another name, or a local path that does not exist, stops the run at parameter validation. Its contig names must be the FASTA's: checked by the first task of every run ([`preflight_checks.md`](preflight_checks.md) → *Reference files*). |
| `--genbank` | Tier-2 only | breseq input (not part of the Tier-1 recipe). |
| `--chr_dir` | Tier-2 only | Per-chromosome FASTAs for Control-FREEC. |

Rules that apply to the SnpEff cache whichever way you build it:

- **snpEff version lock.** Build with the version the pipeline's module runs, **5.1**
  (`quay.io/biocontainers/snpeff:5.1--hdfd78af_2`). snpEff refuses a database from a newer version:
  `Database version: '5.2', Program version: '5.1'`. Both scripts below pin that image. A sarek rebase
  that bumps snpEff means rebuilding every cache; see `docs/dev-practices/ale_sarek_upgrade_runbook.md`
  → *Known Rebase Hazards: SnpEff cache*.
- **Flat layout.** `<snpeff_cache>/<snpeff_db>/…`, not the `<db>/<db>/` form that nf-core's
  `annotation-cache` bucket uses.
- **Chromosome names** in the annotation must equal the FASTA headers. On a mismatch snpEff builds
  happily and then annotates *nothing*, with no error (nf-core/sarek #415). `build_snpeff_cache.sh`
  checks this; `process_genbank_auto.sh` derives both from the same GenBank so they agree by construction.
  The pipeline checks the `--report_gff3` file against the FASTA at the start of every run
  (`PREFLIGHT_REFERENCE`: error when no contig name is shared; GFF3 contigs the FASTA lacks are only
  noted, see [`preflight_checks.md`](preflight_checks.md)); the cache itself is **not** checked at start-up.
- **Runtime files only are needed**: `snpEffectPredictor.bin`, `sequence*.bin`, `snpEff.config` (~6 MB
  for yeast). `genes.gff` and `sequences.fa` are build inputs and may be left out of what you ship.
  `snpEff.config` is not a formality: it carries the genetic code per contig (see *Genetic code* below).
- **Running from cloud storage** (Seqera, AWS Batch, HPC): upload the directory to your own bucket and
  pass the `az://` / `s3://` / `gs://` path; see the README section *Running the SnpEff cache from cloud
  storage*. An https URL cannot be used for a directory.

## Path A: from a GenBank file

```bash
bash docs/prepare_input/process_GeneBank/process_genbank_auto.sh <input.gbk> [output_dir]
```

One script, all three outputs: FASTA (via `any2fasta`), GFF3 (its own BioPython converter) and the
SnpEff cache built from those two. `--snpeff_db` is the genome name derived from the GenBank `ORGANISM`
field (lowercase, spaces → underscores; e.g. `Saccharomyces cerevisiae S288C` → `saccharomyces_cerevisiae_s288c`),
matching the `snpeff_cache/<name>/` directory. The script prints the exact `--fasta`, `--snpeff_cache`,
`--snpeff_db` values and records the name in `organism_info.sh`; use the produced GFF3 as `--report_gff3`.

**Verified 2026-09-08** on the 4-chromosome S288C test GenBank: runs clean, cache loads, chromosome names
match. Against the project's Ensembl-built cache on the 100-variant contract-test VCF: 89/100 same
primary effect, 92/100 same impact, all 4 truth SNVs identical in effect and impact.

⚠️ **Known limitation: the GenBank → GFF3 step is lossy** (roadmap item). It writes every feature as
one flat line: no gene → mRNA → CDS `Parent` links, no CDS phase, and the `/gene=` symbols are dropped
(`ID=locus_tag`, `Name=product`). Consequences: snpEff invents one transcript per CDS
(`WARNING_TRANSCRIPT_NOT_FOUND … Created transcript` throughout the build log); multi-exon CDS are
collapsed to a single span (83 of 1,949 CDS on S288C; 3 of the 11 changed calls above sit on such genes, the
other 8 are frame and feature-type artefacts of the flat conversion: tRNAs written like CDS-less genes,
no phase); and
reports show systematic names (`YDL140C`) where the Ensembl cache shows gene symbols (`RPO21`). Tolerable
for a nearly intronless yeast, wrong for an intron-rich genome. If your GenBank comes from an Ensembl or
NCBI genome that also has a GFF3, prefer Path B. Path A also writes no `codonTable` line, although the
GenBank's `/transl_table` says which contigs need one: append it by hand (see *Genetic code* under Path B).

## Path B: from FASTA + GFF3 (Ensembl, NCBI, or your own annotation)

```bash
bash docs/prepare_input/build_snpeff_cache.sh <snpeff_db> <reference.fa> <annotation.gff3> [out_dir] [genome_description]
# e.g. the project's own S288C cache, byte for byte (the mitochondrion uses genetic code 3):
CODON_TABLES=Mito=Yeast_Mitochondrial \
bash docs/prepare_input/build_snpeff_cache.sh R64-1-1.105 S288C_R64.fa S288C_R64.gff3 ./ref Saccharomyces_cerevisiae
```

Builds only the cache (you already have the FASTA and the GFF3; pass the same GFF3 as `--report_gff3`).
It checks the contig names, strips the Ensembl `gene:` / `transcript:` / `CDS:` ID prefixes and exon
`Name=` / `exon_id=` attributes that break snpEff 5.1's gene models (a no-op on other GFF3s), builds with
`-noCheckCds -noCheckProtein`, keeps snpEff's build log next to the cache, and prints the parameters.
Pick any `<snpeff_db>` name; the convention here is `<assembly>.<annotation release>` (`R64-1-1.105`).

**Verified 2026-09-08**: rebuilding `R64-1-1.105` from the published `S288C_R64.fa` + `S288C_R64.gff3` with
the original description `Saccharomyces_cerevisiae` reproduces the project's cache **byte for byte** (all
five files). The build is deterministic: same snpEff, FASTA, GFF3 and description give the same bytes, so a
checksum is a valid way to confirm a cache. The optional last argument is that description, the free-text
`<db>.genome : <description>` line of `snpEff.config`. It is stored inside both `.bin` files but does not
affect annotation: built with the default description (the db name) the `.bin` files differ from the
project's by exactly that one string, and the 100 contract-test variants annotate identically.
**Re-verified 2026-11-02** with `CODON_TABLES=Mito=Yeast_Mitochondrial`: all four runtime files equal the
cache as shipped since that date, the codon-table line included.

### Genetic code (`codonTable`): the one thing the GFF3 cannot tell snpEff

snpEff ignores the annotation's `/transl_table` and stores no genetic code in the `.bin` files. The code is a
line per contig in the cache's `snpEff.config`, `<db>.<contig>.codonTable : <Table>`, read at annotation
time; a contig without one is translated with the standard code. For yeast that is wrong on the
mitochondrion (code 3: `TGA` is tryptophan), so a synonymous change at such a codon is reported as
`stop_lost` and the protein change of any mitochondrial coding variant can be wrong, with no warning
(measured 2026-11-02, `docs/dev-practices/genbank_reference_input.md` §4). Nuclear genes are unaffected.

- `build_snpeff_cache.sh` writes the lines from `CODON_TABLES=contig=Table[,contig=Table]`; it checks the
  contig against the FASTA and the table name against the image's list before building. Table names are
  snpEff's: NCBI code 3 is `Yeast_Mitochondrial`, 4 `Mold_Mitochondrial` (also `Mycoplasma`), 11
  `Bacterial_and_Plant_Plastid`, 12 `Alternative_Yeast_Nuclear` (CTG-clade yeasts).
- An existing cache is fixed by appending the line to `<snpeff_cache>/<db>/snpEff.config` (and to the
  parent `snpEff.config`, if you keep one): the `.bin` files do not change. The project's `R64-1-1.105`
  caches carry `R64-1-1.105.Mito.codonTable : Yeast_Mitochondrial` since 2026-11-02; the `ottilie/v1`
  copies on blob storage still lack it until the `ottilie/v2` test-data package.
- `tests/snpeff_codon_table.nf.test` checks the shipped cache with a synthetic COX2 variant.

## Provenance and retired scripts

- The S288C reference used by every test and benchmark was built by
  `docs/benchmarking/ottilie_xenobiotic_ale/02_reference_prep/prepare_s288c_reference.sh` (Ensembl release
  105 downloads + the Path-B steps, S288C-specific).
- `docs/prepare_input/process_GeneBank/generate_cache/gen_cache.sh` was **retired 2026-09-08**: it was
  hard-coded to a dev-VM directory and to a private genome, and produced sarek-3.4-era directory layouts
  nobody uses. Path A's cache step and Path B replace it; it remains in git history.
- A pipeline-internal builder (FASTA + GFF3/GenBank → versioned cache, with acceptance tests) is a
  roadmap item (`docs/dev-practices/roadmap.md` → *Onboarding*); until then these two scripts are the way.
