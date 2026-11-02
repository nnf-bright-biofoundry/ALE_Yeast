#!/usr/bin/env bash
# The two gates of SNPEFF_BUILD (modules/local/snpeff_build), as rows of the "yAMP input checks" MultiQC
# table, after `snpEff build -genbank` has run (docs/dev-practices/genbank_reference_input.md §5.3):
#
#   snpEff build: protein check   OK       every CDS with a /translation translates to it (Errors: 0),
#                                          which verifies the gene models and the genetic code at once
#                                 SKIPPED  the file carries no /translation (--no-protein-check)
#                                 ERROR    Errors > 0, or the build produced no database
#   snpEff build: contig names    OK       the names stored in the cache equal the expected list
#                                 SKIPPED  no expected list given
#                                 ERROR    a name missing from the cache or unexpected in it
#
# Console lines only for ERROR (the "no [yAMP preflight] line on a clean run" rule); exit 65 on ERROR
# after writing the table, so the module's errorStrategy stops the run. The header is the one
# bin/preflight_reference.sh and preflightTable() write; keep the three identical.
#
# Usage: snpeff_build_gates.sh --db <name> --cache <dataDir> --log <build log> [--no-protein-check]
#                              [--expected <file>] [--out snpeff_build_mqc.tsv]
set -euo pipefail

db='' cache='' log='' expected='' out='snpeff_build_mqc.tsv' check_protein=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)       db=$2;       shift 2 ;;
        --cache)    cache=$2;    shift 2 ;;
        --log)      log=$2;      shift 2 ;;
        --expected) expected=$2; shift 2 ;;
        --out)      out=$2;      shift 2 ;;
        --no-protein-check) check_protein=0; shift ;;
        *) echo "snpeff_build_gates.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
[[ -n "$db" && -n "$cache" && -n "$log" ]] || { echo "snpeff_build_gates.sh: --db, --cache and --log are required" >&2; exit 2; }
[[ -r "$log" ]] || { echo "snpeff_build_gates.sh: cannot read build log '$log'" >&2; exit 2; }

errors=0
rows=()
verdict() {   # STATUS CHECK DETAIL
    local status=$1 check=$2 detail=$3
    rows+=("${check}"$'\t'"${status}"$'\t'"${detail}")
    if [[ "$status" == ERROR ]]; then
        echo "[yAMP preflight] ERROR ${check}: ${detail}"
        echo "[yAMP preflight] ERROR ${check}: ${detail}" >&2
        errors=$((errors + 1))
    fi
}

# --- gate 1: the build itself and its protein check --------------------------------------------------
# snpEff writes no database when its check fails ("Database check failed"), so read the check line
# first: a failed check is reported as such, a missing database with no check line as a build failure.
check='snpEff build: protein check'
line=$(grep -m1 'Protein check:' "$log" || true)
n_err=0
if [[ -n "$line" ]]; then
    n_ok=$(sed -E 's/.*OK: ([0-9]+).*/\1/' <<<"$line")
    n_nf=$(sed -E 's/.*Not found: ([0-9]+).*/\1/' <<<"$line")
    n_err=$(sed -E 's/.*Errors: ([0-9]+).*/\1/' <<<"$line")
fi
if (( check_protein == 1 )) && [[ -n "$line" ]] && [[ "$n_err" != 0 ]]; then
    verdict ERROR "$check" "${n_err} of $((n_ok + n_err)) CDS do not translate to the file's /translation (OK: ${n_ok}, Errors: ${n_err}): a wrong genetic code (/transl_table) or broken gene models in ${db}; see the build log"
elif [[ ! -s "$cache/$db/snpEffectPredictor.bin" ]]; then
    last=$(grep -v '^[[:space:]]*$' "$log" | grep -v 'WARNING_' | tail -1 | cut -c1-200)
    verdict ERROR "$check" "snpEff build produced no database for ${db}; last log line: ${last}"
elif (( check_protein == 0 )); then
    verdict SKIPPED "$check" "the GenBank carries no /translation, so snpEff cannot compare its translation of the CDS with the file's; the gene models and the genetic code are unverified"
elif [[ -z "$line" ]]; then
    verdict ERROR "$check" "no 'Protein check:' line in the snpEff build log for ${db}"
else
    verdict OK "$check" "${n_ok} CDS translate to the file's /translation, ${n_nf} without one (Errors: 0): gene models and genetic code verified for ${db}"
fi

# --- gate 2: the names stored in the cache against the expected list ----------------------------------
check='snpEff build: contig names'
if [[ -s "$cache/$db/snpEffectPredictor.bin" && -n "$expected" ]]; then
    stored=$(snpEff dump -bed -dataDir "$(cd "$cache" && pwd)" "$db" 2>/dev/null \
        | awk -F'\t' '$4 ~ /^Chromosome_/ { sub(/^Chromosome_/, "", $4); print $4 }' | sort -u)
    want=$(grep -v '^[[:space:]]*$' "$expected" | sort -u)
    missing=$(comm -13 <(printf '%s\n' "$stored") <(printf '%s\n' "$want") | tr '\n' ' ')
    extra=$(comm -23 <(printf '%s\n' "$stored") <(printf '%s\n' "$want") | tr '\n' ' ')
    n_stored=$(grep -c . <<<"$stored" || true)
    if [[ -z "${missing// }" && -z "${extra// }" ]]; then
        verdict OK "$check" "${n_stored} contig name(s) in the cache, equal to the expected list"
    else
        verdict ERROR "$check" "cache contig names differ from the FASTA-derived list${missing:+; missing from the cache: ${missing}}${extra:+; only in the cache: ${extra}}. Variants on a missing contig would be ERROR_CHROMOSOME_NOT_FOUND, silently"
    fi
elif [[ -z "$expected" ]]; then
    verdict SKIPPED "$check" "no expected contig list given"
fi

{
    cat <<'HEADER'
# id: 'yamp_input_checks'
# section_name: 'yAMP input checks'
# description: "What the pipeline checked before aligning any read (docs/usage/preflight_checks.md): the samplesheet and the parameters when the run starts, the reference files in its first task. A failed check stops the run before any report is written, so this table lists what passed (OK) and what was flagged (WARN); WARN lines are also printed on the console with the [yAMP preflight] prefix."
# plot_type: 'table'
# pconfig:
#     id: 'yamp_input_checks_table'
#     namespace: 'yAMP input checks'
#     sort_rows: false
# headers:
#     status:
#         title: 'Status'
#         description: 'OK, WARN or SKIPPED (an ERROR stops the run)'
#     detail:
#         title: 'Detail'
#         description: 'What was checked and what was found'
HEADER
    printf 'Check\tstatus\tdetail\n'
    printf '%s\n' "${rows[@]}"
} > "$out"

if (( errors > 0 )); then
    echo "[yAMP preflight] ${errors} snpEff build gate(s) failed, stopping the run (table: ${out})" >&2
    exit 65
fi
