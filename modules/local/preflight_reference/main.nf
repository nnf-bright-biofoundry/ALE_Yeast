// yAMP preflight, task level: do the reference files handed to the pipeline agree with each other?
//
// A task rather than a DAG-build check, so cloud paths (az://, s3://) are staged like any other
// input and the check runs in the QC-only run as well. Its only output is a MultiQC custom-content
// table — nothing downstream depends on it, so adding it changed no other task's inputs or hashes.
// conf/modules/preflight.config terminates the run on a failed check and echoes the verdict lines.
// The checks themselves: bin/preflight_reference.sh. User page: docs/usage/preflight_checks.md.
// Inputs 3 and 4 (2026-11-09): the pre-built snpEff cache and its database name, for the cache-vs-FASTA
// contig-name row; [] on the GenBank route (SNPEFF_BUILD's gates compare the names there) and when
// snpEff is not in --tools, which makes the row SKIPPED. Staging the cache changed this task's hash
// on the pre-built route (it reruns once under -resume; seconds).
process PREFLIGHT_REFERENCE {
    tag "reference"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/gawk:5.3.0' :
        'biocontainers/gawk:5.3.0' }"

    input:
    path fasta
    path gff3          // [] when --report_gff3 is unset: the FASTA-vs-GFF3 row then reads SKIPPED
    path snpeff_cache  // the pre-built --snpeff_cache directory, or []: the cache row then reads SKIPPED
    val  snpeff_db     // the database directory inside it (--snpeff_db); any string when snpeff_cache is []

    output:
    path "preflight_reference_mqc.tsv", emit: mqc
    path "versions.yml",                emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def gff3_arg  = gff3 ? "--gff3 ${gff3}" : ''
    def cache_arg = snpeff_cache ? "--snpeff-cache ${snpeff_cache} --snpeff-db ${snpeff_db}" : ''
    """
    preflight_reference.sh --fasta ${fasta} ${gff3_arg} ${cache_arg} --out preflight_reference_mqc.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        gawk: \$(gawk --version | sed '1!d; s/^GNU Awk //; s/,.*//')
    END_VERSIONS
    """
}
