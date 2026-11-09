#!/usr/bin/env bash
# yAMP preflight, task level: do the reference files handed to the pipeline agree with each other?
#
# Runs inside PREFLIGHT_REFERENCE (modules/local/preflight_reference) — a task rather than a
# DAG-build check, so cloud paths are staged like any other input. User page:
# docs/usage/preflight_checks.md.
#
# Two checks, one row each in the MultiQC table this writes. A new check is a new function below,
# one more verdict row, and a fixture pair under tests/fixtures/preflight_reference/.
#
#   FASTA vs GFF3 contig names — the GFF3 given as --report_gff3 is the gene track of the mutation
#     report, so its contig names must be the FASTA's. ERROR when the two share no name: the track
#     would be empty and nothing downstream would complain. Otherwise OK; when some GFF3 contigs have
#     no FASTA sequence the row says which — their features are simply not shown, the normal picture
#     for a chromosome-subset reference (the release test set is one: 4 chromosomes against the
#     full-genome GFF3). FASTA contigs without annotation (cassettes, plasmids) are not reported.
#     Both deliberate (decision 2026-09-28: ship the case that is silent today, refine when a real
#     input error shows the need — e.g. a partial naming mismatch such as Mito vs chrM). Same
#     no-shared-name rule as docs/prepare_input/build_snpeff_cache.sh applies to the cache build.
#     An embedded ##FASTA section (SGD and GenBank-converted GFF3 files) is ignored.
#
#   snpEff cache vs FASTA contig names (the pre-built route, --snpeff_cache + --snpeff_db; added
#     2026-11-09 with the GenBank route, whose build gates compare the same names) — snpEff annotates
#     a variant only when its CHROM is a chromosome of the database; otherwise it logs
#     ERROR_CHROMOSOME_NOT_FOUND and writes an unannotated record, and nothing else complains. The
#     database's names are read from <cache>/<db>/snpEffectPredictor.bin (snpEff 5.1 serialises its
#     markers as gzipped tab-separated text; one CHROMOSOME line per contig, the name in column 6),
#     the FASTA's are SIMPLIFIED the way snpEff stores and looks them up (a leading chr / chromo /
#     chromosome, any case, and leading zeros stripped, repeatedly; bin/genbank_to_reference.py
#     documents the measurement). ERROR when no name is shared, or when <db>/ or its database file
#     is missing (the cloud-path case ANNOTATION_CACHE_INITIALISATION cannot check); WARN when some
#     FASTA contigs are not in the database (their variants would silently stay unannotated); OK
#     otherwise, noting the database's extra contigs — the SUBSET case is the release test set
#     (4 chromosomes against the 17-contig cache). SKIPPED without a pre-built cache (snpEff not in
#     --tools, or the database is built from --genbank).
#
# Console: verdict lines only (ERROR — and WARN, should a future check use it — prefixed
# [yAMP preflight]). A clean reference prints nothing, so "no [yAMP preflight] line" keeps meaning
# "clean". Exit 0 on OK / WARN / SKIPPED, 65
# (EX_DATAERR) on ERROR — outside the pipeline's retry range (130–145, 104); the process's
# errorStrategy is 'terminate' (conf/modules/preflight.config).
#
# Usage: preflight_reference.sh --fasta ref.fa [--gff3 genes.gff3] [--snpeff-cache DIR --snpeff-db NAME]
#                               [--out preflight_reference_mqc.tsv]

set -euo pipefail

fasta='' gff3='' cache='' db='' out='preflight_reference_mqc.tsv'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fasta)        fasta=$2; shift 2 ;;
        --gff3)         gff3=$2;  shift 2 ;;
        --snpeff-cache) cache=$2; shift 2 ;;
        --snpeff-db)    db=$2;    shift 2 ;;
        --out)          out=$2;   shift 2 ;;
        *) echo "preflight_reference.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
[[ -n "$fasta" ]] || { echo "preflight_reference.sh: --fasta is required" >&2; exit 2; }
[[ -r "$fasta" ]] || { echo "preflight_reference.sh: cannot read FASTA '$fasta'" >&2; exit 2; }
[[ -z "$gff3" || -r "$gff3" ]] || { echo "preflight_reference.sh: cannot read GFF3 '$gff3'" >&2; exit 2; }
[[ -z "$cache" || -d "$cache" ]] || { echo "preflight_reference.sh: snpEff cache '$cache' is not a directory" >&2; exit 2; }
[[ -z "$cache" || -n "$db" ]] || { echo "preflight_reference.sh: --snpeff-cache needs --snpeff-db" >&2; exit 2; }

