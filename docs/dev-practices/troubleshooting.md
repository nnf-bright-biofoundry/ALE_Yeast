# Troubleshooting

Debugging notes for confusing pipeline failures.

## The misleading "sample-sheet only contains normal/tumor-samples" error

**Symptom.** The console shows something like:

```
The sample-sheet only contains normal-samples, but the following tools expect
at least one tumor-sample: controlfreec, mutect2, msisensorpro
```

…but your samplesheet clearly has the right `status` values. **Do not trust this message** — it is
almost always a *downstream symptom* of an unrelated upstream failure, not a real sample-status problem.

### Why it lies

The `input_sample` channel fails to populate whenever **any** earlier error occurs (schema validation,
a config syntax error, a workflow wiring bug). The germline/somatic split then hits an empty channel:

```groovy
// subworkflows/local/samplesheet_to_channel/main.nf (~146-166)
input_sample.filter { it[0].status == 1 }.ifEmpty { error("... expect at least one tumor-sample ...") }
```

The `.ifEmpty{}` fires on the empty channel and prints the tumor/normal error, while the **real**
exception is only in `.nextflow.log`. Three layers stack up: (1) the wrong console message, (2) a
possibly-misleading validation message in the log, (3) the actual root cause.

### Find the real error

1. **Read `.nextflow.log`, earliest exception first** (not the tumor/normal one):
   ```bash
   grep -nE "Exception|ERROR" .nextflow.log | head -20
   ```
2. **Match it to a real cause:**

   | Log error | Real cause | Fix |
   |-----------|-----------|-----|
   | `SchemaValidationException: file or directory '…' does not exist` (but the file *does* exist) | samplesheet paths are **relative**, validated from a different working dir | use **absolute paths** in the samplesheet |
   | `Process XXX declares N input channels but M were specified` | process-invocation bug in workflow code (nothing to do with the samplesheet) | fix the process call to match its input signature |
   | `No such variable` / `Unknown method` | config syntax error or missing import | check recently edited `.config` files (e.g. a missing comma) |
   | `Missing or unknown field in csv file header` | genuine samplesheet header error | fix the column names |
   | *(no obvious exception)* — DAG aborts while building an optional input | a `file(params.x)` on a **null** param. `file(null)` throws during workflow construction, before any task runs | make the param optional with the `[]` idiom (see below), or set it |

3. **Sanity-check the samplesheet is actually valid:**
   ```bash
   awk -F, 'NR>1 {print $3}' samplesheet.csv | sort | uniq -c   # status counts (0=normal, 1=tumor)
   head -5 samplesheet.csv | tail -4 | awk -F, '{print $8}' | xargs ls -lh   # do the FASTQs resolve?
   ```
4. **Bisect recent features.** If you just added a workflow/flag (e.g. `--split_haplotypecaller_joint_vcf`),
   disable it to isolate whether the failure is in the new path.

### Real cases seen

- **Relative FASTQ paths** — samplesheet used `../data/…/file.fastq.gz`; nf-validation resolved them from
  a different directory → "file does not exist" for a file that exists. Absolute paths fixed it.
- **Config syntax** — a missing comma in `custom_freebayes_filter.config` surfaced only as the tumor/normal
  error.
- **Workflow wiring** — `BCFTOOLS_VIEW declares 4 input channels but 1 were specified` (a SPLIT_JOINT_VCF
  input mismatch) masqueraded as a sample-status error.
- **A null optional param** — with `generate_reports` true (its default) and `--report_gff3` unset,
  `file(params.report_gff3)` threw while the DAG was being built, and the abort surfaced as
  *"only contains tumor-samples … expect at least one normal-sample : haplotypecaller"*. The
  samplesheet was fine. This one cost a long debugging session on the first Azure Batch run, because
  the message points at the input while the cause is in the report wiring.
  **Fixed (2026-08-04)** — `report_gff3` is now genuinely optional; reports build without the gene
  track. Verified end-to-end: 30 reports, `PREPARE_GFF3` skipped, cohort report carries a full
  variant table.
- **A `--report_gff3` path that does not exist.** A local path with nothing behind it passed
  parameter validation, `file(params.report_gff3, checkIfExists: true)` then threw while the DAG was
  being built, and the abort surfaced as the same *"only contains tumor-samples"* message (seen in a
  `-preview` start-up, 2026-10-04). **Caught earlier since 2026-10-04**: the schema entry carries
  `exists: true`, so the run stops at parameter validation with `the file or directory '…' does not
  exist`. nf-schema does not check cloud paths (`az://`, `s3://`, `gs://`), so a missing blob still
  takes the old route.

