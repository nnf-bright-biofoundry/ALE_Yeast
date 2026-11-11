# Preflight checks: what the pipeline verifies before the first task

At start-up, while the workflow graph is being built and before any task is submitted, yAMP runs a
set of ALE-specific checks on the parameters and the samplesheet. They come on top of the checks
inherited from nf-core/sarek (schema validation, tool/step consistency, missing reference
resources). Every line they print starts with **`[yAMP preflight]`**, so a run's verdicts can be
pulled from the console or `.nextflow.log` with one grep:

```bash
grep '\[yAMP preflight\]' .nextflow.log
```

A run with **no** `[yAMP preflight]` line is on the validated Tier-1 recipe with a consistent
samplesheet. The check runs in seconds, also under `-preview`. A second, task-level check reads the
reference files themselves once the run starts (see *Reference files* below); it follows the same
rule (prints only when something is wrong) but, being a task, does not run under `-preview`.

## In the MultiQC reports: the *yAMP input checks* table

Every check that passed or warned is also a row of the **yAMP input checks** table, the first section
of all three MultiQC reports (read-QC, alignment-QC, complete-QC; see [`qc_first_run.md`](qc_first_run.md)
→ *The three MultiQC reports*). A run's verdicts can therefore be read without opening its log: on
Seqera Platform from the run's *Outputs* tab, while the run is still going.

| Row | OK says | WARN says |
|---|---|---|
| `Samplesheet: experiment ids` | how many samples, in which experiments | never (a missing id is an error) |
| `Samplesheet: input files listed once` | how many files in how many rows | never (a repeated file is an error) |
| `Samplesheet: ploidy and clonal flag per experiment` | the values seen | which experiment mixes which values |
| `Parameters: Tier-1 recipe` | every recipe setting matches | each deviation |
| `Parameters: --qc_only` (QC-only runs only) | the run stops after read QC | only fastp's report is produced |
| `FASTA vs GFF3 contig names` | see *Reference files* below | never |

