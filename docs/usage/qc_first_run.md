# QC-first run: look at the reads before the expensive part runs

`--qc_only` turns a launch into a **two-run idiom**: run 1 stops after read QC and exits 0; you look
at the reports and sign them off; run 2 is the *same command* without the flag plus `-resume`, and
continues from alignment with every read-QC task a cache hit. Nothing is computed twice and nothing
is guessed: the second run is the run you would have launched anyway.

```
raw FASTQ ─┬─► FastQC (raw)                                             ┐
           └─► fastp ─► FastQC (after preprocessing) ─► MultiQC read-QC │  run 1: --qc_only  (minutes)
   + preflight checks, reference preparation, GFF3 index                ┘
                       │
                       ▼   the gate: alignment input emptied under --qc_only
             bwa-mem ─► duplicate marking ─► callers ─► annotation ─► mutation report      run 2: -resume
```

## The two runs

**Run 1** is your normal launch plus `--qc_only` (locally, in a params file, or the `qc_only`
box on the Seqera launch form, the first field of *Main options*):

```bash
nextflow -c conf/mymachine.config run main.nf -profile docker -params-file my_project.yml --qc_only
```

It validates the **complete** parameter set (schema, sarek's own checks, the
[`[yAMP preflight]`](preflight_checks.md) checks), prepares the reference, runs FastQC on the raw
reads, fastp, FastQC on the fastp output and the **read-QC MultiQC report**, and ends with:

```
[yAMP qc_only] QC-only run finished — nothing past read QC was run.
[yAMP qc_only]   MultiQC report : <outdir>/multiqc/yAMP-read-QC_multiqc_report.html
[yAMP qc_only]   FastQC / fastp : <outdir>/reports/  (input checks: the report's 'yAMP input checks' table)
[yAMP qc_only]   To continue, run the same command without --qc_only and with -resume <session id>
[yAMP qc_only]   (same work directory and --outdir; every read-QC task is a cache hit):
[yAMP qc_only]     nextflow … -resume <session id>
[yAMP qc_only]   On Seqera Platform: open this run → Resume → set qc_only to false.
```

**Run 2** is the printed command: identical `--input`, `--outdir`, work directory, profile and
revision, `--qc_only` dropped, `-resume <session id>` added. Pass the **session id** the message
prints, not a bare `-resume`: a bare `-resume` resumes whatever ran last in that directory
(`azure_batch_execution.md` → `-resume` hazards). If `qc_only` came from a params file or config
rather than the command line, the message says so; set it to `false` there.

### On Seqera Platform

The Launchpad entry opens with `qc_only` ticked (the first field of *Main options*, the third section of the form), so
a launch from it is run 1 unless you untick the box. This is a setting of the entry, saved in its
parameters (`deploy/azure/seqera-sp/14_register_pipeline.sh`). The pipeline's own default stays a
complete run: the command line is not affected, and a params file uploaded in the form replaces the
entry's parameters, so the file decides ([`params_template.yml`](params_template.yml) carries
`qc_only: false`).

Run 1: give `outdir` a folder you intend to keep and launch. Or launch from a shell, which records
exactly what was sent:

```bash
deploy/azure/seqera-sp/15_launch_run.sh --name yAMP-qc-first-run1-<date> \
    --set outdir=az://aletest/seqera-runs/<folder>
deploy/azure/seqera-sp/16_watch_run.sh <run id>        # one line per status change, then task stats
```

Run 2 is Platform's *Resume* on the **succeeded** run 1 with `qc_only` cleared (open the run →
*Resume* → untick `qc_only` → launch), or:

```bash
deploy/azure/seqera-sp/15_launch_run.sh --resume <run-1 id> --name yAMP-qc-first-run2-<date> \
    --set outdir=az://aletest/seqera-runs/<the same folder>
```

For a complete run in one go, untick `qc_only` before launching, or add `--set qc_only=false` to
the first command.

Resume keeps run 1's session, work directory, compute environment, profiles and **commit** (it pins
the hash run 1 ran, even if `main` has moved since) and replaces only the parameters. The script sends
the committed params box plus your overrides, and with `--resume` it sets `qc_only: false` itself;
`outdir` must be run 1's. Measured 2026-09-28 on the test set (runs `5m9NorL3JmkHFq` →
`464Scp5QNoznbD`; `deploy/azure/seqera-sp/RUNBOOK.md`), when the entry did not yet tick the box and
run 1 was launched with `--set qc_only=true`:

