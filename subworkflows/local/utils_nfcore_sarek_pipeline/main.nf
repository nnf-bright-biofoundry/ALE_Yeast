//
// Subworkflow with functionality specific to the nf-core/sarek pipeline
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { SAMPLESHEET_TO_CHANNEL    } from '../samplesheet_to_channel'
include { UTILS_NEXTFLOW_PIPELINE   } from '../../nf-core/utils_nextflow_pipeline'
include { UTILS_NFCORE_PIPELINE     } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NFSCHEMA_PLUGIN     } from '../../nf-core/utils_nfschema_plugin'
include { completionEmail           } from '../../nf-core/utils_nfcore_pipeline'
include { completionSummary         } from '../../nf-core/utils_nfcore_pipeline'
include { dashedLine                } from '../../nf-core/utils_nfcore_pipeline'
include { getWorkflowVersion        } from '../../nf-core/utils_nfcore_pipeline'
include { imNotification            } from '../../nf-core/utils_nfcore_pipeline'
include { logColours                } from '../../nf-core/utils_nfcore_pipeline'
include { paramsSummaryMap          } from 'plugin/nf-schema'
include { samplesheetToList         } from 'plugin/nf-schema'
include { workflowCitation          } from '../../nf-core/utils_nfcore_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW TO INITIALISE PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_INITIALISATION {

    take:
    version           // boolean: Display version and exit
    validate_params   // boolean: Boolean whether to validate parameters against the schema at runtime
    monochrome_logs   // boolean: Do not use coloured log outputs
    nextflow_cli_args //   array: List of positional nextflow CLI args
    outdir            //  string: The output directory where the results will be saved
    input             //  string: Path to input samplesheet

    main:

    versions = Channel.empty()

    //
    // Print version and exit if required and dump pipeline parameters to JSON file
    //
    UTILS_NEXTFLOW_PIPELINE (
        version,
        true,
        outdir,
        workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1
    )

    //
    // Validate parameters and generate parameter summary to stdout
    //
    UTILS_NFSCHEMA_PLUGIN (
        workflow,
        validate_params,
        null
    )

    //
    // Check config provided to the pipeline
    //
    UTILS_NFCORE_PIPELINE(nextflow_cli_args)

    //
    // Custom validation for pipeline parameters (the ALE checks' verdict rows are kept for the report)
    //
    def preflight_rows = validateInputParameters()

    // Check input path parameters to see if they exist
    def checkPathParamList = [
        params.ascat_alleles,
        params.ascat_loci,
        params.ascat_loci_gc,
        params.ascat_loci_rt,
        params.bwa,
        params.bwamem2,
        params.bcftools_annotations,
        params.bcftools_annotations_tbi,
        params.bcftools_header_lines,
        params.cf_chrom_len,
        params.chr_dir,
        params.cnvkit_reference,
        params.dbnsfp,
        params.dbnsfp_tbi,
        params.dbsnp,
        params.dbsnp_tbi,
        params.dict,
        params.dragmap,
        params.fasta,
        params.fasta_fai,
        params.genbank,
        params.germline_resource,
        params.germline_resource_tbi,
        params.input,
        params.intervals,
        params.known_indels,
        params.known_indels_tbi,
        params.known_snps,
        params.known_snps_tbi,
        params.mappability,
        params.multiqc_config,
        params.ngscheckmate_bed,
        params.pon,
        params.pon_tbi,
        params.sentieon_dnascope_model,
        params.spliceai_indel,
        params.spliceai_indel_tbi,
        params.spliceai_snv,
        params.spliceai_snv_tbi
    ]

