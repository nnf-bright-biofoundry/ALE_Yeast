#!/usr/bin/env python
"""Replay what Nextflow's local scheduler had reserved over a run, from the run's own log.

The local executor starts a task only when its CPU and memory request fits what the scheduler's
counters say is free. This script rebuilds those reservations from the outside: every
"Submitted process" line adds the task's request, every "Task completed" line gives it back. It
prints the highest reservation reached, the state at the end, and the last moment each CPU level
was reached, which is how a budget that silently shrank shows up (docs/usage/
nextflow_local_executor_deadlock.md, occurrence of 2026-11-09).

Two steps, so the evidence can be kept without keeping a 670 KB log:

  # 1. log -> events table (time, +/-, process, tag); optionally the requests table from the
  #    `docker run --cpu-shares N --memory Mm` line of each task's .command.run
  python replay.py extract <nextflow.log> <events.tsv> [--work <work dir> <requests.tsv>]

  # 2. events + requests -> the replay
  python replay.py replay <events.tsv> <requests.tsv> [--cpus 4] [--memory-mb 15974]

  # 3. which tasks were provably waiting although the replay says they fitted (needs task ids,
  #    so an events table extracted with --trace)
  python replay.py pending <events.tsv> <requests.tsv> [--cpus 4] [--memory-mb 15974]

Step 3 rests on one fact: Nextflow numbers tasks in the order it creates them. A task therefore
existed, and was waiting, from no later than the first submission of any task with a higher id. For
each such window the script adds up the time the task's request fitted the free budget of the
replay. It prints the same sum for two reduced budgets (one CPU fewer; 12 GB less memory, the
largest give-back in the run's last minute), which is how the lost resource is told apart.

Requests are per process name (the last element of the qualified name): on the test set every task
of one process has the same request, which `extract --work` verifies. Python standard library only.
"""
import argparse
import csv
import glob
import os
import re
import sys

SUBMIT = re.compile(r"^(\w{3}-\d\d [\d:.]+) .*Submitted process > (\S+)(?: \(([^)]*)\))?")
DONE = re.compile(r"^(\w{3}-\d\d [\d:.]+) .*Task completed > TaskHandler\[id: (\d+); name: ([^ ;]+)(?: \(([^)]*)\))?; "
                  r"status: (\w+); exit: (\S+);")
QUEUED = re.compile(r"^~> TaskHandler\[id: (\d+); name: ([^ ;]+)(?: \(([^)]*)\))?; status: NEW;")