Rows are sorted by name. An ERROR row never appears: a failed check stops the run before any report
exists, so errors are read on the console (on Seqera, in the run's error message). The same rows are
kept in `<outdir>/reports/preflight/`: `preflight_samplesheet_params_mqc.tsv` for the start-up
checks, `preflight_reference_mqc.tsv` for the reference task.

## Errors: the run stops

| Check | Why it is an error |
|---|---|
| **No experiment id** for one or more samples | The samplesheet header must use an `experiment` column. A `patient` header is accepted by the schema but parsed as *empty*, and the run would proceed with read group `SM:[]_<sample>` and every experiment merged into one joint-calling cohort. The pipeline-written `csv/*.csv` restart sheets carry a `patient` header and hit this too: re-run from the original samplesheet; a finished run resumes with `-resume`. |
| **The same input file in more than one row** | A copy-paste slip that aligns one library twice under two names and doubles its evidence in every cohort table. The message names the file(s). |
| **`--qc_only` with `--step` other than `mapping`** | Read QC is the first stage of the mapping step; a run starting later has no reads to QC ([`qc_first_run.md`](qc_first_run.md)). |
| **`--qc_only` with `multiqc` in `--skip_tools`** | There would be no QC report to sign off. |
| **`--qc_only` with `cleanup = true`** | Nextflow would delete the work directory when the QC run completes, so the follow-up run could not `-resume` it. |
| **`--genbank` together with `--fasta`, `--snpeff_cache`, `--report_gff3` or `--download_cache`** | The GenBank route builds the FASTA, the snpEff database and the gene track from the one file; two sources for one reference would be resolved by a silent preference. Pass one route only (since 2026-11-09). |
| **No reference: neither `--genbank` nor `--fasta`** (at a `--step` other than `annotate`) | Upstream sarek would start with an empty reference channel and every reference task would silently never run. |

## Warnings: the run proceeds

| Check | What it means |
|---|---|
| **Recipe drift**: one line per parameter that differs from the validated Tier-1 recipe (`tools`, `joint_germline`, `split_haplotypecaller_joint_vcf`, `joint_manta`, `manta_high_sensitivity`, and the read-preprocessing parameters `trim_adapter`, `trim_quality_3prime`, `trim_quality_5prime`, `trim_quality_window`, `trim_quality_mean`, `length_required`, `filter_quality`, `clip_r1/r2`, `three_prime_clip_r1/r2`), then a summary line with the count | Any other configuration is allowed; it just is not the one the ottilie contract test and the Azure baseline validate, so its outputs are not covered by them. `tools` is compared as a set: missing Tier-1 callers and extra tools are listed separately. |
| **Mixed `ploidy` or `clonal_or_population` within an experiment** | Legal, but joint calling genotypes every sample of an experiment together and the thresholds are per sample, so a mixed experiment is usually a typo. |
| **`--qc_only` with `fastqc` in `--skip_tools`** | The QC-only run then produces only fastp's report. |

The Tier-1 recipe is the parameter set in `conf/test/ottilie_common.config` plus the read-preprocessing
defaults of `nextflow.config` ([`read_preprocessing.md`](read_preprocessing.md)). The checks keep a
copy of it, and the test suite requires the ottilie profile to produce zero warnings, which is what
keeps the copy honest.

## Reference files: checked by the first task

The reference files themselves are read by one small task, `PREFLIGHT_REFERENCE`, which runs before
alignment at every `--step` and in a QC-only run. It is a task rather than a DAG-build check so that cloud
paths (`az://`, `s3://`) are staged like any other input. It writes one row per check to the MultiQC
reports (a row of the *yAMP input checks* table) and to
`<outdir>/reports/preflight/preflight_reference_mqc.tsv`. On the console it prints only a failed
verdict, with the same `[yAMP preflight]` prefix, so a clean reference still prints nothing.
An ERROR stops the run at once (exit 65, no retry).

| Check | ERROR: the run stops | OK, with a note | Skipped when |
|---|---|---|---|
| **FASTA vs GFF3 contig names.** The GFF3 given as `--report_gff3` is the gene track of the mutation report, so its contig names must be the FASTA's (the first token of each header). | No name is shared: the gene track would be empty and nothing else would complain. The typical cause is Ensembl-style `I` in one file and SGD/NCBI-style `chrI` in the other; rename the contigs of one file ([`prepare_reference.md`](prepare_reference.md)). | Some GFF3 contigs have no FASTA sequence: the row says which, and their features are simply not shown. This is the normal picture for a chromosome-subset reference such as the ottilie test set (4 chromosomes against the full-genome GFF3). FASTA contigs without annotation (cassettes, plasmids) are not reported. | `--report_gff3` is not set: the row reads SKIPPED. |
| **snpEff cache vs FASTA contig names** (since 2026-11-09). snpEff annotates a variant only when its contig is a chromosome of the database; otherwise it logs `ERROR_CHROMOSOME_NOT_FOUND`, writes the record unannotated and nothing else complains. The database's names are read from `<snpeff_cache>/<snpeff_db>/snpEffectPredictor.bin`; the FASTA's are compared the way snpEff looks them up (a leading `chr` and leading zeros do not count: `chrI` matches a database built as `I`). | No FASTA contig is in the database (the annotation would be empty), or `--snpeff_db` names no directory of `--snpeff_cache` (the row lists the directories found; on an `az://` cache this is the first place the mistake is visible), or that directory holds no database file. | All FASTA contigs are in the database. When the database has more contigs than the FASTA, the row says which: the test set's 4 chromosomes against the 17-contig cache. **WARN** (the run proceeds, the line is printed) when some FASTA contigs are *not* in the database: variants on them get no annotation. | snpEff is not in `--tools`, or the reference comes from `--genbank` (the build's own gates compare the names, see below). |

An embedded `##FASTA` section in the GFF3 (SGD and GenBank-converted files carry one) is ignored.
**Not checked here**, by decision (more checks are added as real input errors turn up): a
naming mismatch on part of the genome (`Mito` vs `chrM` with the chromosomes matching), which is visible only
as the note, not an error; the SnpEff database's *version* (an older build of the same genome annotates
with older gene models, silently); a
user-supplied `--fasta_fai` or `--dict` from another FASTA version, which fails inside GATK after alignment;
and FASTA syntax (duplicate headers, CRLF line endings), which fails in reference preparation within minutes.

