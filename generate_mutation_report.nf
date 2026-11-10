#!/usr/bin/env nextflow
/*
 * Standalone launcher for the MUTATION_REPORT subworkflow.
 *
 * Regenerates the mutation dashboard from an EXISTING pipeline output directory,
 * without re-running Sarek. Because there is no live run here, this launcher rebuilds
 * the channels MUTATION_REPORT expects by discovering published files under params.outdir
 * (the path-discovery logic used to live inside the subworkflow; it was moved here so the
 * subworkflow itself stays clean/channel-based for the inline, clean-run path).
 *
 * The inline one-shot path is workflows/sarek/main.nf (--generate_reports); use THIS launcher
 * only to re-run reports against an already-populated outdir.
 *
 * ⚠️ MAINTENANCE WARNING — this file encodes FILESYSTEM LAYOUT ASSUMPTIONS (publish directory
 * and filename suffixes). The inline path does not: it consumes `cram_variant_calling` and the
 * caller output channels directly, so it stays correct whatever preprocessing ran. Anything
 * here that guesses a path can rot silently when the pipeline configuration changes — a wrong
 * guess yields an EMPTY glob, i.e. missing tracks in the report, not an error. See the
 * cram_subdir/cram_suffix note below and the VCF suffix map (`sfx`). This launcher has NO
 * automated test coverage (tests/ottilie_e2e.nf.test exercises main.nf, not this file).
 *
 * Usage:
 *   nextflow run generate_mutation_report.nf \
 *       -profile azureD4as,docker \
 *       --outdir output_ottilie_test \
 *       --input data/ottilie/samplesheet_pilot.csv \
 *       --fasta data/ottilie/S288C_reference/S288C_R64.fa \
 *       --fasta_fai data/ottilie/S288C_reference/S288C_R64.fa.fai \
 *       --report_gff3 data/ottilie/S288C_reference/S288C_R64.gff3 \
 *       --tools haplotypecaller,cnvkit,manta,tiddit,snpeff \
 *       --report_outdir docs/igvreports/ottilie \
 *       -resume
 */

nextflow.enable.dsl = 2

include { MUTATION_REPORT } from './subworkflows/local/mutation_report/main'

