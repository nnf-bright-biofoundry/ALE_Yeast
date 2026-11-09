#!/bin/bash
# The --qc_only gate test (docs/usage/qc_first_run.md; the rule it guards is documented in
# docs/dev-practices/SAREK_MODIFICATIONS.md → "workflows/sarek/main.nf" → the --qc_only gate).
#
# The gate works by STARVATION: --qc_only empties the alignment input and every process downstream
# of it never receives a task. That holds only while nothing downstream of alignment can fire on
# EMPTY input — a toList(), an ifEmpty(...), a value channel or a plain-file input as a process's
# only inputs would make it run in a QC-only run, silently. This script pins the property.
#
#   tests/qc_gate.sh a                      part (a), minutes. Run 1 = the ottilie test set with --qc_only.
#                                           The execution trace must contain EXACTLY the allow-listed
#                                           processes below (read QC + reference preparation; plus the
#                                           two --genbank reference tasks when the launch takes that
#                                           route), and the completion message must name a report that
#                                           exists and the session id to resume.
#                                           QC_GATE_PARAMS_FILE=<file> adds -params-file to both launches
#                                           (e.g. tests/qc_gate_genbank_params.yml: the test set on the
#                                           --genbank route).
#   tests/qc_gate.sh b <reference_outdir>   part (b), about one e2e. Run 2 = the same command without
#                                           --qc_only, with -resume <run-1 session>. Every run-1 task
#                                           except MULTIQC_READ_QC must be CACHED, the task list must equal the
#                                           reference run's, and the deliverables must equal the
#                                           reference's (tests/qc_gate_compare.py: names + content).
#
# Reference for (b): a ONE-SHOT run of the same commit on the same profile — the e2e's output dir
# (.nf-test/tests/<hash>/output after `nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test`;
# its trace is read from the sibling meta/trace.csv, where nf-test redirects it).
# Dirs: output_qc_gate/ and work_qc_gate/ at the repo root (both gitignored); part (b) reuses part (a)'s.
# Requires: NXF_VER=25.10.4 (set here), docker, the local test data (bin/../data/ottilie, see README).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export NXF_VER=${NXF_VER:-25.10.4}
part=${1:-}
outdir=${QC_GATE_OUTDIR:-$here/output_qc_gate}
workdir=${QC_GATE_WORKDIR:-$here/work_qc_gate}
profile=${QC_GATE_PROFILE:-ottilie_test,docker}
params_file=${QC_GATE_PARAMS_FILE:-}     # optional -params-file, e.g. one that switches the profile to --genbank
launch=( nextflow run "$here/main.nf" -profile "$profile" -c "$here/tests/ottilie_nftest_resources.config"
         --outdir "$outdir" -w "$workdir" -ansi-log false )
[ -n "$params_file" ] && launch+=( -params-file "$params_file" )
cd "$here"   # repo-relative paths in a params file resolve against the launch directory; every output path above is absolute

# The allow-list: every process a QC-only run of the ottilie profile may execute. Read QC (raw FastQC,
# fastp, FastQC on its output, the read-QC MultiQC report — the alignment-QC and complete-QC ones are
# starved under --qc_only in workflows/sarek/main.nf) plus reference preparation, the GFF3 index and the reference
# preflight task, which take plain file inputs and are deliberately ungated (seconds, cached, and run 2
# needs them anyway — the preflight is the point of run 1).
# With split_fastq > 0 (not the ottilie profile) FASTQC_TRIMMED_QC:CAT_FASTQ_TRIMMED joins the list.
ALLOW=(
  NFCORE_SAREK:PREPARE_GENOME:BWAMEM1_INDEX
  NFCORE_SAREK:PREPARE_GENOME:GATK4_CREATESEQUENCEDICTIONARY
  NFCORE_SAREK:PREPARE_GENOME:SAMTOOLS_FAIDX
  NFCORE_SAREK:PREPARE_INTERVALS:BUILD_INTERVALS
  NFCORE_SAREK:PREPARE_INTERVALS:CREATE_INTERVALS_BED
  NFCORE_SAREK:PREPARE_INTERVALS:TABIX_BGZIPTABIX_INTERVAL_COMBINED
  NFCORE_SAREK:PREPARE_INTERVALS:TABIX_BGZIPTABIX_INTERVAL_SPLIT
  NFCORE_SAREK:PREPARE_REFERENCE_CNVKIT:CNVKIT_ANTITARGET
  NFCORE_SAREK:PREPARE_REFERENCE_CNVKIT:CNVKIT_REFERENCE
  NFCORE_SAREK:SAREK:FASTP
  NFCORE_SAREK:SAREK:FASTQC
  NFCORE_SAREK:SAREK:FASTQC_TRIMMED_QC:FASTQC_TRIMMED
  NFCORE_SAREK:SAREK:MULTIQC_READ_QC
  NFCORE_SAREK:SAREK:MUTATION_REPORT:PREPARE_GFF3
  NFCORE_SAREK:SAREK:PREFLIGHT_REFERENCE
)
# The --genbank reference route (main.nf) adds its two reference tasks, both before alignment and
# needed by run 2 like the rest of reference preparation. Which route run 1 took is read from its
# parameter summary (every non-default parameter is printed; genbank is null by default), so the
# list stays exact on either route.
ALLOW_GENBANK=( NFCORE_SAREK:GENBANK_REFERENCE NFCORE_SAREK:SNPEFF_BUILD )
took_genbank_route() { sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -qE '^[[:space:]]*genbank[[:space:]]+: [^[:space:]]'; }

