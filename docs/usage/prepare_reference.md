# Preparing a reference: one GenBank file

Give the pipeline your genome as **one GenBank file** and nothing else: `--genbank genome.gb`. The run builds
the FASTA, the snpEff database and the gene track of the reports from it, checks them, and publishes them with
the results. There is nothing to prepare beforehand and no second file to keep in step with the first.

The older way, a FASTA plus a snpEff database you build yourself (the *pre-built route*), still works and is
described in the [appendix](#appendix-the-pre-built-route-fasta--snpeff-cache--gff3). Use it only to reproduce
a run made that way.

## Give us the GenBank

```bash
nextflow run main.nf -profile docker -c my_machine.config \
    --input samplesheet.csv --outdir results \
    --genbank genome.gbff
```

On Seqera Platform `genbank` is the only field under *Reference genome options*.

**The file name.** It must end in `.gb`, `.gbk`, `.gbff` or `.genbank`, lowercase, optionally followed by
`.gz`. Any other name, `genome.GB` or a `.fasta` given by mistake included, stops the run at parameter
validation, before any task. The name without that ending is the snpEff database name (`genome.gbff.gz` →
`genome`): it names the folder `reference/genome/` and the `reports/snpeff/` paths, nothing inside a VCF.
`--snpeff_db <name>` sets another name.

**One route only.** `--genbank` together with `--fasta`, `--snpeff_cache`, `--report_gff3` or
`--download_cache` is a start-up error, and so is a run with neither `--genbank` nor `--fasta`. A profile or
params file that names one route has to be overridden with `null` to take the other
(`--genbank null --fasta …`).

**Cloud paths.** A local path, an https URL, or `az://<container>/…` / `s3://…` / `gs://…` all work: it is a
single file. On Azure write `az://<container>/path`, never `az://<account>.<container>/path`, which stops at
start-up with a readable message.

## What a good GenBank file looks like

One file, **one record per contig** (chromosome, mitochondrion, plasmid, scaffold), each with its sequence.
What the pipeline reads from it:

| In the file | What it becomes | If it is missing or wrong |
|---|---|---|
| The `LOCUS` name of each record | The contig name in **every** output: VCFs, cohort tables, reports, IGV pages | Two records with the same name, two names snpEff would store as one (`chr1` and `1`), or a name with whitespace, `:`, `\|` or a GFF3/VCF reserved character: ERROR, the run stops. Rename in the file. |
| The sequence (`ORIGIN`) | The FASTA | A record without sequence: ERROR. NCBI Nucleotide's plain *GenBank* format of a CON record lists the pieces instead of the sequence: download *GenBank (full)*, or the assembly's `.gbff`. |
| `CDS` features with `/gene`, `/locus_tag`, `/product` | The snpEff gene models and the report's gene track | Variants on that contig get no gene annotation. |
| `/translation` on the CDS | snpEff translates every CDS and compares: the *protein check* row, the one number that verifies gene models and genetic code together | Absent from the whole file (a draft): the row reads SKIPPED and the models are unverified. Any mismatch: ERROR. |
| `/transl_table=N` on the CDS of a contig whose genetic code is not the standard one | The contig's `codonTable` line in the database config: the **only** place snpEff takes the genetic code from | Nuclear contig without it: standard code, silently (the INSDC rule). Organelle contig without it: WARN, standard code assumed. Two tables on one contig, or one snpEff has no table for: ERROR. |
| `/organelle="mitochondrion"` (or another organelle) or `/plasmid` on the `source` feature | The contig's `type` in the contig manifest; the report's *Whole chromosomes* table grades such a contig against the cohort median instead of against 1 (a mitochondrion sits at tens of copies) | The contig is typed `other` and graded against 1, so a mitochondrion reads as a gain in every sample. |
| `VERSION` (a versioned accession such as `NC_001133.9`) | The manifest's `version` column, for a later database registration | Normal for SnapGene, Benchling and Prokka files: the identifiers row is OK with a note, no console line. |

The order of the records is the contig order of every table and report. Yeast files from NCBI list I to XVI,
then the mitochondrion.

**Where to get one.** For a published genome, the assembly's `*_genomic.gbff.gz` from NCBI (S288C:
`https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/146/045/GCF_000146045.2_R64/GCF_000146045.2_R64_genomic.gbff.gz`,
the source of the test GenBank; NCBI Datasets gives the same file with `--include gbff`). Its LOCUS names are accessions
(`NC_001133`), and those become your contig names. To use names like `I` … `XVI` instead, rename the LOCUS
(and VERSION) lines first, as the test GenBank was (*Provenance*, below). For an
engineered strain, export the whole genome from SnapGene or Benchling, or annotate it with Prokka/Bakta:
those files are first-class input.