// only check if we are using the tools
if (params.tools && (params.tools.split(',').contains('snpeff') || params.tools.split(',').contains('merge'))) checkPathParamList.add(params.snpeff_cache)
if (params.tools && (params.tools.split(',').contains('vep')    || params.tools.split(',').contains('merge'))) checkPathParamList.add(params.vep_cache)

    // def retrieveInput(need_input, step, outdir) {

    params.input_restart = retrieveInput((!params.build_only_index && !params.input), params.step, params.outdir)

    // The rows are materialised as a list first so the ALE samplesheet checks run at DAG build,
    // before any task is submitted (validateAleSamplesheet below); the channel is built from the
    // same list.
    def samplesheet_rows = params.build_only_index ? [] :
        samplesheetToList(params.input ?: params.input_restart, "$projectDir/assets/schema_input.json")
    preflight_rows += validateAleSamplesheet(samplesheet_rows)
    ch_from_samplesheet = Channel.fromList(samplesheet_rows)

    // The DAG-build checks' verdicts as the "yAMP input checks" MultiQC table (preflightTable), also
    // kept in reports/preflight/. MultiQC is its only consumer: no task hash depends on it.
    preflight_mqc = Channel.of(preflightTable(preflight_rows))
        .collectFile(name: 'preflight_samplesheet_params_mqc.tsv', storeDir: "${outdir}/reports/preflight")

    // Convert experiment to patient if experiment column is used
    ch_from_samplesheet_processed = ch_from_samplesheet.map { meta, fastq_1, fastq_2, spring_1, spring_2, table, cram, crai, bam, bai, vcf, variantcaller ->
        if (meta.experiment && !meta.patient) {
            meta.patient = meta.experiment
            meta.remove('experiment')
        }
        return [meta, fastq_1, fastq_2, spring_1, spring_2, table, cram, crai, bam, bai, vcf, variantcaller]
    }

    SAMPLESHEET_TO_CHANNEL(
        ch_from_samplesheet_processed,
        params.aligner,
        params.ascat_alleles,
        params.ascat_loci,
        params.ascat_loci_gc,
        params.ascat_loci_rt,
        params.bcftools_annotations,
        params.bcftools_annotations_tbi,
        params.bcftools_header_lines,
        params.build_only_index,
        params.download_cache,
        params.dbsnp,
        params.fasta ?: params.genbank,     // read-group DS only (BAM input; FASTQ input: addReadgroupToMeta in workflows/sarek/main.nf); the GenBank route has no --fasta
        params.germline_resource,
        params.intervals,
        params.joint_germline,
        params.joint_mutect2,
        params.known_indels,
        params.known_snps,
        params.no_intervals,
        params.pon,
        params.sentieon_dnascope_emit_mode,
        params.sentieon_haplotyper_emit_mode,
        params.seq_center,
        params.seq_platform,
        params.skip_tools,
        params.snpeff_cache ?: params.genbank,  // its "snpeff without a cache" guard: on the GenBank route the database is built from the file
        params.snpeff_db ?: genbankDbName(params.genbank),
        params.step,
        params.tools,
        params.umi_read_structure,
        params.wes)

    emit:
    samplesheet = SAMPLESHEET_TO_CHANNEL.out.input_sample
    preflight_mqc // channel: [ preflight_samplesheet_params_mqc.tsv ]
    versions
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW FOR PIPELINE COMPLETION
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_COMPLETION {

    take:
    email           //  string: email address
    email_on_fail   //  string: email address sent on pipeline failure
    plaintext_email // boolean: Send plain-text email instead of HTML
    outdir          //    path: Path to output directory where results will be published
    monochrome_logs // boolean: Disable ANSI colour codes in log output
    hook_url        //  string: hook URL for notifications
    multiqc_report  //  string: Path to MultiQC report
    qc_only         // boolean: QC-first run — print where the report is and the follow-up -resume command
    multiqc_title   //  string: user MultiQC title prefix, if any (it names the read-QC report file)

    main:
    summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")

    def multiqc_report_list = multiqc_report.toList()

    //
    // Completion email and summary
    //
    workflow.onComplete {
        if (email || email_on_fail) {
            completionEmail(
                summary_params,
                email,
                email_on_fail,
                plaintext_email,
                outdir,
                monochrome_logs,
                multiqc_report_list.getVal()
            )
        }

        completionSummary(monochrome_logs)
        if (hook_url) {
            imNotification(summary_params, hook_url)
        }
        // neither `params` nor `workflow` resolves inside this handler (NPE at completion) — the
        // flags are inputs, and the function reads `workflow` through the script binding
        qcOnlyCompletion(qc_only, outdir, multiqc_title)
    }

    workflow.onError {
        log.error "Pipeline failed. Please refer to troubleshooting docs: https://nf-co.re/docs/usage/troubleshooting"
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
//
// Check and validate pipeline parameters. Returns the ALE checks' verdict rows for the
// "yAMP input checks" MultiQC table (preflightTable below).
//
def validateInputParameters() {
    genomeExistsError()
    return validateAleRecipe() + validateQcOnly() + validateReferenceRoute()
}

//
// Reference route (docs/dev-practices/genbank_reference_input.md §6): ONE GenBank (--genbank; the
// FASTA, the snpEff database and the report's gene track are built from it before alignment), or
// upstream's pre-built files (--fasta, --snpeff_cache, --snpeff_db, --report_gff3). Both at once is an
// error naming both, never a silent preference (decision 11); neither is an error too — upstream
// starts with an empty fasta channel and every reference task silently never runs.
//
def validateReferenceRoute() {
    if (params.genbank) {
        def also = [ fasta: params.fasta, snpeff_cache: params.snpeff_cache, report_gff3: params.report_gff3,
                     download_cache: params.download_cache ]
                   .findAll { _k, v -> v }.keySet().collect { "--${it}" }
        if (also) {
            error("[yAMP preflight] --genbank together with ${also.join(', ')}: the GenBank route builds the FASTA, the snpEff database and the report's gene track from the one file, so the pre-built reference parameters cannot be given with it. Pass one route only (docs/usage/prepare_reference.md).")
        }
    } else if (!params.fasta && params.step != 'annotate') {
        error("[yAMP preflight] no reference genome: pass --genbank <genome.gb|.gbk|.gbff[.gz]> (the FASTA, snpEff database and gene track are built from it), or the pre-built files --fasta, --snpeff_cache with --snpeff_db, --report_gff3 (docs/usage/prepare_reference.md).")
    }
    return []
}

//
// The snpEff database name of the GenBank route (decision 10): the file's basename without its GenBank
// extension (.gb, .gbk, .gbff, .genbank, optionally .gz). --snpeff_db overrides it. It names the cache
// directory, reference/<db>/ and the reports/snpeff/ paths; nothing in a VCF. Null without --genbank.
//
def genbankDbName(genbank) {
    if (!genbank) return null
    return genbank.toString().replaceAll(/.*\//, '').replaceFirst(/\.(gb|gbk|gbff|genbank)(\.gz)?$/, '')
}

//
// QC-first run (--qc_only): the combinations that would make the follow-up run impossible or the
// QC run pointless are errors at DAG build; the gate itself is in workflows/sarek/main.nf.
//
def validateQcOnly() {
    if (!params.qc_only) return []
    if (params.step != 'mapping') {
        error("[yAMP preflight] --qc_only requires --step mapping (read QC is the first stage of the mapping step; a run starting from '${params.step}' has no reads to QC)")
    }
    if (params.skip_tools && params.skip_tools.split(',').contains('multiqc')) {
        error("[yAMP preflight] --qc_only with multiqc in --skip_tools would produce no QC report to sign off — drop multiqc from --skip_tools")
    }
    if (workflow.session.config.cleanup) {
        error("[yAMP preflight] --qc_only with cleanup = true: Nextflow would delete the work directory when the QC run completes, so the follow-up run could not -resume it — set cleanup = false")
    }
    def no_fastqc = params.skip_tools && params.skip_tools.split(',').contains('fastqc')
    if (no_fastqc) {
        log.warn "[yAMP preflight] --qc_only with fastqc in --skip_tools: only fastp's report will be produced"
    }
    return [[
        'Parameters: --qc_only',
        no_fastqc ? 'WARN' : 'OK',
        no_fastqc ? "fastqc in --skip_tools: only fastp's report is produced"
                  : 'QC-only run: step mapping, MultiQC on, cleanup off — stops after read QC',
    ]]
}

//
// What a finished QC-only run prints: where the report is and the exact follow-up command.
// The report is the read-QC one (MULTIQC_READ_QC; its title is set in conf/modules/modules.config —
// keep the two in sync). Its name follows MultiQC's --title rule, measured on 1.25.1 and 1.35
// (write_results.py: whitespace/hyphen runs → '-', every other non-word character dropped). The command is the launch command with
// --qc_only (any spelling: bare, `--qc_only true`, `--qc_only=true`) and any -resume (bare or with
// a session id/name — never the option that follows a bare one) removed, plus -resume <this
// session>; when --qc_only did not come from the command line (params file / config — which is
// how Seqera Platform passes every parameter) the user is told to unset it there instead.
//
def qcOnlyCompletion(qc_only, outdir, multiqc_title) {
    if (!qc_only || !workflow.success) return
    def title  = "${multiqc_title ?: 'yAMP'} read-QC"
    def slug   = title.replaceAll(/[-\s]+/, '-').replaceAll(/[^\w.\-]/, '').trim()
    def report = "${outdir}/multiqc/${slug}_multiqc_report.html"
    def cmd    = workflow.commandLine
    def on_cli = cmd =~ /(^|\s)--qc_only((=|\s+)(true|false))?(?=\s|$)/
    cmd = cmd.replaceAll(/\s--qc_only((=|\s+)(true|false))?(?=\s|$)/, '')
             .replaceAll(/\s-resume(\s+(?!-)\S+)?(?=\s|$)/, '')
    def lines = [
        "",
        "[yAMP qc_only] QC-only run finished — nothing past read QC was run.",
        "[yAMP qc_only]   MultiQC report : ${report}",
        "[yAMP qc_only]   FastQC / fastp : ${outdir}/reports/  (input checks: the report's 'yAMP input checks' table)",
        "[yAMP qc_only]   To continue, run the same command without --qc_only and with -resume ${workflow.sessionId}",
        "[yAMP qc_only]   (same work directory and --outdir; every read-QC task is a cache hit):",
        "[yAMP qc_only]     ${cmd} -resume ${workflow.sessionId}",
    ]
    if (!on_cli) lines << "[yAMP qc_only]   qc_only was set in a params file or config — set it to false there before re-launching."
    lines << "[yAMP qc_only]   On Seqera Platform: open this run → Resume → set qc_only to false."
    log.info lines.join('\n')
}

//
// ALE preflight (1/2): warn when the parameter set drifts from the validated Tier-1 recipe.
//
// The recipe is what conf/test/ottilie_common.config sets plus the read-preprocessing defaults of
// nextflow.config — the configuration the ottilie contract test and the Azure baseline validate.
// It is a second copy of those values on purpose: the ottilie profile must produce ZERO of these
// warnings (tests/preflight.nf.test), which is what keeps the two in sync. Warnings only — any
// other configuration is allowed, it just is not the validated one. Every line carries the
// `[yAMP preflight]` prefix so it can be grepped out of .nextflow.log.
//
def validateAleRecipe() {
    def recipe = [
        // calling recipe (conf/test/ottilie_common.config)
        tools                          : 'snpeff,cnvkit,tiddit,manta,haplotypecaller',
        joint_germline                 : true,
        split_haplotypecaller_joint_vcf: true,
        joint_manta                    : true,
        manta_high_sensitivity         : false,
        // read preprocessing (nextflow.config defaults; docs/usage/read_preprocessing.md)
        trim_adapter                   : true,
        trim_quality_3prime            : 'tail',
        trim_quality_5prime            : false,
        trim_quality_window            : 4,
        trim_quality_mean              : 20,
        length_required                : 15,
        filter_quality                 : true,
        clip_r1                        : 0,
        clip_r2                        : 0,
        three_prime_clip_r1            : 0,
        three_prime_clip_r2            : 0,
    ]
    def drift = []
    recipe.each { key, expected ->
        def actual = params[key]
        if (key == 'tools') {
            def want = expected.split(',') as Set
            def have = (actual ?: '').toString().split(',').findAll { it } as Set
            def missing = want - have
            def extra   = have - want
            if (missing) drift << "tools is missing Tier-1 caller(s) ${missing.sort().join(',')}"
            if (extra)   drift << "tools includes non-Tier-1 tool(s) ${extra.sort().join(',')}"
        } else if (key == 'trim_adapter') {
            if (!(params.trim_adapter || params.trim_fastq)) drift << "trim_adapter = false (Tier-1: true)"
        } else if (actual != expected) {
            drift << "${key} = ${actual} (Tier-1: ${expected})"
        }
    }
    drift.each { log.warn "[yAMP preflight] recipe drift: ${it}" }
    if (drift) log.warn "[yAMP preflight] ${drift.size()} deviation(s) from the validated Tier-1 recipe — the run proceeds, but its outputs are not covered by the ottilie contract test or the Azure baseline (docs/usage/preflight_checks.md)"
    return [[
        'Parameters: Tier-1 recipe',
        drift ? 'WARN' : 'OK',
        drift ? "${drift.size()} deviation(s): ${drift.join('; ')} — outputs not covered by the ottilie contract test or the Azure baseline"
              : "all ${recipe.size()} recipe settings match (callers, joint calling, read preprocessing)",
    ]]
}

//
// ALE preflight (2/2): samplesheet facts that upstream does not check.
//
// Runs on the parsed rows at DAG build. Errors are for sheets that would run to completion and
// produce wrong output silently; warnings for inconsistencies that are legal but unusual.
//
def validateAleSamplesheet(rows) {
    if (!rows) return []
    def metas = rows.collect { it[0] }

    // ERROR: no experiment id. assets/schema_input.json maps both `experiment` and `patient` to
    // meta.patient; with a `patient` header nf-schema overwrites the value with [] (declaration
    // order), so the run would proceed with read group SM:[]_<sample> and every experiment merged
    // into one joint-calling cohort. Pipeline-written csv/*.csv restart sheets carry a `patient`
    // header and hit this too — restart with -resume from the original samplesheet instead.
    def no_experiment = metas.findAll { !(it.patient instanceof CharSequence) || !it.patient }.collect { it.sample }.unique()
    if (no_experiment) {
        error("[yAMP preflight] no experiment id for sample(s) ${no_experiment.join(', ')}: the samplesheet header must use an `experiment` column (a `patient` header, including the pipeline-written csv/*.csv restart sheets, is parsed as empty). Re-run from the original samplesheet — a finished run resumes with -resume.")
    }

    // ERROR: the same input file in more than one row (a copy-paste error that aligns one library
    // twice under two names and doubles its evidence in every cohort table).
    def paths = rows.collectMany { row -> row[1..10].findAll { it }.collect { it.toString() } }
    def duplicated = paths.countBy { it }.findAll { _p, n -> n > 1 }.keySet().sort()
    if (duplicated) {
        error("[yAMP preflight] input file(s) listed in more than one samplesheet row: ${duplicated.join(', ')}")
    }

    // WARN: ploidy or clonal_or_population differing within an experiment. Legal, but joint calling
    // genotypes every sample of an experiment together, and the clonal/population AF thresholds are
    // per sample — a mixed experiment is usually a typo.
    def mixed = []
    metas.groupBy { it.patient }.each { experiment, ms ->
        ['ploidy', 'clonal_or_population'].each { key ->
            def values = ms.collect { it[key] }.unique()
            if (values.size() > 1) {
                log.warn "[yAMP preflight] experiment ${experiment} mixes ${key} values ${values.join(' / ')} — check the samplesheet (a mixed experiment is usually a typo)"
                mixed << "experiment ${experiment} mixes ${key} ${values.join(' / ')}"
            }
        }
    }

    // The verdict rows for the "yAMP input checks" table; a failed ERROR check never gets here
    def experiments = metas.collect { it.patient }.unique()
    def samples     = metas.collect { it.sample }.unique()
    def seen        = { key -> metas.collect { it[key] }.unique().join(' / ') }
    return [
        ['Samplesheet: experiment ids', 'OK',
            "${samples.size()} sample(s) in ${experiments.size()} experiment(s): ${firstTen(experiments)}"],
        ['Samplesheet: input files listed once', 'OK',
            "${paths.size()} file(s) in ${rows.size()} row(s), none listed twice"],
        ['Samplesheet: ploidy and clonal flag per experiment', mixed ? 'WARN' : 'OK',
            mixed ? "${mixed.join('; ')} — a mixed experiment is usually a typo"
                  : "consistent within every experiment (ploidy ${seen('ploidy')}; ${seen('clonal_or_population')})"],
    ]
}

// The first ten items, comma separated, "…" when there are more (same rule as bin/preflight_reference.sh)
def firstTen(items) {
    items.take(10).join(', ') + (items.size() > 10 ? ', …' : '')
}

//
// The "yAMP input checks" MultiQC table: one row per DAG-build check above, OK rows included, so
// the report shows what was checked and not only what was flagged. The header is the one
// bin/preflight_reference.sh writes for the task-level reference check — same custom-content id,
// so MultiQC renders both files as ONE table (rows sorted by check name; measured on 1.35). Keep
// the two headers identical. An ERROR never appears: it stops the run before any report exists.
//
def preflightTable(rows) {
    def header = [
        "# id: 'yamp_input_checks'",
        "# section_name: 'yAMP input checks'",
        '# description: "What the pipeline checked before aligning any read (docs/usage/preflight_checks.md): the samplesheet and the parameters when the run starts, the reference files in its first task. A failed check stops the run before any report is written, so this table lists what passed (OK) and what was flagged (WARN); WARN lines are also printed on the console with the [yAMP preflight] prefix."',
        "# plot_type: 'table'",
        "# pconfig:",
        "#     id: 'yamp_input_checks_table'",
        "#     namespace: 'yAMP input checks'",
        "#     sort_rows: false",
        "# headers:",
        "#     status:",
        "#         title: 'Status'",
        "#         description: 'OK, WARN or SKIPPED (an ERROR stops the run)'",
        "#     detail:",
        "#         title: 'Detail'",
        "#         description: 'What was checked and what was found'",
        "Check\tstatus\tdetail",
    ]
    return (header + rows.collect { it.join('\t') }).join('\n') + '\n'
}

//
// The Workflow Summary section lists every parameter the run set — provenance, and long to scroll
// past. Its body goes inside <details>, collapsed until clicked: MultiQC has no per-section collapse
// option, and passes the tag through an html section unescaped (measured on 1.35). Takes the YAML
// that nf-core's paramsSummaryMultiqc() builds, so the vendored function stays untouched.
//
def collapsedSummaryMultiqc(summary_yaml) {
    def n = summary_yaml.count('<dt>')
    return summary_yaml.replaceFirst(/(?m)^data: \|\n/,
        "data: |\n    <details><summary>Show the ${n} parameter(s) this run was started with</summary>\n") +
        "    </details>\n"
}

//
// Validate channels from input samplesheet
//
def validateInputSamplesheet(input) {
    def (metas, fastqs) = input[1..2]

    // Check that multiple runs of the same sample are of the same datatype i.e. single-end / paired-end
    def endedness_ok = metas.collect{ meta -> meta.single_end }.unique().size == 1
    if (!endedness_ok) {
        error("Please check input samplesheet -> Multiple runs of a sample must be of the same datatype i.e. single-end or paired-end: ${metas[0].id}")
    }

    return [ metas[0], fastqs ]
}

//
// Exit pipeline if incorrect --genome key provided
//
def genomeExistsError() {
    if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
        def error_string = "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n" +
            "  Genome '${params.genome}' not found in any config files provided to the pipeline.\n" +
            "  Currently, the available genome keys are:\n" +
            "  ${params.genomes.keySet().join(", ")}\n" +
            "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        error(error_string)
    }
}
//
// Generate methods description for MultiQC
//
def toolCitationText() {
    // TODO nf-core: Optionally add in-text citation tools to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "Tool (Foo et al. 2023)" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def citation_text = [
            "Tools used in the workflow included:",
            "FastQC (Andrews 2010),",
            "MultiQC (Ewels et al. 2016)",
            "."
        ].join(' ').trim()

    return citation_text
}

def toolBibliographyText() {
    // TODO nf-core: Optionally add bibliographic entries to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "<li>Author (2023) Pub name, Journal, DOI</li>" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def reference_text = [
            "<li>Andrews S, (2010) FastQC, URL: https://www.bioinformatics.babraham.ac.uk/projects/fastqc/).</li>",
            "<li>Ewels, P., Magnusson, M., Lundin, S., & Käller, M. (2016). MultiQC: summarize analysis results for multiple tools and samples in a single report. Bioinformatics , 32(19), 3047–3048. doi: /10.1093/bioinformatics/btw354</li>"
        ].join(' ').trim()

    return reference_text
}