fail() { echo "qc_gate FAIL: $*" >&2; exit 1; }
# newest execution trace of an outdir; an nf-test output dir keeps its trace next door in meta/trace.csv
# (same tab format) because nf-test redirects -with-trace there. Prints nothing when there is none.
newest_trace() {
  local t; t=$(ls -t "$1"/pipeline_info/execution_trace_*.txt 2>/dev/null | head -1 || true)
  [ -n "$t" ] || { [ -f "$1/../meta/trace.csv" ] && t="$1/../meta/trace.csv"; }
  echo "${t:-}"
}
# trace → "<name>\t<status>" per task; name = full process name + tag
trace_rows() { awk -F'\t' 'NR==1{for(i=1;i<=NF;i++){if($i=="name")n=i;if($i=="status")s=i}; next} {print $n "\t" $s}' "$1"; }
# trace → sorted unique full process names (tag stripped)
trace_processes() { trace_rows "$1" | cut -f1 | sed -E 's/ \(.*$//' | sort -u; }

case "$part" in
  a)
    if [ -e "$outdir" ] && [ ! -e "$outdir/.qc_gate" ]; then
      fail "$outdir exists and was not written by this script — refusing to overwrite it (set QC_GATE_OUTDIR)"
    fi
    rm -rf "$outdir" "$workdir"; mkdir -p "$outdir"; touch "$outdir/.qc_gate"
    echo "qc_gate (a): run 1 --qc_only → $outdir"
    "${launch[@]}" --qc_only 2>&1 | tee "$outdir/qc_gate_run1.log"

    # the completion message: session id + a report that exists
    session=$(grep -oE 'with -resume [0-9a-f-]{36}' "$outdir/qc_gate_run1.log" | head -1 | awk '{print $3}')
    [ -n "$session" ] || fail "no '[yAMP qc_only] … -resume <session id>' completion message in the run-1 output"
    echo "$session" > "$outdir/.qc_gate_session"
    report=$(grep -oE 'MultiQC report : .*' "$outdir/qc_gate_run1.log" | head -1 | sed 's/^MultiQC report : //')
    [ -n "$report" ] && [ -f "$report" ] || fail "the report named in the completion message does not exist: '$report'"
    ls "$outdir"/reports/fastqc/*/trimmed/*_trimmed_1_fastqc.zip >/dev/null 2>&1 || fail "no post-trim FastQC output under $outdir/reports/fastqc/*/trimmed/"

    # the trace: exactly the allow-list
    trace=$(newest_trace "$outdir"); [ -n "$trace" ] || fail "no execution trace under $outdir/pipeline_info/"
    cp "$trace" "$outdir/.qc_gate_trace_run1.txt"
    ran=$(trace_processes "$trace")
    took_genbank_route "$outdir/qc_gate_run1.log" && ALLOW+=( "${ALLOW_GENBANK[@]}" )
    allowed=$(printf '%s\n' "${ALLOW[@]}" | sort -u)
    stray=$(comm -23 <(echo "$ran") <(echo "$allowed"))
    missing=$(comm -13 <(echo "$ran") <(echo "$allowed"))
    if [ -n "$stray" ]; then
      echo "qc_gate FAIL: process(es) ran under --qc_only that are not on the allow-list:" >&2
      sed 's/^/    /' <<<"$stray" >&2
      echo "  A process downstream of alignment fired on EMPTY input (toList(), ifEmpty(...), a value channel or a" >&2
      echo "  plain-file input as its only inputs). Either gate it on params.qc_only or, if it is harmless reference" >&2
      echo "  preparation, add it to ALLOW in tests/qc_gate.sh. Rule and rationale: docs/dev-practices/SAREK_MODIFICATIONS.md" >&2
      echo "  → 'workflows/sarek/main.nf' → the --qc_only gate." >&2
      exit 1
    fi
    if [ -n "$missing" ]; then
      echo "qc_gate FAIL: allow-listed process(es) did NOT run — the read-QC stage itself changed:" >&2
      sed 's/^/    /' <<<"$missing" >&2
      exit 1
    fi
    n=$(trace_rows "$trace" | wc -l)
    echo "qc_gate (a) PASS: $n tasks, exactly the $(wc -l <<<"$allowed") allow-listed processes; session $session; report $report"
    ;;

  b)
    ref=${2:-}; [ -n "$ref" ] && [ -d "$ref" ] || fail "usage: tests/qc_gate.sh b <reference_outdir>  (a one-shot run's --outdir)"
    ref=$(cd "$ref" && pwd)
    [ -f "$outdir/.qc_gate_session" ] || fail "run part (a) first ($outdir/.qc_gate_session missing)"
    session=$(cat "$outdir/.qc_gate_session")
    echo "qc_gate (b): run 2 -resume $session → $outdir (reference: $ref)"
    # QC_GATE_SKIP_RUN=1 re-checks an existing run 2 without launching it again (test development)
    [ -n "${QC_GATE_SKIP_RUN:-}" ] || "${launch[@]}" -resume "$session" 2>&1 | tee "$outdir/qc_gate_run2.log"
    grep -q 'Pipeline completed successfully' "$outdir/qc_gate_run2.log" || fail "run 2 did not complete successfully"

    trace2=$(newest_trace "$outdir")
    [ "$trace2" != "$outdir/.qc_gate_trace_run1.txt" ] && [ -n "$trace2" ] || fail "no run-2 trace"
    # 1. every run-1 task except the read-QC MultiQC report (its input-checks table and workflow summary
    #    carry qc_only) is a cache hit in run 2
    not_cached=$(join -t $'\t' <(trace_rows "$outdir/.qc_gate_trace_run1.txt" | cut -f1 | grep -v ':MULTIQC_READ_QC$' | sort) \
                               <(trace_rows "$trace2" | sort) | awk -F'\t' '$2 != "CACHED"' || true)
    [ -z "$not_cached" ] || { echo "qc_gate FAIL: run-1 task(s) re-ran in run 2 instead of resuming (a task hash moved):" >&2; sed 's/^/    /' <<<"$not_cached" >&2; exit 1; }
    # 2. run 2 executed exactly the reference run's task list
    ref_trace=$(newest_trace "$ref"); [ -n "$ref_trace" ] || fail "no execution trace under $ref/pipeline_info/"
    if ! diff <(trace_rows "$trace2" | cut -f1 | sort) <(trace_rows "$ref_trace" | cut -f1 | sort) >/dev/null; then
      echo "qc_gate FAIL: run 2's task list differs from the reference run's (< run 2, > reference):" >&2
      diff <(trace_rows "$trace2" | cut -f1 | sort) <(trace_rows "$ref_trace" | cut -f1 | sort) | sed 's/^/    /' >&2 || true
      exit 1
    fi
    # 3. deliverables: names + content (tests/qc_gate_compare.py)
    python "$here/tests/qc_gate_compare.py" "$ref" "$outdir" || fail "outputs differ from the reference one-shot run"
    cached=$(trace_rows "$trace2" | awk -F'\t' '$2=="CACHED"' | wc -l); total=$(trace_rows "$trace2" | wc -l)
    echo "qc_gate (b) PASS: $cached/$total tasks cached, task list and deliverables equal the reference run"
    ;;
  *)
    sed -n '2,25p' "$0"; exit 2 ;;
esac