## What the run builds and checks

Two tasks run before alignment, also in a QC-only run (`--qc_only`), and take seconds on a yeast genome:

1. `GENBANK_REFERENCE` reads the file once and writes the FASTA, the GFF3 gene track (gene → mRNA → CDS
   with phase), the contig manifest and the database's `snpEff.config` with one `codonTable` line per
   non-standard contig.
2. `SNPEFF_BUILD` runs `snpEff build -genbank` (snpEff 5.1, the version the annotation step runs) and stops
   the run unless the protein check reports no error and the database's contig names are the FASTA's.

Their four verdicts are rows of the *yAMP input checks* table at the top of every MultiQC report:
*GenBank contig identifiers*, *GenBank genetic code*, *snpEff build: protein check*, *snpEff build: contig
names*. What each says, and when it stops the run: [`preflight_checks.md`](preflight_checks.md) → *Reference
from one GenBank*.

Published in every run, under `<outdir>/reference/<db>/`:

| File | What |
|---|---|
| your GenBank, under the name you gave | Untouched: the reference record of the run |
| `<db>.fa` | The FASTA, LOCUS names as headers, records in file order |
| `<db>.gff3` | The gene track of the reports |
| `contig_manifest.csv` | One row per contig: `contig` (LOCUS), `version`, `length`, `md5` of the upper-cased sequence, `type` (`chromosome`, `mitochondrion`, `plasmid`, `other`, …), `chromosome`, `transl_table`, `order`; a header comment names the GenBank file and its sha256 |
| `snpeff_cache/<db>/` | The snpEff database, usable as `--snpeff_cache <outdir>/reference/<db>/snpeff_cache --snpeff_db <db>` |
| `<db>.snpeff_build.log` | snpEff's build log, protein-check counts included |

The FASTA index and sequence dictionary are built in the run but not published unless `--save_reference`
is set (`reference/fai/`, `reference/dict/`).

## Known limits of the GenBank route

- **Non-coding genes have no transcript.** `snpEff build -genbank` makes transcripts from CDS features
  only, so a variant inside a tRNA or ncRNA gene is reported as `intragenic_variant` (MODIFIER) and the
  first annotation may name a neighbouring protein-coding gene. On the four test chromosomes 120 of 2,070
  genes are such genes. Detail: [`genbank_noncoding_models.md`](../dev-practices/genbank_noncoding_models.md).
- **The gene models are the file's.** A RefSeq file gives RefSeq models: against the Ensembl-built cache of
  the pre-built route, 12 of the test set's 100 variant sites name another gene or effect first (dubious ORFs
  RefSeq dropped, Ty elements, tRNAs); the four truth SNVs annotate identically.

## Regenerating the reports from a finished run

`generate_mutation_report.nf` rebuilds the mutation reports from an existing output directory without
rerunning the pipeline. It finds the contig manifest under `reference/*/` itself, but still takes the FASTA,
its index and the gene track as parameters. For a GenBank-route output they are in `reference/<db>/`, except
the index, which you make once with `samtools faidx`:

```bash
R=results/reference/<db>
samtools faidx $R/<db>.fa            # writes $R/<db>.fa.fai
nextflow run generate_mutation_report.nf -profile docker -c my_machine.config \
    --outdir results --input samplesheet.csv \
    --fasta $R/<db>.fa --fasta_fai $R/<db>.fa.fai --report_gff3 $R/<db>.gff3 \
    --tools haplotypecaller,cnvkit,manta,tiddit,snpeff \
    --skip_tools baserecalibrator \
    --report_outdir results/mutation_reports_rerun
```