errors=0
rows=()

# verdict STATUS CHECK DETAIL — one table row; WARN and ERROR also go to the console (ERROR to stderr too)
verdict() {
    local status=$1 check=$2 detail=$3
    rows+=("${check}"$'\t'"${status}"$'\t'"${detail}")
    case "$status" in
        WARN)  echo "[yAMP preflight] WARN  ${check}: ${detail}" ;;
        ERROR) echo "[yAMP preflight] ERROR ${check}: ${detail}"
               echo "[yAMP preflight] ERROR ${check}: ${detail}" >&2
               errors=$((errors + 1)) ;;
    esac
}

# Contig names, sorted unique (for comm). FASTA: the first token of each header line.
# GFF3: column 1 of the feature lines, stopping at an embedded ##FASTA section.
fasta_contigs() { gawk '/^>/ { sub(/^>/, ""); print $1 }' "$1" | sort -u; }
gff3_contigs()  { gawk -F '\t' '/^##FASTA/ { exit } /^#/ || /^[[:space:]]*$/ { next } { print $1 }' "$1" | sort -u; }

# list FILE — the first 10 names of a one-per-line file, comma separated, "…" when there are more
list() {
    local n s
    n=$(wc -l < "$1")
    s=$(head -n 10 "$1" | paste -sd ',' - | sed 's/,/, /g')
    (( n > 10 )) && s="${s}, …"
    printf '%s' "$s"
}

check_fasta_vs_gff3() {
    local check='FASTA vs GFF3 contig names'
    if [[ -z "$gff3" ]]; then
        verdict SKIPPED "$check" "--report_gff3 not set: the mutation report has no gene track, nothing to compare"
        return
    fi
    local fa_name gff_name n_fasta n_gff3 n_shared n_missing
    fa_name=$(basename "$fasta"); gff_name=$(basename "$gff3")
    fasta_contigs "$fasta" > fasta.contigs
    gff3_contigs  "$gff3"  > gff3.contigs
    comm -13 fasta.contigs gff3.contigs > gff3_only.contigs
    n_fasta=$(wc -l < fasta.contigs); n_gff3=$(wc -l < gff3.contigs)
    n_shared=$(comm -12 fasta.contigs gff3.contigs | wc -l); n_missing=$(wc -l < gff3_only.contigs)

    if (( n_gff3 == 0 )); then
        verdict ERROR "$check" "no feature line in ${gff_name} (comments only, or empty): the gene track of the mutation report would be empty"
    elif (( n_shared == 0 )); then
        verdict ERROR "$check" "none of the ${n_gff3} contig name(s) in ${gff_name} ($(list gff3.contigs)) is a contig of ${fa_name} ($(list fasta.contigs)): the gene track of the mutation report would be empty. Rename the contigs of one file to the other's convention (docs/usage/prepare_reference.md)"
    elif (( n_missing > 0 )); then
        verdict OK "$check" "${n_shared} of ${n_fasta} FASTA contig(s) annotated; ${n_missing} of ${n_gff3} contig name(s) in ${gff_name} have no sequence in ${fa_name} ($(list gff3_only.contigs)) — their features are not shown, as expected for a chromosome-subset reference"
    else
        verdict OK "$check" "all ${n_gff3} contig name(s) of ${gff_name} are contigs of ${fa_name} (${n_fasta} contigs)"
    fi
}

# The name snpEff 5.1 stores for a chromosome and looks a VCF's CHROM up by (ChromosomeSimpleName,
# measured 2026-11-02; the Python twin is snpeff_simple_name() in bin/genbank_to_reference.py — keep
# the two identical): leading zeros, then a leading chromosome / chromo / chr (any case) and an
# underscore after it, repeated; a name that would become empty is kept.
# Prints "<simplified>\t<name>" per FASTA header, sorted unique by the simplified name.
fasta_contigs_simplified() {
    gawk '
        function simple(name,    n, before, t, low, i, p) {
            n = name
            while (1) {
                before = n
                t = n; sub(/^0+/, "", t); if (t != "") n = t
                low = tolower(n)
                for (i = 1; i <= 3; i++) {
                    p = P[i]
                    if (index(low, p) == 1 && length(n) > length(p)) { n = substr(n, length(p) + 1); break }
                }
                t = n; sub(/^_+/, "", t); if (t != "") n = t
                if (n == before) break
            }
            return (n == "" ? name : n)
        }
        BEGIN { P[1] = "chromosome"; P[2] = "chromo"; P[3] = "chr" }
        /^>/ { sub(/^>/, ""); print simple($1) "\t" $1 }' "$1" | sort -u -k1,1
}