def extract(args):
    # (process, tag) -> [[submit time in s, task id], ...] from the trace file. The trace and the log stamp
    # one submission up to a few ms apart, so a submission takes the nearest unused entry within 50 ms.
    by_name = {}
    if args.trace:
        for r in csv.DictReader(open(args.trace), delimiter="\t"):
            name, _, tag = r["name"].partition(" (")
            by_name.setdefault((name.split(":")[-1], tag.rstrip(")")), []).append([seconds(r["submit"]), r["task_id"]])

    def task_id(stamp, proc, tag):
        cands = by_name.get((proc, tag), [])
        if not cands:
            return ""
        best = min(cands, key=lambda c: abs(c[0] - seconds(stamp)))
        if abs(best[0] - seconds(stamp)) > 0.05:
            return ""
        cands.remove(best)
        return best[1]
    rows = []
    queued = {}         # tasks of the LAST "tasks in the submission queue" dump: created, never submitted
    with open(args.log, errors="replace") as fh:
        for line in fh:
            m = SUBMIT.match(line)
            if m:
                proc, tag = m.group(2).split(":")[-1], m.group(3) or ""
                rows.append((m.group(1), "+", proc, tag, "", task_id(m.group(1), proc, tag)))
                continue
            m = DONE.match(line)
            if m:
                rows.append((m.group(1), "-", m.group(3).split(":")[-1], m.group(4) or "", m.group(6), m.group(2)))
                continue
            if "tasks in the submission queue" in line:
                queued = {}
                stamp = line[:19]
                continue
            m = QUEUED.match(line)
            if m:
                queued[m.group(1)] = (stamp, "?", m.group(2).split(":")[-1], m.group(3) or "", "", m.group(1))
    done_ids = {r[5] for r in rows if r[1] == "-"}
    rows += [q for i, q in queued.items() if i not in done_ids]
    with open(args.events, "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(["time", "event", "process", "tag", "exit", "id"])
        w.writerows(rows)
    print(f"{args.events}: {sum(r[1] == '+' for r in rows)} submitted, {sum(r[1] == '-' for r in rows)} completed, "
          f"{sum(r[1] == '?' for r in rows)} left in the submission queue")
    if args.work:
        work, out = args.work
        req = {}
        for f in glob.glob(os.path.join(work, "*", "*", ".command.run")):
            text = open(f).read()
            name = re.search(r"###\s*name: '([^']+)'", text).group(1).split(" ")[0].split(":")[-1]
            cpus = int(re.search(r"--cpu-shares (\d+)", text).group(1)) // 1024
            mem = int(re.search(r"--memory (\d+)m", text).group(1))
            req.setdefault(name, set()).add((cpus, mem))
        varying = {k: v for k, v in req.items() if len(v) > 1}
        if varying:
            sys.exit(f"processes whose tasks differ in their request, the per-process table does not hold: {varying}")
        with open(out, "w", newline="") as fh:
            w = csv.writer(fh, delimiter="\t", lineterminator="\n")
            w.writerow(["process", "cpus", "memory_mb"])
            for name in sorted(req):
                w.writerow([name, *next(iter(req[name]))])
        print(f"{out}: {len(req)} processes")


def seconds(stamp):
    h, m, s = stamp.split(" ")[1].split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def replay(args):
    req = {r["process"]: (int(r["cpus"]), int(r["memory_mb"])) for r in csv.DictReader(open(args.requests), delimiter="\t")}
    events = [e for e in csv.DictReader(open(args.events), delimiter="\t") if e["event"] in "+-"]
    # completions before submissions at an equal timestamp: the order the scheduler needs to stay in budget
    events.sort(key=lambda e: (seconds(e["time"]), e["event"] == "+"))
    missing = sorted({e["process"] for e in events} - set(req))
    if missing:
        sys.exit(f"no request known for: {', '.join(missing)}")
    cpus = mem = running = 0
    peak_cpus = peak_mem = peak_running = 0
    over = 0
    last_at = {}        # cpu level -> (index, time) of the last moment it was reached
    hist = []
    for i, e in enumerate(events):
        c, m = req[e["process"]]
        sign = 1 if e["event"] == "+" else -1
        cpus += sign * c
        mem += sign * m
        running += sign
        peak_cpus, peak_mem, peak_running = max(peak_cpus, cpus), max(peak_mem, mem), max(peak_running, running)
        if sign > 0 and (cpus > args.cpus or mem > args.memory_mb):
            over += 1
        last_at[cpus] = (i, e["time"])
        hist.append((e, cpus, mem, running))
    n_sub = sum(e["event"] == "+" for e in events)
    n_done = len(events) - n_sub
    nonzero = [e for e in events if e["event"] == "-" and e["exit"] != "0"]
    print(f"events: {n_sub} submitted, {n_done} completed, {len(nonzero)} with a non-zero exit")
    print(f"budget: {args.cpus} cpus, {args.memory_mb} MB")
    print(f"highest reservation: {peak_cpus} cpus, {peak_mem} MB, {peak_running} tasks at once")
    print(f"submissions that put the replay over the budget: {over}")
    print(f"at the end: {cpus} cpus, {mem} MB, {running} tasks")
    print("last moment each CPU level was reserved:")
    for level in sorted(last_at, reverse=True):
        i, t = last_at[level]
        print(f"  {level} cpus: {t}  (event {i + 1} of {len(events)})")
    top = max(last_at)
    i_top = last_at[top][0]
    after = hist[i_top + 1:]
    if after:
        full = [e["process"] for e, _, _, _ in after if e["event"] == "+" and req[e["process"]][0] >= args.cpus]
        print(f"after the last {top}-cpu moment: highest reservation {max(h[1] for h in after)} cpus over {len(after)} events; "
              f"tasks submitted that request the whole CPU budget: {len(full)}")
        if args.context:
            print(f"events around the last {top}-cpu moment:")
            for e, c, m, r in hist[max(0, i_top - 3):i_top + args.context]:
                print(f"  {e['time'].split(' ')[1]} {e['event']} {e['process']:26}{e['tag'][:28]:30}cpus {c}  mem {m:>6}  running {r}")


def pending(args):
    req = {r["process"]: (int(r["cpus"]), int(r["memory_mb"])) for r in csv.DictReader(open(args.requests), delimiter="\t")}
    tasks = {}
    for e in csv.DictReader(open(args.events), delimiter="\t"):
        if not e["id"]:
            sys.exit("the events table has submissions without a task id: extract it again with --trace")
        t = tasks.setdefault(int(e["id"]), {"p": e["process"], "tag": e["tag"], "sub": None, "done": None})
        if e["event"] == "+":
            t["sub"] = seconds(e["time"])
        elif e["event"] == "-":
            t["done"] = seconds(e["time"])
    ids = sorted(tasks)
    times = sorted({t[k] for t in tasks.values() for k in ("sub", "done") if t[k] is not None})
    end = times[-1]

    def reserved(at):
        c = m = 0
        for t in tasks.values():
            if t["sub"] is not None and t["sub"] <= at and (t["done"] is None or t["done"] > at):
                c += req[t["p"]][0]
                m += req[t["p"]][1]
        return c, m

    def clock(x):
        return "never" if x is None else f"{int(x // 3600):02d}:{int(x % 3600 // 60):02d}:{x % 60:06.3f}"

    budgets = {"full": (args.cpus, args.memory_mb), "cpu-1": (args.cpus - 1, args.memory_mb),
               "mem-12GB": (args.cpus, args.memory_mb - 12288)}
    rows = []
    windows = 0
    for i in ids:
        t = tasks[i]
        later = [tasks[j]["sub"] for j in ids if j > i and tasks[j]["sub"] is not None]
        if not later:
            continue
        since = min(later)                      # proven to exist from here
        until = t["sub"] if t["sub"] is not None else end
        if since >= until and t["sub"] is not None:
            continue
        windows += 1
        pts = [since] + [x for x in times if since < x < until] + [until]
        fit = dict.fromkeys(budgets, 0.0)
        first = None
        for a, b in zip(pts, pts[1:]):
            c, m = reserved(a)
            for name, (bc, bm) in budgets.items():
                if c + req[t["p"]][0] <= bc and m + req[t["p"]][1] <= bm:
                    fit[name] += b - a
                    if name == "full" and first is None:
                        first = a
        if t["sub"] is None:                    # still queued when the log ends: fits whenever the end state does
            c, m = reserved(end)
            for name, (bc, bm) in budgets.items():
                if c + req[t["p"]][0] <= bc and m + req[t["p"]][1] <= bm:
                    fit[name] = float("inf")
                    if name == "full" and first is None:
                        first = end
        if fit["full"] > args.min_seconds:
            rows.append((i, t, since, first, fit))
    print(f"budget: {args.cpus} cpus, {args.memory_mb} MB; tasks with a proven waiting window: {windows}")
    print(f"waiting although the request fitted for more than {args.min_seconds} s: {len(rows)}")
    print(f"{'id':>4}  {'process':20}{'tag':16}{'waiting since':>13} {'submitted':>13} {'first fit':>13} {'fit s':>7} {'at cpu-1':>9} {'at mem-12GB':>12}")
    for i, t, since, first, fit in rows:
        f = lambda v: "no end" if v == float("inf") else f"{v:.1f}"
        print(f"{i:>4}  {t['p']:20}{t['tag'][:14]:16}{clock(since):>13} {clock(t['sub']):>13} {clock(first):>13} "
              f"{f(fit['full']):>7} {f(fit['cpu-1']):>9} {f(fit['mem-12GB']):>12}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("extract")
    a.add_argument("log")
    a.add_argument("events")
    a.add_argument("--work", nargs=2, metavar=("WORK_DIR", "REQUESTS_TSV"))
    a.add_argument("--trace", help="the run's trace file (task_id, name, submit): adds the task id to each submission")
    a.set_defaults(func=extract)
    b = sub.add_parser("replay")
    b.add_argument("events")
    b.add_argument("requests")
    b.add_argument("--cpus", type=int, default=4)
    b.add_argument("--memory-mb", type=int, default=15974, help="15.6 GB, the budget the stalled run logged")
    b.add_argument("--context", type=int, default=0, help="print this many events after the last top-level moment")
    b.set_defaults(func=replay)
    c = sub.add_parser("pending")
    c.add_argument("events")
    c.add_argument("requests")
    c.add_argument("--cpus", type=int, default=4)
    c.add_argument("--memory-mb", type=int, default=15974)
    c.add_argument("--min-seconds", type=float, default=0.5)
    c.set_defaults(func=pending)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