### Making an optional file param actually optional

The fix generalises. Pass **`[]`**, never `null` and never a placeholder filename:

```groovy
// workflow: [] declares no file at all
params.report_gff3 ? file(params.report_gff3, checkIfExists: true) : []

// module: an absent path is falsy, so build the flag conditionally
def tracks_arg = gff3_gz ? "--tracks ${gff3_gz}" : ''
```

Two traps this avoids:

- **`file(null)` throws at DAG-construction time**, producing the misdirection above rather than a
  message naming the param.
- **A placeholder filename (`file('NO_SUCH_FILE')`) breaks on remote work dirs.** It works locally —
  Nextflow symlinks it and `ln -s` to a missing target succeeds — but with `az://`/`s3://` every input
  is physically copied, so FilePorter fails with `Can't stage file … -- file does not exist`. `[]`
  declares nothing to stage. See [`azure_batch_execution.md`](azure_batch_execution.md) §5.

⚠️ For a value consumed as `tuple path(a), path(b)`, pass `[[], []]` — one `[]` per path.

### The real fix (roadmap)

The console message should distinguish a genuine sample-sheet issue from an upstream failure. Preferred
approach: wrap the sample-validation logic so unrelated exceptions re-throw with context instead of being
reported as a tumor/normal problem. Tracked in [`roadmap.md`](roadmap.md) (Robustness / infrastructure).

---

## Closures in a config file — `Unknown method invocation … on _parse_closureN type`

Groovy closure-scoping, not a Nextflow-specific quirk. Applies to any config that defines a helper
closure; in this repo that is only [`conf/azure_batch.config`](../../conf/azure_batch.config) (`req()`,
the env-var guard).

The config parser wraps the file body in generated closures (`_parse_closureN`) to turn `azure { … }`
into config sections. A bare name followed by `(…)` inside one is dispatched as a **method** on the
config-builder delegate. Whether that resolves depends on how the closure was declared. Measured on
25.10.4:

| Declaration / call | `nextflow run` | `nextflow config` |
|---|---|---|
| `def req = { … }` then `req('X')` — **current** | ✅ | ❌ |
| `req = { … }` — no `def` | ❌ | ❌ |
| `req.call('X')` — explicit invocation | ✅ | ❌ |
| `System.getenv('X')` — static method | ✅ | ✅ |
| `def v = 'x'` then `params.foo = v` — no invocation | ✅ | ✅ |

Two consequences:

- ⚠️ **Keep the `def`.** It makes `req` a *local* the `azure { … }` closure captures lexically. Without
  it `req` lands in the script binding, dispatch falls back to the delegate, and **`nextflow run` breaks
  too**. Looks like harmless tidying; breaks the Azure Batch path.
- ⚠️ **`nextflow config` cannot read such a file** — at any nesting depth, and `.call()` is not a
  workaround. The error says the file is broken; the accurate statement is that the command can't read
  it. Failure is at parse time, so there is no process name or work dir in the message. Validate with a
  preview run instead:

  ```bash
  nextflow run main.nf -c conf/azure_batch.config -params-file conf/params_ottilie_test_blob.yml -preview
  ```

Whether the `nextflow config` behaviour is deliberate or an upstream bug has not been investigated.

**Scope.** [`conf/azure_batch.config`](../../conf/azure_batch.config) is the only config in this repo
that defines a closure — `req()`, the environment-variable guard — so it is the only file affected.
Whether this is a deliberate `nextflow config` limitation or an upstream bug has not been investigated;
it has only been observed on 25.10.4.

## Manta dies with `Too many open files` on a large experiment group

Symptom: `--joint_manta` on a big cohort fails in Manta's `generateCandidateSV` step with

```
<reference>.fa.fai: Too many open files
FATAL_ERROR: Failed to use reference: '<ref>.fa' for BAM/CRAM file: '<sample>.md.cram'
```

Cause: joint Manta opens **every** CRAM on **every** thread, so a group of N samples needs roughly
`N × threads × 3` descriptors — about 1,030 at 86 samples with 4 threads, against a container default
soft limit of 1024. It is a cliff, not a gradient: below ~80 samples nothing hints at it, and Manta
retries the sub-task twice before the run dies, so the failure looks deterministic and mysterious.

Fixed in-repo by `--ulimit nofile=65536:65536` on the `docker` profiles (`nextflow.config`) and in
`conf/seqera_azure.config`. If you hit it on another executor, add the equivalent there. Note the
cohort size that triggers this is far beyond the range where joint Manta is recommended anyway —
see [`manta_calling_modes.md`](../variant-calling/manta/manta_calling_modes.md).