workflow {
    // -------------------------------------------------------------------------
    // Config → path resolution (mirrors the pipeline's output layout)
    // -------------------------------------------------------------------------
    def tool_list = params.tools ? params.tools.split(',').collect { it.trim() } : []
    def skip_list = params.skip_tools ? params.skip_tools.split(',').collect { it.trim() } : []

    def has_annotation = tool_list.contains('snpeff') || tool_list.contains('vep')
    def has_cnvkit          = tool_list.contains('cnvkit')
    def has_manta           = tool_list.contains('manta')
    def has_tiddit          = tool_list.contains('tiddit')
    def has_haplotypecaller = tool_list.contains('haplotypecaller')

    def outdir   = params.outdir
    def vcf_root = has_annotation ? "${outdir}/annotation" : "${outdir}/variant_calling"

    // CRAM subdir depends on which preprocessing steps ran.
    //
    // ⚠️ ONLY the 'markduplicates' branch is exercised. Every ALE run sets
    // `skip_tools = 'baserecalibrator'` (mandatory — the custom genome has no known-sites VCFs,
    // and dropping it aborts the run), so that branch is always taken. The other two are
    // effectively dead here AND their suffixes are WRONG against what Sarek actually publishes:
    //
    //   subdir           published filename        cram_suffix below   ok?
    //   mapped           <id>.sorted.cram          .cram               NO  (BAM_TO_CRAM_MAPPING,
    //                                                                       conf/modules/markduplicates.config)
    //   markduplicates   <id>.md.cram              .md.cram            yes
    //   recalibrated     <id>.recal.cram           .cram               NO  (conf/modules/recalibrate.config)
    //
    // So enabling BQSR, or skipping markduplicates, would make the CRAM glob match nothing and
    // silently drop IGV alignment tracks from the reports. Fix the suffix map before relying on
    // either branch. The INLINE path (workflows/sarek/main.nf) is unaffected — it takes
    // `cram_variant_calling`, which Sarek already points at the right CRAMs for any
    // preprocessing configuration. Tracked in docs/dev-practices/roadmap.md.
    def cram_subdir
    if (skip_list.contains('markduplicates')) {
        cram_subdir = 'mapped'
    } else if (skip_list.contains('baserecalibrator')) {
        cram_subdir = 'markduplicates'
    } else {
        cram_subdir = 'recalibrated'
    }
    def cram_dir    = "${outdir}/preprocessing/${cram_subdir}"
    def cram_suffix = cram_subdir == 'markduplicates' ? '.md.cram' : '.cram'

    // Annotated-vs-raw filename suffixes
    def sfx = [
        hc:     has_annotation ? '.haplotypecaller.from_joint_calling_snpEff.ann.vcf.gz' : '.haplotypecaller.from_joint_calling.vcf.gz',
        cnvkit: has_annotation ? '.cnvcall_snpEff.ann.vcf.gz' : '.cnvcall.vcf',
        manta:  has_annotation ? '.manta.diploid_sv_snpEff.ann.vcf.gz' : '.manta.diploid_sv.vcf.gz',
        tiddit: has_annotation ? '.tiddit_snpEff.ann.vcf.gz' : '.tiddit.vcf.gz',
    ]

    // Sample list from the samplesheet
    ch_samples = Channel.fromPath(params.input)
        .splitCsv(header: true)
        .map { row -> row.sample }
        .unique()

    // -------------------------------------------------------------------------
    // report_vcfs — combined [meta, vcf, tbi], tagged with variantcaller (+ hc_kind for HC)
    // -------------------------------------------------------------------------
    def mk3 = { meta, path -> [ meta, file(path), file("${path}.tbi") ] }

    // HC joint (cohort)
    def joint_dir    = has_annotation ? "${vcf_root}/haplotypecaller/joint_variant_calling" : "${outdir}/variant_calling/haplotypecaller/joint_variant_calling"
    def joint_suffix = has_annotation ? '_snpEff.ann.vcf.gz' : '.vcf.gz'
    def joint_path   = "${joint_dir}/HaplotypeCaller_joint_calling_soft_filtered${joint_suffix}"
    ch_hc_joint = has_haplotypecaller
        ? Channel.of(mk3([ id: 'joint_variant_calling', variantcaller: 'haplotypecaller', hc_kind: 'joint' ], joint_path))
        : Channel.empty()

    // HC per-sample soft (split-from-joint)
    ch_hc_sample = has_haplotypecaller
        ? ch_samples.map { s -> mk3([ id: s, variantcaller: 'haplotypecaller', hc_kind: 'sample_soft' ], "${vcf_root}/haplotypecaller/${s}/${s}${sfx.hc}") }
        : Channel.empty()

    ch_cnvkit_vcf = has_cnvkit
        ? ch_samples.map { s -> mk3([ id: s, variantcaller: 'cnvkit' ], "${vcf_root}/cnvkit/${s}/${s}${sfx.cnvkit}") }
        : Channel.empty()

    ch_manta_vcf = has_manta
        ? ch_samples.map { s -> mk3([ id: s, variantcaller: 'manta' ], "${vcf_root}/manta/${s}/${s}${sfx.manta}") }
        : Channel.empty()

    ch_tiddit_vcf = has_tiddit
        ? ch_samples.map { s -> mk3([ id: s, variantcaller: 'tiddit' ], "${vcf_root}/tiddit/${s}/${s}${sfx.tiddit}") }
        : Channel.empty()

    report_vcfs = ch_hc_joint.mix(ch_hc_sample, ch_cnvkit_vcf, ch_manta_vcf, ch_tiddit_vcf)

    // -------------------------------------------------------------------------
    // CRAM, raw SV VCFs, CNVKit CN files
    // -------------------------------------------------------------------------
    cram = ch_samples.map { s ->
        [ [ id: s ], file("${cram_dir}/${s}/${s}${cram_suffix}"), file("${cram_dir}/${s}/${s}${cram_suffix}.crai") ]
    }

    vcf_tiddit_raw = has_tiddit
        ? ch_samples.map { s -> [ [ id: s, variantcaller: 'tiddit' ], file("${outdir}/variant_calling/tiddit/${s}/${s}.tiddit.vcf.gz") ] }
        : Channel.empty()

    // Manta VCF(s) for the SVDB SV merge. With --joint_manta the pipeline published ONE
    // multi-sample VCF per patient (= samplesheet `experiment`) at
    // variant_calling/manta/<patient>/<patient>.manta.diploid_sv.vcf.gz — same pattern as the
    // per-sample splits, just keyed by patient. params.joint_manta must match how the outdir
    // was produced (it comes from the same profile/config; a mismatch globs a missing file).
    ch_patients = Channel.fromPath(params.input)
        .splitCsv(header: true)
        .map { row -> row.experiment ?: row.patient }
        .unique()
    vcf_manta_sv = has_manta
        ? (params.joint_manta
            ? ch_patients.map { p -> [ [ id: p ], file("${outdir}/variant_calling/manta/${p}/${p}.manta.diploid_sv.vcf.gz") ] }
            : ch_samples.map { s -> [ [ id: s ], file("${outdir}/variant_calling/manta/${s}/${s}.manta.diploid_sv.vcf.gz") ] })
        : Channel.empty()

    // TIDDIT per-contig coverage table + the samplesheet ploidy it was run with (-n), for the
    // contig copy-number table. Ploidy comes from the samplesheet because TIDDIT does not
    // record -n in the .tab.
    ch_sample_ploidy = Channel.fromPath(params.input)
        .splitCsv(header: true)
        .map { row -> [ row.sample, row.ploidy ?: '2' ] }
        .unique()
    tiddit_ploidy = has_tiddit
        ? ch_sample_ploidy.map { s, n -> [ [ id: s, ploidy: n ], file("${outdir}/variant_calling/tiddit/${s}/${s}.tiddit.ploidies.tab") ] }
        : Channel.empty()

    cnvkit_cnr = has_cnvkit
        ? ch_samples.map { s -> [ [ id: s ], file("${outdir}/variant_calling/cnvkit/${s}/${s}.md.cnr") ] }
        : Channel.empty()

    cnvkit_cns_batch = has_cnvkit
        ? ch_samples.map { s -> [ [ id: s ], file("${outdir}/variant_calling/cnvkit/${s}/${s}.md.call.cns") ] }
        : Channel.empty()

    cnvkit_cns_germline = has_cnvkit
        ? ch_samples.map { s -> [ [ id: s ], file("${outdir}/variant_calling/cnvkit/${s}/${s}.md.germline.call.cns") ] }
        : Channel.empty()

    // -------------------------------------------------------------------------
    // MultiQC data dir + report (cloud-aware existence check)
    // -------------------------------------------------------------------------
    def mqc_data = file("${outdir}/multiqc/multiqc_data")
    multiqc_data = Channel.value(mqc_data)

    def mqc_file = file("${outdir}/multiqc/multiqc_report.html")
    multiqc_report = Channel.value(mqc_file.exists() ? mqc_file : file("NO_FILE"))

    def manifests = file("${outdir}/reference/*/contig_manifest.csv")
    def contig_manifest = manifests ? manifests[0] : []

    MUTATION_REPORT(
        report_vcfs,
        cram,
        vcf_tiddit_raw,
        vcf_manta_sv,
        tiddit_ploidy,
        cnvkit_cnr,
        cnvkit_cns_batch,
        cnvkit_cns_germline,
        multiqc_data,
        multiqc_report,
        // Standalone regenerates from an existing outdir (no PREPARE_GENOME), so --fasta_fai
        // is still required here; wrapped in a value channel to match MUTATION_REPORT's input.
        Channel.value([ file(params.fasta), file(params.fasta_fai) ]),
        file(params.report_gff3),
        // The contig manifest a --genbank run published under reference/<db>/; a pre-built-route outdir
        // has none, and then every contig (Mito included) is graded against 1, as in the run itself.
        Channel.value(contig_manifest)
    )
}