- **Run 1:** 18 tasks, the 15 read-QC and reference-preparation processes, 12 min wall time, of which
  about 10 min is the head pool starting from zero. Both pools scale back to zero after a run
  (5-minute evaluation, halving; the head pool is gone within ~5 min of idle), so launch run 2 within
  those five minutes and it starts in ~2 min instead of ~10. The head node runs two head jobs at
  once, so a QC-only run launched ~15 min ahead keeps the pools warm for a launch that must start fast.
- **Run 2:** 17 of 153 tasks CACHED (every run-1 task but MultiQC, which must re-run: its inputs grow
  with every alignment and calling stat), the task list of a one-shot run, deliverables identical to
  the local e2e output of the same commit (530 names equal, 145 snapshot files md5-identical, 42/42
  VCFs record-identical; `tests/qc_gate.sh` part (b) applied to the downloaded outdir).
- **Outputs tab.** Run 1's lists the read-QC report (entry *6a*). A full run's (run 2 or a one-shot
  run) lists *6a* and *6b* (alignment-QC) **while it is still running**, then the dashboard entries
  and *6* (complete-QC) at the end: Platform picks up each published report within about a minute
  (measured 2026-09-29, run `5CiOiON5oJuETn`; `azure_batch_execution.md` → Outputs tab).
  Before 2026-09-29 the QC-only report had its own file name and survived run 2 (`702a4c0`); now
  run 2 rewrites the same read-QC report early in its run (see *The three MultiQC reports*).
- **The run page lists all 117 processes for both runs** (115 before the two MultiQC reports of
  2026-09-29): the workflow map is registered whole; 15 carry tasks in run 1 (64 in a full run on
  2026-10-05; the rest are sarek branches this recipe never uses). The
  *Tasks* tab is the record of what ran.
- **Repeated 2026-10-05** (runs `1VItgFdKPAxaLT` → `6iO52bvtK9Db7`, commit `616f67a`; the first
  pair from the entry that opens with `qc_only` ticked, run 1 launched by `15_launch_run.sh` with
  no `qc_only` override and run 2 by its `--resume`): run 1 18 tasks in 15 processes, 11.6 min;
  run 2 submitted 55 s after run 1 ended and RUNNING after 2 min, 155 tasks of which 17 CACHED
  (every run-1 task but `MULTIQC_READ_QC`), 64 of 117 processes with tasks, 18.2 min, no UNKNOWN.
  The two tasks and two processes more than on 2026-09-28 are `MULTIQC_READ_QC` and
  `MULTIQC_ALIGNMENT_QC` (the only processes new in the map since then). Outputs present (995 blobs:
  index, cohort report, the three MultiQC reports, the joint VCF), not compared against a baseline.
- **Platform's status is not the outcome.** Run 2 was shown as UNKNOWN from 19:00 while it kept
  completing tasks and finished cleanly at 19:07; the watch script says what to check instead
  ([`azure_batch_execution.md` §15](../dev-practices/azure_batch_execution.md)).

## What to look at before signing off