## Splitting a joint VCF fails with `the tag "FT" is not defined in the VCF header`

Symptom: with `--joint_manta` (or `--split_haplotypecaller_joint_vcf`), `SPLIT_JOINT_VCF_*:BCFTOOLS_FILTER`
exits 255 complaining that `FT` is undefined — even though the joint VCF's header clearly defines it.

The message points at the wrong step. The real failure is one step earlier, in `BCFTOOLS_VIEW`:
the sample name to extract is built from the **samplesheet** as `"<patient>_<sample>"`
([`split_joint_vcf/main.nf`](../../subworkflows/local/split_joint_vcf/main.nf)), while Manta and GATK
name VCF columns from the **CRAM's `@RG SM` tag**. Those diverge when a run enters at
`--step variant_calling` with CRAMs that were aligned under a *different* experiment name — e.g.
reusing an existing cohort's CRAMs under a new `experiment` value. bcftools then subsets nothing,
producing a VCF with no samples and therefore no `FORMAT` header lines at all, and the next step
fails on the first FORMAT tag it needs.

Diagnosis — compare the two strings:

```bash
bcftools query -l <joint>.vcf.gz | head              # what the caller actually wrote
samtools view -H --reference ref.fa <sample>.md.cram | grep '^@RG'   # the SM tag it came from
awk -F, 'NR>1{print $1"_"$2}' samplesheet.csv | head  # what the pipeline will look for
```

Fix: make the samplesheet's `experiment` column match the experiment encoded in the CRAMs' SM tags
(or re-align from FASTQ). `--force-samples` was **removed** from that step so this now fails
immediately, naming the missing sample, instead of surfacing later as the `FT` error.

## `[yAMP preflight] ERROR FASTA vs GFF3 contig names` — the run stops before alignment

Symptom: the first task, `PREFLIGHT_REFERENCE`, exits 65 within seconds of the launch, and the console
(and its `.command.err`) carries one line naming the contigs of each file — GFF3 `chrI, chrII, …`
against FASTA `I, II, …`, say. In a QC-only run it is the only thing that fails.

Cause: the `--report_gff3` annotation and the `--fasta` come from sources with different chromosome
naming — Ensembl `I`, SGD and NCBI `chrI`, GenBank accessions such as `BK006935.2`, `Mito` versus
`chrM`. Without the check the run would complete and the mutation report's gene track would simply be
empty, with no error anywhere ([`preflight_checks.md`](../usage/preflight_checks.md) → *Reference files*).

Fix: rename the contigs of one file to the other's convention and relaunch. For a GFF3 that is the
first column — `sed -E 's/^chr([IVX]+)\t/\1\t/'` strips a `chr` prefix; treat `Mito`/`chrM` by hand — for
a FASTA the first token of each header. Keep the SnpEff cache on the same names: it is built from a
GFF3 too, and a mismatch there annotates nothing, silently
([`prepare_reference.md`](../usage/prepare_reference.md)). GFF3 contigs the FASTA lacks do not stop
the run: the OK row in the MultiQC table lists them, the expected picture for a chromosome-subset
reference such as the ottilie test set.

## Every containerised nf-test task exits 1 within seconds, with an empty `.command.err`

Symptom: `nf-test test tests/<name>.nf.test` reports a process "terminated with an error exit status
(1)", the task's `.command.out`, `.command.err` and `.command.log` are all empty, the work directory holds
only the staged inputs, and `.command.run` contains no `docker` line. The tests that run no container
(pure-Python or script-only processes on the host) pass in the same session, so it looks like the
containerised module broke. Seen 2026-11-04 on `snpeff_build.nf.test` (5/5 red) and the first case of
`genbank_reference.nf.test`, a day after both had been recorded green.

Cause: the test was launched **without `-c tests/nf-test-ottilie.config`**. The root `nf-test.config`
(kept 0-diff against upstream sarek) applies only the `test` profile, so no container engine is enabled
and the task runs on the bare VM, where the tool binary does not exist. The `-c` file is what turns on
`docker` and the ottilie profile ([`testing_best_practices.md` §10](testing_best_practices.md#10-existing-test-infrastructure)).

Fix: every test under `tests/` takes the same prefix, module tests included:

```bash
NXF_VER=25.10.4 nf-test test -c tests/nf-test-ottilie.config tests/<name>.nf.test
```

Each test file's header comment repeats its own command line. A failure that reproduces *with* the `-c`
config is a real one; one that vanishes with it was the launch, not the code.