def methodsDescriptionText(mqc_methods_yaml) {
    // Convert  to a named map so can be used as with familar NXF ${workflow} variable syntax in the MultiQC YML file
    def meta = [:]
    meta.workflow = workflow.toMap()
    meta["manifest_map"] = workflow.manifest.toMap()

    // Pipeline DOI
    if (meta.manifest_map.doi) {
        // Using a loop to handle multiple DOIs
        // Removing `https://doi.org/` to handle pipelines using DOIs vs DOI resolvers
        // Removing ` ` since the manifest.doi is a string and not a proper list
        def temp_doi_ref = ""
        def manifest_doi = meta.manifest_map.doi.tokenize(",")
        manifest_doi.each { doi_ref ->
            temp_doi_ref += "(doi: <a href=\'https://doi.org/${doi_ref.replace("https://doi.org/", "").replace(" ", "")}\'>${doi_ref.replace("https://doi.org/", "").replace(" ", "")}</a>), "
        }
        meta["doi_text"] = temp_doi_ref.substring(0, temp_doi_ref.length() - 2)
    } else meta["doi_text"] = ""
    meta["nodoi_text"] = meta.manifest_map.doi ? "" : "<li>If available, make sure to update the text to include the Zenodo DOI of the pipeline version used. </li>"

    // Tool references
    meta["tool_citations"] = ""
    meta["tool_bibliography"] = ""

    // TODO nf-core: Only uncomment below if logic in toolCitationText/toolBibliographyText has been filled!
    // meta["tool_citations"] = toolCitationText().replaceAll(", \\.", ".").replaceAll("\\. \\.", ".").replaceAll(", \\.", ".")
    // meta["tool_bibliography"] = toolBibliographyText()


    def methods_text = mqc_methods_yaml.text

    def engine =  new groovy.text.SimpleTemplateEngine()
    def description_html = engine.createTemplate(methods_text).make(meta)

    return description_html.toString()
}

