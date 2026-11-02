// snpEff database build from a GenBank file (yAMP reference step 2 of 2), in nf-core module shape so
// it can be offered upstream as snpeff/build (nf-core ships snpeff/download and snpeff/snpeff only).
//
// Input: a directory named after the database holding genes.gbk and the per-genome snpEff.config
// (GENBANK_REFERENCE writes both; the config carries the .genome line and the codonTable lines that
// give snpEff the genetic code per contig, which it never reads from the GenBank). The build config
// is snpEff's bundled file plus that per-genome file: a codonTable line needs the bundled codon.<Table>
// definitions in the same file ("No such codon table" otherwise). The protein check compares snpEff's
// own translation of every CDS with the file's /translation, so it verifies the gene models AND the
// genetic code in one number; it is skipped when the file carries no /translation at all (snpEff then
// fails the build on "OK: 0"). Two gates, each a row of the "yAMP input checks" table (docs/dev-practices/
// genbank_reference_input.md §5.3): protein check Errors: 0; the names stored in the cache equal the
// expected list (snpEff simplifies names: chrB is stored as B, see the extract script) when one is given.
// A failed gate prints the verdict and exits 65; the pipeline config stops the run on it. genes.gbk is a
// build intermediate and is removed from the cache afterwards.
process SNPEFF_BUILD {
    tag "$meta.id"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/snpeff:5.1--hdfd78af_2' :
        'biocontainers/snpeff:5.1--hdfd78af_2' }"

    input:
    tuple val(meta), path(genome_dir)   // directory <db>/ with genes.gbk (+ .gz accepted) and snpEff.config
    path expected_contigs               // one stored contig name per line; [] skips the name gate

    output:
    tuple val(meta), path("snpeff_cache"), emit: cache     // snpeff_cache/<db>/{snpEffectPredictor.bin, sequence*.bin, snpEff.config}
    path "*.snpeff_build.log",             emit: log
    path "snpeff_build_mqc.tsv",           emit: mqc
    path "versions.yml",                   emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args   = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def db     = meta.id
    def avail_mem = 6144
    if (!task.memory) {
        log.info '[snpEff build] Available memory not known - defaulting to 6GB. Specify process memory requirements to change this.'
    } else {
        avail_mem = (task.memory.mega*0.8).intValue()
    }
    def contigs_arg = expected_contigs ? "--expected ${expected_contigs}" : ''
    """
    mkdir -p snpeff_cache
    cp -rL ${genome_dir} snpeff_cache/${db}
    # (pipefail: -quit and grep -c instead of head/grep -q, which close the pipe early and fail the task)
    bundled=\$(find / -name snpEff.config -path '*share/snpeff*' -print -quit 2>/dev/null)
    cat "\$bundled" snpeff_cache/${db}/snpEff.config > snpEff.build.config

    check=''
    reader=cat; [ -f snpeff_cache/${db}/genes.gbk.gz ] && reader='gzip -cd'   # the image's zcat has no -f
    n_translation=\$(\$reader snpeff_cache/${db}/genes.gbk* | { grep -c '/translation=' || true; })
    if [ "\$n_translation" -eq 0 ]; then check='-noCheckProtein'; fi

    snpEff -Xmx${avail_mem}M build -genbank -v -noLog -nodownload \$check $args \\
        -c snpEff.build.config -dataDir \$PWD/snpeff_cache ${db} \\
        > ${prefix}.snpeff_build.log 2>&1 || true

    snpeff_build_gates.sh \\
        --db ${db} \\
        --cache snpeff_cache \\
        --log ${prefix}.snpeff_build.log \\
        \${check:+--no-protein-check} \\
        ${contigs_arg} \\
        --out snpeff_build_mqc.tsv

    rm -f snpeff_cache/${db}/genes.gbk snpeff_cache/${db}/genes.gbk.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        snpeff: \$(echo \$(snpEff -version 2>&1) | cut -f 2 -d ' ')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    mkdir -p snpeff_cache/${meta.id}
    touch snpeff_cache/${meta.id}/snpEffectPredictor.bin snpeff_cache/${meta.id}/sequence.bin
    cp ${genome_dir}/snpEff.config snpeff_cache/${meta.id}/
    touch ${prefix}.snpeff_build.log snpeff_build_mqc.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        snpeff: \$(echo \$(snpEff -version 2>&1) | cut -f 2 -d ' ')
    END_VERSIONS
    """
}