### Reference from one GenBank (`--genbank`)

On the GenBank route the reference files are *derived*, so the checks move to the two tasks that derive them
(`GENBANK_REFERENCE`, then `SNPEFF_BUILD`; both before alignment, in a QC-only run too). Each writes its rows to
the same table (`reports/preflight/preflight_genbank_mqc.tsv`, `snpeff_build_mqc.tsv`), prints WARN and ERROR
lines with the `[yAMP preflight]` prefix, and an ERROR stops the run before any read is touched. The
derived FASTA and GFF3 then go through the FASTA-vs-GFF3 row above like any other pair
([`genbank_reference_input.md`](../dev-practices/genbank_reference_input.md) §5.5 for the rules in full):

| Row | ERROR: the run stops | WARN: the run proceeds | OK |
|---|---|---|---|
| **GenBank contig identifiers.** The LOCUS name of each record is the contig name in every output. | Two records with the same LOCUS, or two that snpEff would store under one name (`chr1` and `1`); a LOCUS with whitespace, a colon, a pipe or a GFF3/VCF reserved character; a record without sequence. | None. | The row lists the names, and which ones snpEff stores simplified. A record without a versioned accession (no VERSION, or VERSION equal to LOCUS) is noted in the same row, with no console line: that is what SnapGene, Benchling and Prokka write, so a lab-made file is a normal input. A database registration matches such a contig by sequence md5 (`reference/<db>/contig_manifest.csv`). The release test GenBank is such a file. |
| **GenBank genetic code.** The `/transl_table` of each contig's CDS becomes one `codonTable` line of the database's config: the only place snpEff takes the genetic code from. | A contig whose CDS state different tables; a table snpEff 5.1 has no codon table for. | An organelle contig (`/organelle` on its source feature) whose CDS state no table: the standard code is assumed, which organelles rarely use. Add `/transl_table=N` to the CDS and rerun. A nuclear contig without the qualifier is the standard code by the INSDC rule, silently. | The non-standard contigs and their tables are listed. |
| **snpEff build: protein check.** snpEff translates every CDS and compares with the file's `/translation`: gene models and genetic code verified in one number. | `Errors > 0`, or no database written. | — | `Errors: 0`. SKIPPED when the file carries no `/translation` at all (a draft): the models are then unverified. |
| **snpEff build: contig names.** The names stored in the database must equal the ones expected from the FASTA (after snpEff's simplification). | Any name missing from, or unexpected in, the database. | — | Equal. |

Two start-up errors belong to the same route: `--genbank` given together with `--fasta`, `--snpeff_cache`,
`--report_gff3` or `--download_cache` (one route only, never a silent preference), and no reference at all
(neither `--genbank` nor `--fasta`; upstream sarek would start and every reference task would silently never run).

Where they live: `validateAleRecipe()`, `validateAleSamplesheet()`, `validateQcOnly()` and
`validateReferenceRoute()` in
`subworkflows/local/utils_nfcore_sarek_pipeline/main.nf` (their table rows: `preflightTable()`, whose
header must stay identical to the reference script's), test `tests/preflight.nf.test`; the reference
task in `modules/local/preflight_reference/` runs `bin/preflight_reference.sh` (gawk), configured by
`conf/modules/preflight.config`, test `tests/preflight_reference.nf.test`; the GenBank rows in
`bin/genbank_to_reference.py` (`modules/local/genbank_reference/`) and `bin/snpeff_build_gates.sh`
(`modules/local/snpeff_build/`), configured by `conf/modules/genbank_reference.config`, tests
`tests/genbank_reference.nf.test`, `tests/snpeff_build.nf.test` and, for the whole route in a QC-only
run, `tests/genbank_route.nf.test`; the contract test (`tests/ottilie_e2e.nf.test`) runs on this route and
asserts the ten rows of the table.