//
// nf-core/sarek logo
//
def nfCoreLogo(monochrome_logs=true) {
    Map colors = logColours(monochrome_logs)
    String.format(
        """\n
        ${dashedLine(monochrome_logs)}
                                                ${colors.green},--.${colors.black}/${colors.green},-.${colors.reset}
        ${colors.blue}        ___     __   __   __   ___     ${colors.green}/,-._.--~\'${colors.reset}
        ${colors.blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${colors.yellow}}  {${colors.reset}
        ${colors.blue}  | \\| |       \\__, \\__/ |  \\ |___     ${colors.green}\\`-._,-`-,${colors.reset}
                                                ${colors.green}`._,._,\'${colors.reset}
        ${colors.white}      ____${colors.reset}
        ${colors.white}    .´ _  `.${colors.reset}
        ${colors.white}   /  ${colors.green}|\\${colors.reset}`-_ \\${colors.reset}     ${colors.blue} __        __   ___     ${colors.reset}
        ${colors.white}  |   ${colors.green}| \\${colors.reset}  `-|${colors.reset}    ${colors.blue}|__`  /\\  |__) |__  |__/${colors.reset}
        ${colors.white}   \\ ${colors.green}|   \\${colors.reset}  /${colors.reset}     ${colors.blue}.__| /¯¯\\ |  \\ |___ |  \\${colors.reset}
        ${colors.white}    `${colors.green}|${colors.reset}____${colors.green}\\${colors.reset}´${colors.reset}

        ${colors.purple}  ${workflow.manifest.name} ${getWorkflowVersion()}${colors.reset}
        ${dashedLine(monochrome_logs)}
        """.stripIndent()
    )
}

