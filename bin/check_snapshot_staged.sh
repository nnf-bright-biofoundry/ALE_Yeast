#!/bin/bash
# Commit gate for the "what counts as validated" rule (CLAUDE.md; testing_best_practices.md §12).
#
# Blocks a commit whose STAGED files can change pipeline outputs unless the commit carries a trace
# that the tests were run: the re-recorded e2e snapshot staged alongside, or explicit trailer lines
# in the commit message (Snapshot / Module test / Gate test / Baseline diff). It never runs a test
# and never inspects outputs - it only checks that the commit says which validation happened, so it
# takes milliseconds and any false claim is on record. It also runs bin/check_doc_drift.sh on every
# commit: the docs that copy the tree (module / config / test / doc inventories) must agree with it.
#
#   bin/check_snapshot_staged.sh [commit-message-file]      exit 0 = allow, 2 = block (message on stderr)
#
# Wired as a Claude Code PreToolUse hook on `git commit` (.claude/settings.json) and installable as a
# git hook:  ln -s ../../bin/check_snapshot_staged.sh .git/hooks/commit-msg
set -u
here=$(git rev-parse --show-toplevel)
msg_file="${1:-}"
staged=$(git diff --cached --name-only)
[ -z "$staged" ] && exit 0
msg=""; [ -n "$msg_file" ] && [ -r "$msg_file" ] && msg=$(cat "$msg_file")
fail=0

# 0. documented inventories vs the tree - every commit, milliseconds; each DRIFT line names its fix
bash "$here/bin/check_doc_drift.sh" || fail=1

# 1. new or removed output NAMES in the staged e2e snapshot: every comparison against an older run
#    will show them, so the dated known-differences table must move too (output_comparison.md §2.10).
#    Name lines are the quoted entries without a colon (md5 lines and versions keys carry one).
if grep -q '^tests/ottilie_e2e.nf.test.snap$' <<<"$staged"; then
  names=$(git diff --cached -U0 -- tests/ottilie_e2e.nf.test.snap | grep -E '^[+-][[:space:]]*"[^":]+",?$' || true)
  if [ -n "$names" ] && ! grep -q '^docs/dev-practices/output_comparison.md$' <<<"$staged" \
     && ! grep -qi '^Baseline diff:' <<<"$msg"; then
    fail=1
    cat >&2 <<EOT
BLOCKED: the staged snapshot adds or removes output names ($(wc -l <<<"$names") lines), e.g.:
$(head -8 <<<"$names" | sed 's/^/    /')
Add a dated row to docs/dev-practices/output_comparison.md §2.10 and stage it, or add a trailer line:
      Baseline diff: <why no row is needed>
EOT
  fi
fi