check_fasta_vs_cache() {
    local check='snpEff cache vs FASTA contig names'
    if [[ -z "$cache" ]]; then
        verdict SKIPPED "$check" "no pre-built snpEff cache to compare: snpEff is not in --tools, or the database is built from --genbank (its build gates compare the names)"
        return
    fi
    local fa_name cache_name bin
    fa_name=$(basename "$fasta"); cache_name=$(basename "$cache"); bin="$cache/$db/snpEffectPredictor.bin"
    if [[ ! -d "$cache/$db" ]]; then
        local have
        have=$(cd "$cache" && ls -d -- */ 2>/dev/null | sed 's#/$##' | paste -sd ',' - | sed 's/,/, /g')
        verdict ERROR "$check" "no directory ${db}/ in the snpEff cache ${cache_name} (--snpeff_db must name a database directory of --snpeff_cache; found: ${have:-none}). snpEff would try to download '${db}' and fail at the annotation step"
        return
    fi
    if [[ ! -s "$bin" ]]; then
        verdict ERROR "$check" "no snpEffectPredictor.bin in ${cache_name}/${db}/: not a built snpEff database (docs/usage/prepare_reference.md)"
        return
    fi
    # gate the gzip read: a non-5.1 database may serialise differently
    gzip -cd "$bin" 2>/dev/null | gawk -F '\t' '$1 == "CHROMOSOME" && $6 != "" { print $6 }' | sort -u > cache.contigs || true
    local n_cache
    n_cache=$(wc -l < cache.contigs)
    if (( n_cache == 0 )); then
        verdict ERROR "$check" "no CHROMOSOME entry could be read from ${cache_name}/${db}/snpEffectPredictor.bin: not a snpEff 5.1 database? The pipeline's snpEff is 5.1 and reads only its own caches (docs/usage/prepare_reference.md)"
        return
    fi
    fasta_contigs_simplified "$fasta" > fasta.simple          # "<simplified>\t<name>"
    cut -f1 fasta.simple | sort -u > fasta.simple.names
    # FASTA names (original spelling) whose simplified form the database lacks, and the database's extras
    gawk -F '\t' 'NR == FNR { have[$1] = 1; next } !($1 in have) { print $2 }' cache.contigs fasta.simple > fasta_only.contigs
    comm -13 fasta.simple.names cache.contigs > cache_only.contigs
    local n_fasta n_missing n_extra n_shared
    n_fasta=$(wc -l < fasta.simple); n_missing=$(wc -l < fasta_only.contigs); n_extra=$(wc -l < cache_only.contigs)
    n_shared=$(( n_fasta - n_missing ))
    if (( n_shared == 0 )); then
        verdict ERROR "$check" "none of the ${n_fasta} contig name(s) of ${fa_name} ($(list fasta_only.contigs)) is a chromosome of snpEff database ${db} ($(list cache.contigs)): every variant would be ERROR_CHROMOSOME_NOT_FOUND and the annotation empty, with no other error. Rebuild the database from this FASTA, or give the GenBank with --genbank (docs/usage/prepare_reference.md)"
    elif (( n_missing > 0 )); then
        verdict WARN "$check" "${n_missing} of ${n_fasta} contig name(s) of ${fa_name} are not in snpEff database ${db} ($(list fasta_only.contigs)): variants on them get no annotation (ERROR_CHROMOSOME_NOT_FOUND in the snpEff log, nothing else). ${n_shared} shared; rebuild the database from this FASTA if those contigs matter (docs/usage/prepare_reference.md)"
    elif (( n_extra > 0 )); then
        verdict OK "$check" "all ${n_fasta} contig name(s) of ${fa_name} are chromosomes of snpEff database ${db}; the database has ${n_extra} more ($(list cache_only.contigs)), as expected for a chromosome-subset reference"
    else
        verdict OK "$check" "all ${n_fasta} contig name(s) of ${fa_name} are the chromosomes of snpEff database ${db} (${n_cache})"
    fi
}

check_fasta_vs_gff3
check_fasta_vs_cache

# The header is the one preflightTable() writes for the DAG-build checks
# (subworkflows/local/utils_nfcore_sarek_pipeline/main.nf): same custom-content id, so MultiQC renders
# the two files as ONE "yAMP input checks" table. Keep the two identical.
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
    echo "[yAMP preflight] ${errors} reference check(s) failed — stopping the run (table: ${out})" >&2
    exit 65
fi