//
// retrieveInput
//
def retrieveInput(need_input, step, outdir) {
    def input = null
    if (!params.input && !params.build_only_index) {
        switch (step) {
            case 'mapping':                 error("Can't start $step step without samplesheet")
                                            break
            case 'markduplicates':          log.warn("Using file ${outdir}/csv/mapped.csv");
                                            input = outdir + "/csv/mapped.csv"
                                            break
            case 'prepare_recalibration':   log.warn("Using file ${outdir}/csv/markduplicates_no_table.csv");
                                            input = outdir + "/csv/markduplicates_no_table.csv"
                                            break
            case 'recalibrate':             log.warn("Using file ${outdir}/csv/markduplicates.csv");
                                            input = outdir + "/csv/markduplicates.csv"
                                            break
            case 'variant_calling':         log.warn("Using file ${outdir}/csv/recalibrated.csv");
                                            input = outdir + "/csv/recalibrated.csv"
                                            break
            // case 'controlfreec':         csv_file = file("${outdir}/variant_calling/csv/control-freec_mpileup.csv", checkIfExists: true); break
            case 'annotate':                log.warn("Using file ${outdir}/csv/variantcalled.csv");
                                            input = outdir + "/csv/variantcalled.csv"
                                            break
            default:                        log.warn("Please provide an input samplesheet to the pipeline e.g. '--input samplesheet.csv'")
                                            error("Unknown step $step")
        }
    }
    return input
}
