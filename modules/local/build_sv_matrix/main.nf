// Build the SV cohort matrix CSV from the SVDB cross-caller cohort VCF.
// Cells are a deterministic parse of the merged record (FORMAT GT/FT for Manta,
// propagated <sample>.tiddit*_SAMPLE keys for TIDDIT) — see bin/sv_cohort_matrix.py.
// Rows follow the reference's contig order (the .fai), then position.
process BUILD_SV_MATRIX {
    tag "sv_matrix_${meta.merge_mode}"
    label 'process_low'

    conda 'conda-forge::pandas=2.2.1'
    container 'quay.io/biocontainers/pandas:2.2.1'

    input:
    tuple val(meta), path(cohort_vcf)   // meta.merge_mode: 'union' | 'union_pass'
    val(samples)                        // sorted sample ids (matrix column order)
    path(fai)                           // reference .fai: the row order

    output:
    path("sv_cohort_matrix_${meta.merge_mode}.csv"), emit: csv
    path "versions.yml"                            , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def pass_flag = meta.merge_mode == 'union_pass' ? '--pass-view' : ''
    """
    sv_cohort_matrix.py \\
        --cohort-vcf ${cohort_vcf} \\
        --samples ${samples.join(' ')} \\
        --fai ${fai} \\
        ${pass_flag} \\
        --csv sv_cohort_matrix_${meta.merge_mode}.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | sed 's/Python //')
        sv_cohort_matrix: "3.2"
    END_VERSIONS
    """
}
