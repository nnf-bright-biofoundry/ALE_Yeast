# Nextflow Local Executor Deadlock

## Problem

When running nf-core/sarek on a single VM with the Nextflow `local` executor,
the pipeline can deadlock during the variant calling stage. The scheduler reports:

```
!! executor local > No more task to compute -- The following nodes are still active:
```

Tasks are queued but none are submitted. The Nextflow Java process stays alive at 0% CPU indefinitely.

## When it happens

This occurs when:
1. **Multiple process types** compete for task slots (e.g., HaplotypeCaller, CNVKit, TIDDIT, ControlFREEC all run in parallel after alignment completes)
2. **`executor.memory`** is barely larger than **`process.memory`**, so only 1 task fits at a time
3. The scheduler cannot resolve which waiting process to run next

**Not affected**: HPC/cloud executors (SLURM, AWS Batch, Azure Batch, Seqera Platform). These have independent resource pools and don't share a single memory budget.

## Example (Tier 2 run, May 2026)

```groovy
// DEADLOCKED: only 1 task fits (10 / 8 = 1)
executor { memory = '10 GB' }
process  { memory = '8 GB'  }
```

86 samples completed alignment (86/86), but variant calling stalled at 6/86 for
HaplotypeCaller, CNVKit, and TIDDIT. ControlFREEC never started (0/86).
The pipeline sat idle for 4 days before being killed manually.

## Fix

Ensure `executor.memory / process.memory >= 2` so at least 2 tasks can run concurrently:

```groovy
// FIXED: 3 tasks fit (14 / 4 = 3), breaks deadlock
executor { memory = '14 GB' }
process  { memory = '4 GB'  }

// Override for processes that actually need more
withName: 'GATK4_MARKDUPLICATES' { memory = '8 GB' }
withName: 'BWAMEM1_MEM'          { memory = '6 GB' }
withName: 'GATK4_GENOMICSDBIMPORT|GATK4_GENOTYPEGVCFS' { memory = '12 GB' }
```

## Second occurrence (2026-11-09): one CPU lost from the budget, no pool set

The contract test stalled the same way on a setup the section above calls safe: no `executor` block, so
the budget was the host itself (4 CPUs, 15.6 GB), and only the clamp set (`resourceLimits` 4 CPUs,
14 GB). After 136 tasks had completed, four `SNPEFF_SNPEFF` tasks (4 CPUs and 14 GB each after the
clamp) stayed in the submission queue for 20 minutes with nothing running, until the run was stopped.
The same tree passed twice right after.

**Measured**, by replaying every submission and completion of the run's log against each process's
request (script, tables and output in
[`docs/dev-practices/local_scheduler_stall_2026-11-09/`](../dev-practices/local_scheduler_stall_2026-11-09/)):

- Reservations never exceed the budget and return to zero at the end: the log is complete and no task
  failed (0 non-zero exits).
- 4 CPUs were reserved for the last time at 19:15:23.900. In the 71 events after it the run never
  reserved more than 3.
- From that moment tasks waited although their request fitted. Nextflow numbers tasks in creation order,
  so a task with a lower id than one already submitted was provably waiting. Six tasks did so for more
  than 0.5 s, the first a one-CPU, 1 GB task that waited 1.1 s beside 3 reserved CPUs; the complete run
  on the same tree has none (0 of 75 waiting windows).
- A budget of 3 CPUs explains all six. Lost memory does not: the run still reserved 13.3 GB after that
  moment, which a memory budget short of the 12 GB needed to explain the waits could not hold.
- In the 8 ms around that moment one task completed (19:15:23.896), one was submitted (.900) and one
  completed (.904).

**Inferred, not measured:** the scheduler's free-CPU counter lost the give-back of one completing task
when it coincided with a submission, so the budget read 3 CPUs for the rest of the run. The counters
were not read from the live process before it was stopped.

What follows from the measured part alone:

- **A task that requests the whole budget, in CPUs or in memory, is the weak spot.** It starts only when
  the scheduler believes everything is free, and one lost unit strands it for good. The rule of the
  section above (`executor.memory / process.memory >= 2`) is the memory case of this.
- **Not setting a pool does not avoid it.** With the clamp equal to the machine's CPU count, every
  process that asks for the cap needs the whole CPU budget. On the test set that is 14 process types.
- **The remedy keeps every request below the budget.** The test configuration
  (`tests/ottilie_nftest_resources.config`) now sets the CPU budget to twice the per-task cap
  (`executor { cpus = 8 }`, a number for the scheduler, not a hardware count) and trims memory requests
  to measured peaks, so the largest is about half of the memory budget. Tasks get the same `task.cpus`
  as before, so tool thread counts and outputs do not change.
- **Still exposed:** the `azureD4as` profile (pool of 4 CPUs, processes that request 4) and a clamp-only
  file copied from `conf/mymachine.config`. One stall in the contract-test runs to date; if a local run
  stalls this way, the same two settings are the fix.

## How to diagnose

1. Check if the pipeline is idle: `docker ps` shows no containers, `top` shows 0% CPU for the Nextflow Java process
2. Check the log: `grep "No more task to compute" .nextflow.log`
3. The log block lists which process nodes are `ACTIVE` with `port 0: (queue) OPEN`. These have tasks waiting but can't be scheduled
4. `grep -A6 "tasks in the submission queue" .nextflow.log | tail -8` names the tasks that are queued. Compare their request (`docker run --cpu-shares N --memory Mm` in a completed task's `.command.run`; 1024 shares per CPU) with the budget on the log's `Creating local task monitor` line: a queued task that asks for all of either is the pattern
5. Before stopping the run, keep the log (`.nextflow.log`, or `.nf-test/tests/<hash>/meta/nextflow.log` under nf-test) and the trace file: a rerun overwrites both, and the replay script reads them

## Key takeaway

Set per-process memory based on **actual peak RSS** (from the execution trace), not worst-case guesses. Most bioinformatics tools on yeast-sized genomes use <2 GB. Over-requesting memory starves the local executor. And keep every single request, CPUs included, below the scheduler's budget: a task that needs all of it can be stranded by one lost unit.