# 2. paths whose change CAN alter pipeline outputs. A task script is a bin/ file that some module's
#    main.nf calls by name - derived here, so launchers, hooks and generators in bin/ stay out of the
#    rule and a .sh task script is covered (2026-09-28: bin/preflight_reference.sh was the first, and
#    the old bin/*.py pattern let it through with no trailer at all).
task_scripts=$(for f in "$here"/bin/*; do n=$(basename "$f"); grep -rq --include=main.nf -F -- "$n" "$here/modules" && echo "bin/$n"; done)
#    A report asset is a repo file or directory that nextflow.config hands to a report process through a
#    `report_*` param under ${projectDir} (the index renderer, its templates, the igv-reports templates and
#    filter config live under docs/igvreports/, not bin/, so the bin/ rule alone let them through -
#    found 2026-10-06 while reviewing the new index UI). Derived from nextflow.config, so a new asset
#    param is covered without touching this file.
report_assets=$(grep -oE '^[[:space:]]*report_[a-z_]+[[:space:]]*=[[:space:]]*"\$\{projectDir\}/[^"]+"' "$here/nextflow.config" \
                | sed -E 's/.*\$\{projectDir\}\///; s/"$//')
behaviour=$({ grep -E '^(conf/modules/|subworkflows/|modules/|workflows/|nextflow\.config$)' <<<"$staged"
              grep -Fx -f <(printf '%s\n' "$task_scripts") <<<"$staged"
              for a in $report_assets; do grep -E "^${a}(/|$)" <<<"$staged"; done; } | sort -u)
if [ -z "$behaviour" ]; then
  [ "$fail" -eq 0 ] && exit 0
  echo "See CLAUDE.md 'What counts as validated' / docs/dev-practices/testing_best_practices.md §12." >&2
  exit 2
fi

# 3. e2e contract test: the .snap must be staged, or the message must claim it did not move
if ! grep -q '^tests/ottilie_e2e.nf.test.snap$' <<<"$staged" && ! grep -qi '^Snapshot: unchanged' <<<"$msg"; then
  fail=1
  cat >&2 <<EOT
BLOCKED: staged changes can alter pipeline outputs, but tests/ottilie_e2e.nf.test.snap is not staged:
$(sed 's/^/    /' <<<"$behaviour")
Run the contract test:  nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test
- outputs moved   -> explain every difference, re-record (--update-snapshot), stage the .snap
- outputs did not -> add a trailer line to the commit message:
      Snapshot: unchanged (e2e green on <commit>, <date>)
EOT
fi

# 4. path -> module/subworkflow test map: each touched entry needs "Module test: <name> green" in the
#    message, one line per test when a value names several (space-separated). bin/check_doc_drift.sh
#    demands an entry for every process / workflow test under tests/.
declare -A TESTMAP=(
  ['conf/modules/trimming.config']=fastp_preprocessing
  ['modules/nf-core/fastp/']=fastp_preprocessing
  ['nextflow.config']=fastp_preprocessing      # its defaults are the test's baseline (2026-09-04: a changed trimming default left it red for a month)
  ['subworkflows/local/split_joint_vcf/']=split_joint_vcf
  ['conf/modules/split_joint_vcf.config']=split_joint_vcf
  ['subworkflows/local/fastqc_trimmed/']=fastqc_trimmed
  ['subworkflows/local/utils_nfcore_sarek_pipeline/']=preflight
  ['subworkflows/local/bam_variant_calling_germline_manta/']=manta_experiment_grouping
  ['subworkflows/local/bam_joint_calling_germline_gatk/']=joint_calling_output_selection
  ['conf/modules/joint_germline.config']='joint_calling_output_selection variantfiltration_fallback'   # ext.prefix names (stub) + the soft-filter ext.args on real data
  ['modules/nf-core/gatk4/variantfiltration/']=variantfiltration_fallback
  ['modules/local/preflight_reference/']=preflight_reference
  ['bin/preflight_reference.sh']=preflight_reference
  ['conf/modules/preflight.config']=preflight_reference
  ['conf/modules/annotate.config']=snpeff_codon_table      # SNPEFF_SNPEFF ext.args; the codonTable line of the cache's snpEff.config is read at annotation time
  ['modules/nf-core/snpeff/snpeff/']=snpeff_codon_table
  ['modules/local/genbank_reference/']=genbank_reference
  ['bin/genbank_to_reference.py']=genbank_reference
  ['modules/local/snpeff_build/']=snpeff_build
  ['bin/snpeff_build_gates.sh']=snpeff_build
  ['conf/modules/genbank_reference.config']='genbank_reference snpeff_build'
)
for path in "${!TESTMAP[@]}"; do
  if grep -q "^${path}" <<<"$staged"; then
    for t in ${TESTMAP[$path]}; do
      if ! grep -qi "^Module test: ${t} green" <<<"$msg"; then
        fail=1
        cat >&2 <<EOT
BLOCKED: $path is staged; its unit test must be cited in the commit message:
      Module test: ${t} green
  (run: nf-test test -c tests/nf-test-ottilie.config tests/${t}.nf.test)
EOT
      fi
    done
  fi
done

# 5. the --qc_only gate works by starvation, so any workflow/subworkflow change can break it silently
#    (a toList()/ifEmpty()/value channel feeding a process downstream of alignment): part (a) of
#    tests/qc_gate.sh (minutes) must be cited for changes under workflows/ or subworkflows/
if grep -qE '^(workflows/|subworkflows/)' <<<"$staged" && ! grep -qi '^Gate test: qc_gate (a) green' <<<"$msg"; then
  fail=1
  cat >&2 <<EOT
BLOCKED: a workflow/subworkflow file is staged; the --qc_only gate test must be cited in the commit message:
      Gate test: qc_gate (a) green
  (run: tests/qc_gate.sh a  — minutes; docs/dev-practices/SAREK_MODIFICATIONS.md → the --qc_only gate)
EOT
fi

[ "$fail" -eq 0 ] && exit 0
echo "See CLAUDE.md 'What counts as validated' / docs/dev-practices/testing_best_practices.md §12." >&2
exit 2
