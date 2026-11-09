// yAMP reference from one GenBank file, step 1 of 2: the extract task.
//
// One parse of the user's GenBank (bin/genbank_to_reference.py, BioPython) yields the FASTA and the
// report's GFF3 with the LOCUS names, the contig manifest, the per-genome snpEff.config (the .genome
// line plus one codonTable line per contig whose /transl_table is not 1), the copy snpEff builds from
// (VERSION rewritten to LOCUS, see the script header), the contig names snpEff will store, and the
// verdict rows of the "yAMP input checks" table. SNPEFF_BUILD (step 2) builds the cache from the copy.
// A failed check writes the table, prints the verdict and exits 65; conf/modules/genbank_reference.config
// stops the run on it. Design: docs/dev-practices/genbank_reference_input.md §5.
process GENBANK_REFERENCE {
    tag "$db"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    // Docker Hub's biocontainers mirror has no biopython:1.81 (checked 2026-11-02), hence quay for docker.
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/biopython:1.81' :
        'quay.io/biocontainers/biopython:1.81' }"

    input:
    path genbank    // .gb / .gbk / .gbff, gzipped or not; never modified
    val  db         // snpEff database name = the cache directory name

    output:
    path genbank,                      emit: genbank           // the input, untouched: the run's reference record (published with the rest)
    path "${db}.fa",                   emit: fasta
    path "${db}.gff3",                 emit: gff3
    path "contig_manifest.csv",        emit: manifest
    tuple val(meta), path("${db}"),    emit: snpeff_input      // <db>/genes.gbk + <db>/snpEff.config
    path "expected_cache_contigs.txt", emit: expected_contigs
    path "preflight_genbank_mqc.tsv",  emit: mqc
    path "versions.yml",               emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    meta = [ id: db ]
    def args = task.ext.args ?: ''
    """
    genbank_to_reference.py \\
        --genbank ${genbank} \\
        --db ${db} \\
        --source-name ${genbank.name} \\
        $args

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version | sed 's/Python //')
        biopython: \$(python -c 'import Bio; print(Bio.__version__)')
    END_VERSIONS
    """
}
