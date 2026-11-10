# Long runs on the VM: launch them detached, so a dropped connection does not kill them

A pipeline run is a child of the shell that launched it. When that shell goes away, the run goes with it:
an SSH session that drops, a VS Code window that closes, a Claude Code session that ends. Nextflow then
logs `Session aborted -- Cause: SIGTERM`, prints `Pipeline completed with errors` with **zero failed
tasks**, kills the running tasks and exits. Nothing is corrupt, but the clock restarts.

Measured 2026-11-10: the full-depth 4-sample pilot (`run_ottilie_pilot.sh`, about 75 min) was started as a
Claude Code background task at 23:56 and received SIGTERM at 00:25 when that session ended. 35 of about 310
tasks had finished (3.5 h of CPU in the work dir), 2 were running, none had failed. The resume below recovered
all 35 (34 cached, one re-run) and the run finished.

**Rule: anything longer than a few minutes is launched detached.** That is every pilot, every `--qc_only`
+ resume pair on real data, the e2e contract test when the shell is remote, and any `nf-test` run you will
not sit and watch.

## 1. The one-liner: `setsid nohup`

```bash
setsid nohup bash my_run.sh > my_run.log 2>&1 < /dev/null & disown
```

- `setsid` puts the run in its own session, so the hang-up of the launching terminal never reaches it.
- `nohup` ignores SIGHUP as a second belt; `< /dev/null` detaches stdin; `& disown` drops it from the
  shell's job table.
- Everything the run prints goes to `my_run.log`; pass `-ansi-log false` to Nextflow so the log is plain
  lines (one per task event) instead of a redrawn progress screen.

Put the Nextflow command in a small script rather than on the command line, and end the script with
`echo "EXIT $?"` so the log says how it ended. Example wrapper, the form used for the pilot resume:

```bash
#!/bin/bash
set -euo pipefail
source ~/miniforge3/etc/profile.d/conda.sh
conda activate nf-env
export NXF_VER=25.10.4
cd /home/azureuser/Docs/ALE_nextflow          # .nextflow/history and .nextflow.log live where you launch
nextflow run main.nf -profile ottilie_test,azureD4as,docker -ansi-log false \
    --outdir output_x -w work_x "$@"
echo "EXIT $?"
```

Then:

```bash
setsid nohup ./my_run.sh > my_run.log 2>&1 < /dev/null & disown
tail -f my_run.log                              # follow; Ctrl-C stops the tail, not the run
pgrep -af "nextflow run"                        # is it still alive
grep -c "Submitted process\|Cached process" my_run.log
```

## 2. The alternative: a `tmux` session

`tmux` and `screen` are on the VM. A run started inside a tmux window survives a dropped SSH connection
and lets you reattach to the live console:

```bash
tmux new -s pilot                 # new session; run the command inside it
# ... Ctrl-b d detaches; the connection may drop now
tmux attach -t pilot              # later, from any new shell
```

Prefer `setsid nohup` for anything you want a log file of anyway (every validation run; the log is the
evidence). Prefer tmux when you want to watch the ANSI progress view live.

## 3. Claude Code: background tasks die with the session

A command run with Claude Code's `run_in_background` is tied to that Claude Code session. Ending the
session, closing the window or a session timeout sends SIGTERM down the process tree, which is what
killed the pilot on 2026-11-10. For a long run started from a Claude Code session, launch it with the
`setsid nohup` line above (the session can still `tail` the log and watch for the `EXIT` line); only
short commands belong in a plain background task.

## 4. Recovering a killed run: resume with the explicit session id

Nothing is lost but wall-clock: every finished task is in the work dir. Resume with the **session id**,
never bare `-resume` (which picks whatever ran last in that directory, usually an unrelated test):

```bash
tail -3 .nextflow/history          # columns: time, duration, run name, status, revision, SESSION ID, command
nextflow run main.nf ... -resume <session id> --outdir <the same outdir> -w <the same work dir>
```

Same command, same `--outdir`, same `-w`; the dated-outdir launchers (`run_ottilie_pilot.sh`) compute a
new date on relaunch, so for a resume copy the command out of the script or out of `.nextflow/history`
rather than rerunning the script. A killed run leaves the `.nextflow.log` with the SIGTERM line quoted
above and `WorkflowStats[succeededCount=…; failedCount=0; … abortedCount=N]` right after it: that line is
the proof that nothing failed, keep it with the run's notes.

## 5. What this does not cover

- **A run on Seqera Platform** is not affected: its head job runs on Azure Batch, not in your shell.
- **The local scheduler stall** (tasks queued, nothing running, no error) is a different failure with a
  different fix: [`nextflow_local_executor_deadlock.md`](nextflow_local_executor_deadlock.md).
- **VM reboot or shutdown** kills detached runs too. Idle-shutdown policies on the VM apply.
