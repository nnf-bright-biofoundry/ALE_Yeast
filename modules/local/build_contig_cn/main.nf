// Build the contig-level copy-number CSV from TIDDIT's per-contig coverage tables
// (<sample>.tiddit.ploidies.tab). Whole-contig only; the one place Mito is quantified.
// Rows follow the reference's contig order (the .fai).
process BUILD_CONTIG_CN {
    tag "contig_cn"
    label 'process_low'

    conda 'conda-forge::pandas=2.2.1'
    container 'quay.io/biocontainers/pandas:2.2.1'

    input:
    path(tabs)              // collected <sample>.tiddit.ploidies.tab
    val(ploidies)           // collected "sample=n" strings (the -n TIDDIT ran with)
    path(fai)               // reference .fai: the row order

    output:
    path("contig_copy_number.csv"), emit: csv
    path "versions.yml",            emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    """
    contig_copy_number.py \\
        --tabs *.tiddit.ploidies.tab \\
        --ploidies ${ploidies.join(' ')} \\
        --fai ${fai} \\
        --csv contig_copy_number.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | sed 's/Python //')
        contig_copy_number: "1.1"
    END_VERSIONS
    """
}