The read-QC report of run 1 opens with the *yAMP input checks* table (every start-up check with its
verdict, [`preflight_checks.md`](preflight_checks.md)), then two FastQC sections, *FastQC (raw)* and
*FastQC (after preprocessing)*, with fastp between them and both sets of General Stats columns on the
same sample rows ([`read_preprocessing.md` → Post-trim QC](read_preprocessing.md#post-trim-qc)). The
Workflow Summary (every parameter the run set) is at the bottom, collapsed.

| Look at | Where | What a problem looks like |
|---|---|---|
| Per-base quality after trimming | FastQC (after preprocessing) → *Per base sequence quality* | a 3′ tail still below Q20: raise `trim_quality_mean` or use `trim_quality_3prime right` |
| Residual adapter content | FastQC (after preprocessing) → *Adapter content* | any rising curve: fastp did not detect the kit; pass `--adapter_sequence` / `--adapter_sequence_r2` |
| Reads surviving fastp | fastp → *Filtered reads*; General Stats `% Pass filter` | more than a few % lost: a low-quality library or an over-tight `filter_quality_*` / `length_required` |
| Duplication estimate | fastp → *Duplication*; FastQC → *Sequence duplication levels* | far above the other samples: low-complexity library or PCR over-amplification |
| GC distribution | FastQC → *Per sequence GC content* | a second peak or a shifted mode: contamination, or reads from the wrong organism |
| Input checks | *yAMP input checks* table (first section) | a WARN row: a parameter off the Tier-1 recipe, or an experiment mixing ploidy or clonal flag; an ERROR is never seen here (it has already stopped the run). The reference row's note lists GFF3 contigs without a FASTA sequence, the expected picture for a chromosome-subset reference such as the test set ([`preflight_checks.md`](preflight_checks.md)) |
| Expected depth | General Stats: bases after filtering ÷ genome size | below what the experiment needs. The coverage check itself is behind the gate (it needs alignment) |

Run 1 shows **no** mapping rate, coverage or mitochondrial depth and cannot tell reads from the wrong
*strain* apart: alignment is the expensive part and stays behind the gate (decision 2026-09-21). A
later "stop after alignment" level would be a separate parameter.

## What run 1 does and does not do

Runs (and is cached for run 2): preflight checks · the reference preflight task (FASTA vs GFF3 contig
names, [`preflight_checks.md`](preflight_checks.md) → *Reference files*) · FastQC on the raw reads ·
fastp · FastQC on the fastp output · the read-QC MultiQC report · reference preparation (bwa index, `.fai`, sequence
dictionary, intervals, the CNVKit flat reference) · the GFF3 index for the mutation report · on the
`--genbank` route, the two tasks that derive the reference from the GenBank. On the
ottilie test set that is 18 tasks and about five minutes (measured 2026-09-28; 20 tasks on the GenBank route).

Does **not** run: alignment and everything downstream (duplicate marking, every caller, annotation,
the mutation report). **breseq** (Tier-2, `--tools breseq --genbank …`) reads the fastp output
directly rather than the alignment, so it is gated separately and is likewise not run. Not checked by
run 1 either: the SnpEff cache (contig names, snpEff version), which is read only at the annotation
step, in run 2 ([`prepare_reference.md`](prepare_reference.md) → chromosome names).

### The three MultiQC reports

Every run writes up to three reports to `<outdir>/multiqc/`, each as soon as its stage ends:

| Report | File | Holds | Written |
|---|---|---|---|
| *yAMP read-QC* | `yAMP-read-QC_multiqc_report.html` | input checks, FastQC (raw and after preprocessing), fastp | when read QC ends; the QC-only run's report |
| *yAMP alignment-QC* | `yAMP-alignment-QC_multiqc_report.html` | + duplicate metrics, samtools stats, mosdepth coverage | when every sample is aligned; not in a QC-only run |
| *yAMP complete-QC* | `multiqc_report.html` | + variant statistics and the software versions | at the end; not in a QC-only run |

The first two carry their `…_data/` and `…_plots/` folders beside them; the complete one keeps
MultiQC's plain names (`multiqc_report.html`, `multiqc_data/`), which the mutation-report index links
to. Run 2 rewrites the read-QC report within minutes of starting: same read-QC data, but its input
checks and Workflow Summary no longer say `qc_only`. `multiqc_title` (hidden on the Seqera launch
form) replaces the `yAMP` prefix of all three titles, and so the two early file names.

## Rules and errors

`qc_only` is a boolean, default `false`. Combinations that would make the follow-up impossible or the
QC run pointless are refused at start-up (`[yAMP preflight]` errors, run in seconds, also under
`-preview`):

| Combination | Why it is an error |
|---|---|
| `--qc_only` with `--step` other than `mapping` | read QC is the first stage of the mapping step; a run starting later has no reads to QC |
| `--qc_only` with `multiqc` in `--skip_tools` | there would be no report to sign off |
| `--qc_only` with `cleanup = true` in the config | Nextflow would delete the work directory when the QC run completes, so run 2 could not resume it |

`--qc_only` with `fastqc` in `--skip_tools` runs (warning): only fastp's report is produced.

Hash stability: run 2 reuses run 1's tasks only if their inputs and scripts are unchanged. Change
nothing between the two runs except the flag: not the samplesheet, the reference, the trimming
parameters or the pipeline revision. (The read-QC MultiQC report is the one task that runs again:
its input checks and Workflow Summary record `qc_only`.)

## How it works, and the test that guards it

The gate is a single point in `workflows/sarek/main.nf`: under `--qc_only` the channel that feeds
alignment is emptied, and every process downstream of it starves (a process with no input never
runs), so nothing further down is wrapped and the DAG is identical to a full run. The one thing that
would break this silently is a future process downstream of alignment whose inputs can all be
satisfied on empty input (`toList()`, `ifEmpty(...)`, a value channel or a plain file). Two tests pin
the property (`docs/dev-practices/testing_best_practices.md` §11):

- `tests/qc_gate.sh a` (minutes): a QC-only run of the test set must execute *exactly* the
  allow-listed processes (the list is in the script);
- `tests/qc_gate.sh b <one-shot outdir>` (one e2e): the resumed run must cache every run-1 task,
  execute the same task list as a one-shot run, and produce the same deliverables
  (`tests/qc_gate_compare.py`).

The rebase rule lives in [`SAREK_MODIFICATIONS.md`](../dev-practices/SAREK_MODIFICATIONS.md) →
`workflows/sarek/main.nf` → the `--qc_only` gate.