Pass the same `--tools`, `--skip_tools` and `--joint_manta` as the run had: the launcher locates the
published files from them (`--skip_tools baserecalibrator` points it at `preprocessing/markduplicates/`,
where every ALE run publishes its CRAMs).
**Verified 2026-11-11** on the GenBank-route output of `bin/test_ottilie_blob.sh` (commit `70aaf8b`): the
command above gives the same 11 cohort tables, byte for byte, and the same variant table in all 11 HTML
reports as the run's own `mutation_reports/`.

## Appendix: the pre-built route (FASTA + snpEff cache + GFF3)

The route of every run before 2026-11-09, and the route of the release `v1.1.0`. On Seqera Platform it is
the Launchpad version `yAMP-prebuilt-inputs-v1.1.0` of the yAMP entry, pinned to that tag (it receives no
later fixes); from the command line the four parameters below still work on every version (they are hidden
in the launch form, not removed). Docker is the only prerequisite for both preparation scripts.
Everything here is what the Ottilie/S288C test data itself was built with.

### What the pipeline consumes

| Parameter | Needed? | What |
|---|---|---|
| `--fasta` | yes | Reference FASTA. `.fai`, `.dict` and the bwa-mem2 index are built in-run (seconds on yeast). |
| `--snpeff_cache` + `--snpeff_db` | yes when `snpeff` is in `--tools` (the Tier-1 recipe) | A SnpEff database **directory**: `<snpeff_cache>/<snpeff_db>/snpEffectPredictor.bin` plus `sequence*.bin` and `snpEff.config`; `--snpeff_db` is that directory's name. There is **no default**: omitting it fails at launch with `Please specify --snpeff_cache …`. |
| `--report_gff3` | optional | GFF3 for the gene track in the igv-reports dashboard. Without it the reports have no gene track. An uncompressed file whose name ends in `.gff3` or `.gff`: another name, or a local path that does not exist, stops the run at parameter validation. Its contig names must be the FASTA's: checked by the first task of every run ([`preflight_checks.md`](preflight_checks.md) → *Reference files*). |
| `--genbank` | no | The other route: giving it together with `--fasta`, `--snpeff_cache` or `--report_gff3` stops the run at start-up. (breseq, Tier 2, reads the same parameter as its reference.) |
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
  noted) and, since 2026-11-09, the database's contig names against the FASTA's (error when none is shared
  or `--snpeff_db` names no directory of the cache, warning for FASTA contigs the database lacks); see
  [`preflight_checks.md`](preflight_checks.md) → *Reference files*.
- **Runtime files only are needed**: `snpEffectPredictor.bin`, `sequence*.bin`, `snpEff.config` (~6 MB
  for yeast). `genes.gff` and `sequences.fa` are build inputs and may be left out of what you ship.
  `snpEff.config` is not a formality: it carries the genetic code per contig (see *Genetic code* below).
- **Running from cloud storage** (Seqera, AWS Batch, HPC): upload the directory to your own bucket and
  pass the `az://` / `s3://` / `gs://` path; see the README section *Running the SnpEff cache from cloud
  storage*. An https URL cannot be used for a directory.

### Path A: from a GenBank file, outside the pipeline

If you have a GenBank file, give it to the pipeline as `--genbank` instead: the in-run build keeps the gene
hierarchy, gene symbols and genetic code that this script loses (below). Path A stays for reproducing a
cache made with it.

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

### Path B: from FASTA + GFF3 (Ensembl, NCBI, or your own annotation)

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

#### Genetic code (`codonTable`): the one thing the GFF3 cannot tell snpEff

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
- The 4-chromosome test GenBank (`S288C_R64_test.gb`, the reference of the test profiles since 2026-11-11)
  is NCBI's `GCF_000146045.2_R64_genomic.gbff` with the LOCUS and VERSION lines renamed to Ensembl's names
  (`I` … `XVI`, `Mito`) by `docs/benchmarking/ottilie_xenobiotic_ale/02_reference_prep/rename_genbank_chromosomes.sh`,
  then cut to four records by `generate_test_data.sh`
  ([`DATA_PROVENANCE.md`](../benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md)).
- The pipeline-internal builder that was a roadmap item until 2026-11 is the GenBank route of this page
  (design and measurements: [`genbank_reference_input.md`](../dev-practices/genbank_reference_input.md)).
