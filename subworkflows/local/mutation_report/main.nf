/*
 * MUTATION_REPORT — Generate multi-caller mutation report dashboard
 *
 * Integrates CN/SV data generation, igv-reports HTML, and index dashboard
 * into a single subworkflow that runs after the main Sarek pipeline.
 *
 * Gated behind --generate_reports in workflows/sarek/main.nf (inline, clean-run correct)
 * or launched standalone via generate_mutation_report.nf (rebuilds channels from disk).
 *
 * CHANNEL-BASED: consumes pipeline OUTPUT CHANNELS (workdir files, DAG-ordered)
 * instead of re-reading published files from params.outdir — no publishDir race.
 */

include { PREPARE_GFF3       } from '../../../modules/local/prepare_gff3/main'
include { PREPARE_VCF        } from '../../../modules/local/prepare_vcf/main'
include { IGVREPORTS_COHORT  } from '../../../modules/local/igvreports_cohort/main'
include { IGVREPORTS_SAMPLE  } from '../../../modules/local/igvreports_sample/main'
include { IGVREPORTS_SV_CNV  } from '../../../modules/local/igvreports_sv_cnv/main'
include { CNR_TO_BEDGRAPH    } from '../../../modules/local/cnr_to_bedgraph/main'
include { FILTER_PASS_VCF    } from '../../../modules/local/filter_pass_vcf/main'
include { PUBLISH_VCFS       } from '../../../modules/local/publish_vcfs/main'
include { GENERATE_INDEX     } from '../../../modules/local/generate_index/main'
include { BUILD_CN_MATRIX    } from '../../../modules/local/build_cn_matrix/main'
include { BUILD_CN_COHORT    } from '../../../modules/local/build_cn_cohort/main'
include { BUILD_CONTIG_CN    } from '../../../modules/local/build_contig_cn/main'
include { MANTA_CONVERTINVERSION } from '../../../modules/nf-core/manta/convertinversion/main'
include { COLLAPSE_SV_PAIRS      } from '../../../modules/local/collapse_sv_pairs/main'
include { CHECK_SV_SAMPLE_ORDER  } from '../../../modules/local/check_sv_sample_order/main'
include { TIDDIT_SV_FILTER       } from '../../../modules/local/tiddit_sv_filter/main'
include { BCFTOOLS_VIEW as FILTER_SV_PASS } from '../../../modules/nf-core/bcftools/view/main'
include { SVDB_MERGE as SVDB_MERGE_MANTA   } from '../../../modules/nf-core/svdb/merge/main'
include { SVDB_MERGE as SVDB_MERGE_TIDDIT  } from '../../../modules/nf-core/svdb/merge/main'
include { SVDB_MERGE as SVDB_MERGE_CALLERS } from '../../../modules/nf-core/svdb/merge/main'
include { BUILD_SV_MATRIX    } from '../../../modules/local/build_sv_matrix/main'

workflow MUTATION_REPORT {
    take:
    report_vcfs         // channel: [ meta, vcf, tbi ]  combined annotated-or-raw VCFs for IGV reports;
                        //          meta carries variantcaller + (for HC) hc_kind. Branched internally.
    cram                // channel: [ meta, cram, crai ]  per-sample alignments (meta.id = sample)
    vcf_tiddit_raw      // channel: [ meta, vcf ]  RAW per-sample tiddit (SVDB SV merge)
    vcf_manta_sv        // channel: [ meta, vcf ]  Manta VCF(s) for the SVDB SV merge: the joint
                        //          multi-sample VCF (one per patient) under --joint_manta, else the
                        //          per-sample VCFs (then merged across samples here, like TIDDIT)
    tiddit_ploidy       // channel: [ meta, .tiddit.ploidies.tab ]  per-contig coverage; meta.ploidy = the -n it ran with
    cnvkit_cnr          // channel: [ meta, .md.cnr ]  bin-level coverage (bedgraph + CN matrix)
    cnvkit_cns_batch    // channel: [ meta, [*.cns] ]   batch segments incl .md.call.cns (CN matrix)
    cnvkit_cns_germline // channel: [ meta, .md.germline.call.cns ]  CI-filtered segments (CN matrix)
    multiqc_data        // channel: MultiQC *_data dir (GENERATE_INDEX metrics)
    multiqc_report      // channel: MultiQC report file(s) — ordering edge + linked from index.html
    fasta               // channel: value [ path(fasta), path(fai) ]
    gff3                // path:     gene annotation GFF3

    main:
    versions = Channel.empty()

    // =========================================================================
    // 1. Tool availability — from params (param reads, NOT path reads: no race)
    // =========================================================================

    def tool_list = params.tools ? params.tools.split(',').collect { it.trim() } : []
    def has_cnvkit          = tool_list.contains('cnvkit')
    def has_manta           = tool_list.contains('manta')
    def has_tiddit          = tool_list.contains('tiddit')
    def has_haplotypecaller = tool_list.contains('haplotypecaller')

    if (!has_haplotypecaller) {
        log.warn "MUTATION_REPORT: haplotypecaller not in params.tools — " +
                 "cohort and per-sample SNV/INDEL reports will be skipped."
    }
    if (!has_manta && !has_tiddit) {
        log.warn "MUTATION_REPORT: neither manta nor tiddit in params.tools — " +
                 "SV reports and SV cohort matrix will be skipped."
    }
    if (!has_cnvkit) {
        log.warn "MUTATION_REPORT: cnvkit not in params.tools — " +
                 "CN matrix, coverage reports, and aneuploidy section will be skipped."
    }

    // =========================================================================
    // 2. GFF3 preparation + static report assets (pipeline assets, not outputs)
    // =========================================================================

    // The gene track is OPTIONAL. With --report_gff3 unset, skip the sort/bgzip/tabix step
    // and feed the downstream `tuple path(gff3_gz), path(gff3_tbi)` a pair of empty lists —
    // the Nextflow idiom for an absent optional path. Both render falsy in the module script
    // blocks, which then drop the track from --tracks.
    //
    // `[]` declares no file at all, so nothing has to stage (or exist) on a remote work dir —
    // the same idiom used for the absent coverage tracks below.
    if (params.report_gff3 || params.genbank) {   // the --genbank route derives the GFF3 (GENBANK_REFERENCE)
        PREPARE_GFF3(gff3)
        ch_gff3_indexed = PREPARE_GFF3.out.gff3
        versions = versions.mix(PREPARE_GFF3.out.versions)
    } else {
        log.warn "MUTATION_REPORT: --report_gff3 not set — reports will be generated " +
                 "WITHOUT the gene annotation track."
        ch_gff3_indexed = Channel.value([ [], [] ])
    }

    ch_fasta = fasta                        // value channel: [ path(fasta), path(fai) ]
    ch_fai   = fasta.map { it[1] }           // value channel: path(fai)

    ch_filter_config   = Channel.value(file(params.report_filter_config))
    ch_template        = Channel.value(file(params.report_cohort_template))
    ch_sample_template = Channel.value(file(params.report_sample_template))
    ch_index_script    = Channel.value(file(params.report_index_script))
    ch_templates_dir   = Channel.value(file(params.report_templates_dir))

    // Where the complete output lands, printed in the dashboard header so a viewer (Seqera Outputs
    // tab, a downloaded copy) knows which folder holds everything. Resolved as a STRING, not via
    // file(): a cloud outdir (az://) would need credentials at DAG-build time, and a relative local
    // outdir must resolve against launchDir exactly as publishDir does. The report bundle's own
    // folder is shown only when report_outdir moves it out of <outdir>/mutation_reports.
    def to_label = { v -> v.toString() =~ /^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\// ? v.toString() : workflow.launchDir.resolve(v.toString()).normalize().toString() }
    def outdir_label     = to_label(params.outdir)
    def report_dir_label = params.report_outdir ? to_label(params.report_outdir) : ''

    // Which run produced this bundle: one line under the index's summary cards. Read here, at DAG
    // build, from the run's own metadata. The Seqera run id exists only when Platform launched the
    // head job (it exports TOWER_WORKFLOW_ID). A run cannot learn the address of its own page:
    // Platform hands the watch URL to the Tower plugin after the DAG is built and the plugin keeps
    // it private, so the link is built from the optional params.seqera_workspace_url. The map is
    // part of GENERATE_INDEX's task hash on purpose: a resumed run has a new name and start time
    // and re-renders the index under them.
    def run_info = [
        run_name            : workflow.runName,
        session_id          : workflow.sessionId.toString(),
        start               : workflow.start.toString(),
        commit_id           : workflow.commitId,
        revision            : workflow.revision,
        repository          : workflow.repository,
        nextflow_version    : workflow.nextflow.version.toString(),
        seqera_run_id       : System.getenv('TOWER_WORKFLOW_ID'),
        seqera_workspace_url: params.seqera_workspace_url,
    ]

    // =========================================================================
    // 3. Reconstruct per-caller VCF channels from the combined input channel
    // =========================================================================
    //
    // Branch on channel metadata (variantcaller + hc_kind), NOT filenames. Defensive:
    //   - joint HC (hc_kind == 'joint')     → cohort report
    //   - hard-filtered HC (sample_hard)    → dropped (report uses soft, per generate_index.py)
    //   - any other HC (soft/single/absent) → per-sample report
    //   - cnvkit / manta / tiddit           → SV/CNV reports
    // Any non-report caller (freebayes, mutect2, deepvariant, …) is filtered out here, so the
    // caller can pass the whole annotated/raw VCF channel without pre-filtering.

    ch_report_known = report_vcfs
        .filter { meta, vcf, tbi ->
            meta.variantcaller in ['haplotypecaller', 'cnvkit', 'manta', 'tiddit'] &&
            !(meta.variantcaller == 'haplotypecaller' && meta.hc_kind == 'sample_hard')
        }
        .map { meta, vcf, tbi ->
            def rmeta
            if (meta.variantcaller == 'haplotypecaller' && meta.hc_kind == 'joint') {
                rmeta = [ id: 'cohort',  caller: 'haplotypecaller', caller_label: 'HaplotypeCaller' ]
            } else if (meta.variantcaller == 'haplotypecaller') {
                rmeta = [ id: meta.id,   caller: 'haplotypecaller', caller_label: 'HaplotypeCaller' ]
            } else if (meta.variantcaller == 'cnvkit') {
                rmeta = [ id: meta.id,   caller: 'cnvkit',          caller_label: 'CNVKit' ]
            } else if (meta.variantcaller == 'manta') {
                rmeta = [ id: meta.id,   caller: 'manta',           caller_label: 'Manta' ]
            } else {
                rmeta = [ id: meta.id,   caller: 'tiddit',          caller_label: 'TIDDIT' ]
            }
            [ rmeta, vcf, tbi ]
        }

    ch_report_known
        .branch {
            joint:     it[0].id == 'cohort'
            cnvkit:    it[0].caller == 'cnvkit'
            manta:     it[0].caller == 'manta'
            tiddit:    it[0].caller == 'tiddit'
            hc_sample: true                       // remaining = per-sample haplotypecaller
        }
        .set { ch_caller }

    ch_joint_vcf      = ch_caller.joint
    ch_sample_hc_vcfs = ch_caller.hc_sample
    ch_cnvkit_vcfs    = ch_caller.cnvkit
    ch_manta_vcfs     = ch_caller.manta
    ch_tiddit_vcfs    = ch_caller.tiddit

    // Per-sample CRAM lookup keyed by sample id (join, no params.outdir reads)
    ch_cram_by_id = cram.map { meta, c, crai -> [ meta.id, c, crai ] }

    // =========================================================================
    // 4. CN matrix generation (CNVKit) — collected files staged into per-sample dirs
    // =========================================================================

    if (has_cnvkit) {
        // Collect the three per-sample CN files build_cn_matrix.py reads:
        //   .md.cnr (batch), .md.call.cns (in batch .cns list), .md.germline.call.cns (call)
        ch_cn_files = cnvkit_cnr.map { meta, f -> f }
            .mix(cnvkit_cns_batch.flatMap { meta, f -> f instanceof List ? f : [f] })
            .mix(cnvkit_cns_germline.map { meta, f -> f })
            .collect()
            .map { files -> [ [ id: 'all_samples' ], files ] }

        BUILD_CN_MATRIX(ch_cn_files, ch_fai)
        versions = versions.mix(BUILD_CN_MATRIX.out.versions)

        BUILD_CN_COHORT(BUILD_CN_MATRIX.out.cn_matrices.map { meta, dir -> dir }, ch_fai)
        versions = versions.mix(BUILD_CN_COHORT.out.versions)

        ch_cn_data = BUILD_CN_COHORT.out.collapsed
            .mix(BUILD_CN_COHORT.out.full)
            .mix(BUILD_CN_MATRIX.out.chr_summary)
            .collect()
    } else {
        ch_cn_data = Channel.empty()
    }

    // =========================================================================
    // 4b. Contig-level copy number (TIDDIT per-contig coverage) — whole-contig only,
    //     and the only quantification of the mitochondrial contig (CNVKit's GC mask
    //     drops every Mito bin).
    // =========================================================================

    if (has_tiddit) {
        // The .tab does not record the -n ploidy TIDDIT ran with; carry it from meta so the
        // script can divide it back out (ratio = Ploidy / n) and make samples comparable.
        ch_contig_cn_in = tiddit_ploidy.map { meta, tab -> [ tab, "${meta.id}=${meta.ploidy ?: 2}" ] }
        BUILD_CONTIG_CN(
            ch_contig_cn_in.map { tab, p -> tab }.collect(),
            ch_contig_cn_in.map { tab, p -> p   }.collect()
        )
        versions = versions.mix(BUILD_CONTIG_CN.out.versions)
        ch_contig_cn = BUILD_CONTIG_CN.out.csv
    } else {
        ch_contig_cn = Channel.empty()
    }

    // =========================================================================
    // 5. SVDB SV merge chain + cohort matrix. Recipe frozen from the
    //     2026-08-28 bench (docs/benchmarking/ottilie_xenobiotic_ale/04_validate/
    //     sv_merge_bench/NOTES.md — findings F1-F10 referenced below):
    //         Manta:  convertInversion → collapse breakend pairs ──────────────┐
    //         TIDDIT: collapse breakend pairs → SVDB merge across samples ─────┴→ SVDB merge
    //                                                                        across callers
    //     Two views: 'union' (all calls) and 'union_pass' (inputs pre-filtered to
    //     FILTER PASS/'.' — deliberately NOT svdb --pass_only, which only refuses to
    //     MERGE non-PASS records but still emits them, F2).
    // =========================================================================

    if (has_manta && has_tiddit) {
        // Manta types inversions as INV3/INV5 breakend pairs; TIDDIT types them <INV>.
        // convertInversion.py (ships with Manta) rewrites the pairs as <INV> records so
        // the two callers can merge (F5). Inter-chromosomal pairs stay BND on both sides.
        MANTA_CONVERTINVERSION(
            vcf_manta_sv.map { meta, vcf -> [ [ id: meta.id, caller: 'manta' ], vcf ] },
            ch_fasta.map { fa, fai -> [ [ id: 'reference' ], fa ] }
        )

        // One record per breakend junction, BOTH callers — SVDB treats a BND as an
        // unordered breakpoint pair and merges mates asymmetrically otherwise (F3).
        COLLAPSE_SV_PAIRS(
            MANTA_CONVERTINVERSION.out.vcf
                .mix(vcf_tiddit_raw.map { meta, vcf -> [ [ id: meta.id, caller: 'tiddit' ], vcf ] })
        )
        versions = versions.mix(COLLAPSE_SV_PAIRS.out.versions)

        // TIDDIT soft filters (item 4): three Manta-inspired named tags appended to FILTER
        // on the per-sample merge input — the pass view drops them below, the union view
        // keeps every record with its reason. Manta needs no equivalent (its own PASS is
        // already multi-criteria). Raw caller VCFs are untouched.
        ch_collapsed = COLLAPSE_SV_PAIRS.out.vcf.branch { meta, vcf ->
            tiddit: meta.caller == 'tiddit'
            other:  true
        }
        TIDDIT_SV_FILTER(ch_collapsed.tiddit)
        versions = versions.mix(TIDDIT_SV_FILTER.out.versions)
        ch_sv_merge_in = TIDDIT_SV_FILTER.out.vcf.mix(ch_collapsed.other)

        // PASS-view inputs: keep FILTER == PASS or '.' (F2).
        FILTER_SV_PASS(ch_sv_merge_in.map { meta, vcf -> [ meta, vcf, [] ] }, [], [], [])
        versions = versions.mix(FILTER_SV_PASS.out.versions)

        ch_sv_collapsed = ch_sv_merge_in.map { meta, vcf -> [ 'union',      meta.caller, vcf ] }
            .mix(FILTER_SV_PASS.out.vcf.map  { meta, vcf -> [ 'union_pass', meta.caller, vcf ] })

        // TIDDIT across samples: one merge per view. sort_inputs=true → alphabetical file
        // order, so svdb's filename-derived tags AND the appended sample columns match the
        // joint Manta VCF's column order (groupTuple(sort:{it.name}) upstream) — the
        // invariant CHECK_SV_SAMPLE_ORDER asserts below.
        SVDB_MERGE_TIDDIT(
            ch_sv_collapsed.filter { mode, caller, vcf -> caller == 'tiddit' }
                .map { mode, caller, vcf -> [ mode, vcf ] }
                .groupTuple()
                .map { mode, vcfs -> [ [ id: 'sv_tiddit_cohort', merge_mode: mode ], vcfs ] },
            [], true)

        // Manta side: with --joint_manta there is exactly ONE multi-sample VCF per view —
        // it goes straight to the cross-caller merge, as benched. In per-sample Manta mode
        // the VCFs are first merged across samples, exactly like TIDDIT.
        ch_manta_grouped = ch_sv_collapsed.filter { mode, caller, vcf -> caller == 'manta' }
            .map { mode, caller, vcf -> [ mode, vcf ] }
            .groupTuple()
            .map { mode, vcfs -> [ [ id: 'sv_manta_cohort', merge_mode: mode ], vcfs ] }
            .branch { meta, vcfs ->
                multi:  vcfs.size() > 1
                single: true
            }
        SVDB_MERGE_MANTA(ch_manta_grouped.multi, [], true)
        ch_manta_cohort = SVDB_MERGE_MANTA.out.vcf
            .mix(ch_manta_grouped.single.map { meta, vcfs -> [ meta, vcfs[0] ] })

        // Cross-caller merge, manta first: --priority manta,tiddit — the first tag wins the
        // record's POS/END/FORMAT (split-read breakpoints beat TIDDIT's depth-derived ranges,
        // decision 81e01b5), the other caller's coordinates survive in INFO/<tag>_POS (F7).
        // sort_inputs=false keeps the [manta, tiddit] list aligned with the priority tags.
        // The guard exists because --same_order trusts column POSITIONS, never names (F6).
        ch_l2_pairs = ch_manta_cohort.map { meta, vcf -> [ meta.merge_mode, vcf ] }
            .join(SVDB_MERGE_TIDDIT.out.vcf.map { meta, vcf -> [ meta.merge_mode, vcf ] },
                  failOnDuplicate: true, failOnMismatch: true)
            .map { mode, manta_vcf, tiddit_vcf ->
                [ [ id: "sv_cohort_${mode}", merge_mode: mode ], manta_vcf, tiddit_vcf ] }

        CHECK_SV_SAMPLE_ORDER(ch_l2_pairs)
        versions = versions.mix(CHECK_SV_SAMPLE_ORDER.out.versions)

        SVDB_MERGE_CALLERS(
            CHECK_SV_SAMPLE_ORDER.out.vcfs
                .map { meta, manta_vcf, tiddit_vcf -> [ meta, [ manta_vcf, tiddit_vcf ] ] },
            ['manta', 'tiddit'], false)

        // NOTE: MANTA_CONVERTINVERSION and SVDB_MERGE (post-2.8.4 update) emit versions via
        // nf-core topic channels, not versions.yml files — there is no .out.versions to mix.
        // Their entries are absent from the aggregated versions.yml until the fork adopts
        // topic-channel version collection (Sarek >= 3.6 scaffolding).

        // Matrix: one deterministic parse of the merged VCF per view (GT/FT for Manta cells,
        // propagated <sample>.tiddit*_SAMPLE keys for TIDDIT cells) — no proximity matching.
        // Sample order = sorted ids, matching every other cohort table.
        ch_matrix_samples = cram.map { meta, c, crai -> meta.id }.toSortedList()
        BUILD_SV_MATRIX(SVDB_MERGE_CALLERS.out.vcf, ch_matrix_samples)
        versions = versions.mix(BUILD_SV_MATRIX.out.versions)

        // Dashboard data: the two matrix CSVs + the two cohort VCFs (named
        // sv_cohort_merged_<mode>.vcf.gz — generate_index.py probes those names for the
        // "VCF" download buttons beside the ensemble SV table).
        ch_sv_data = BUILD_SV_MATRIX.out.csv
            .mix(SVDB_MERGE_CALLERS.out.vcf.map { meta, vcf -> vcf })
            .mix(SVDB_MERGE_CALLERS.out.tbi.map { meta, tbi -> tbi })
            .collect()
    } else {
        ch_sv_data = Channel.empty()
    }

    // =========================================================================
    // 6. PASS filtering — TIDDIT and Manta
    // =========================================================================
    //
    // FILTER_PASS_VCF emits a PASS-only VCF plus a "total / PASS" stats TSV per input.
    //   - TIDDIT: both are used — the per-sample TIDDIT IGV report shows the PASS VCF.
    //   - Manta:  only the stats are used (the "PASS / all" count in the Sample Overview);
    //             the Manta IGV report keeps every call so Manta's own FILTER tags stay visible.

    ch_pass_filter_in = Channel.empty()
    if (has_tiddit) { ch_pass_filter_in = ch_pass_filter_in.mix(ch_tiddit_vcfs) }
    if (has_manta)  { ch_pass_filter_in = ch_pass_filter_in.mix(ch_manta_vcfs) }

    if (has_tiddit || has_manta) {
        FILTER_PASS_VCF(ch_pass_filter_in)
        ch_tiddit_pass = FILTER_PASS_VCF.out.vcf.filter { meta, vcf, tbi -> meta.caller == 'tiddit' }
        ch_pass_stats  = FILTER_PASS_VCF.out.stats.collect().ifEmpty(file("NO_FILE"))
        versions = versions.mix(FILTER_PASS_VCF.out.versions)
    } else {
        ch_tiddit_pass = Channel.empty()
        ch_pass_stats  = Channel.value(file("NO_FILE"))
    }

    // =========================================================================
    // 7. Publish pre-norm annotated VCFs
    // =========================================================================

    if (has_haplotypecaller) {
        PUBLISH_VCFS(
            ch_joint_vcf,
            ch_sample_hc_vcfs.map { meta, vcf, tbi -> [ vcf, tbi ] }.collect(),
            has_cnvkit ? ch_cnvkit_vcfs.flatMap { meta, vcf, tbi -> [vcf, tbi] }.collect() : Channel.value([]),
            has_manta  ? ch_manta_vcfs.flatMap  { meta, vcf, tbi -> [vcf, tbi] }.collect() : Channel.value([]),
            has_tiddit ? ch_tiddit_vcfs.flatMap { meta, vcf, tbi -> [vcf, tbi] }.collect() : Channel.value([]),
            has_tiddit ? ch_tiddit_pass.flatMap { meta, vcf, tbi -> [vcf, tbi] }.collect() : Channel.value([])
        )
        versions = versions.mix(PUBLISH_VCFS.out.versions)
    }

    // =========================================================================
    // 8. Prepare VCFs for igv-reports (multi-allelic split, VAF, FILTER→INFO)
    // =========================================================================

    if (has_haplotypecaller) {
        ch_all_vcfs = ch_joint_vcf
            .mix(ch_sample_hc_vcfs)
            .mix(ch_cnvkit_vcfs)
            .mix(ch_manta_vcfs)
            .mix(has_tiddit ? ch_tiddit_pass : Channel.empty())

        ch_all_prepared = PREPARE_VCF(ch_all_vcfs)
        versions = versions.mix(PREPARE_VCF.out.versions)

        // Branch into cohort, HC sample, and SV/CNV channels
        ch_all_prepared.vcf.branch {
            cohort: it[0].id == 'cohort'
            sv_cnv: it[0].caller in ['cnvkit', 'manta', 'tiddit']
            sample: true
        }.set { ch_branched }

        // ---------------------------------------------------------------------
        // 9. Cohort report
        // ---------------------------------------------------------------------

        IGVREPORTS_COHORT(ch_branched.cohort, ch_gff3_indexed, ch_fasta, ch_filter_config, ch_template)
        versions = versions.mix(IGVREPORTS_COHORT.out.versions)

        // ---------------------------------------------------------------------
        // 10. Per-sample HaplotypeCaller reports (CRAM by channel join)
        // ---------------------------------------------------------------------

        // combine(by:0), NOT join: a sample may carry multiple report rows sharing meta.id,
        // and join is one-to-one (it would silently drop all but the first). combine matches
        // every row to its sample CRAM.
        ch_samples_with_cram = ch_branched.sample
            .map { meta, vcf, tbi -> [ meta.id, meta, vcf, tbi ] }
            .combine(ch_cram_by_id, by: 0)
            .map { id, meta, vcf, tbi, c, crai -> [ meta, vcf, tbi, c, crai ] }

        IGVREPORTS_SAMPLE(ch_samples_with_cram, ch_gff3_indexed, ch_fasta, ch_filter_config, ch_sample_template)
        versions = versions.mix(IGVREPORTS_SAMPLE.out.versions)

        // ---------------------------------------------------------------------
        // 11. CNVKit BedGraph + SV/CNV per-sample reports
        // ---------------------------------------------------------------------

        if (has_cnvkit) {
            CNR_TO_BEDGRAPH(cnvkit_cnr)
            ch_bedgraph_map = CNR_TO_BEDGRAPH.out.bedgraph
                .map { meta, depth_bg, log2_bg -> [ meta.id, depth_bg, log2_bg ] }
            versions = versions.mix(CNR_TO_BEDGRAPH.out.versions)
        }

        // Absent coverage tracks for callers with no CNVKit output. `[]` is the Nextflow
        // idiom for an optional path: it declares no file, so IGVREPORTS_SV_CNV sees a falsy
        // value and drops the track.
        //
        // Do NOT substitute a placeholder filename here. `file('NO_DEPTH_BG')` (no such file)
        // works on the local executor — Nextflow symlinks it, and `ln -s` to a missing target
        // succeeds — but with a remote work dir (az://, s3://) every input must be physically
        // copied, so FilePorter fails the task with:
        //     Can't stage file /path/NO_DEPTH_BG -- file does not exist
        // Found by the first Azure Batch run; the local test suite cannot catch it. `[]` has
        // nothing to stage and so avoids the problem entirely.
        no_depth_bg = []
        no_log2_bg  = []

        // combine(by:0), NOT join: sv_cnv carries cnvkit + manta + tiddit per sample (same meta.id).
        // join is one-to-one and would drop all but one caller per sample; combine attaches the
        // sample CRAM to every caller's row.
        ch_sv_cnv_with_cram = ch_branched.sv_cnv
            .map { meta, vcf, tbi -> [ meta.id, meta, vcf, tbi ] }
            .combine(ch_cram_by_id, by: 0)
            .map { id, meta, vcf, tbi, c, crai -> [ meta, vcf, tbi, c, crai ] }

        if (has_cnvkit) {
            ch_sv_cnv_with_cram.branch {
                cnvkit: it[0].caller == 'cnvkit'
                other: true
            }.set { ch_sv_cnv_branched }

            ch_cnvkit_with_bg = ch_sv_cnv_branched.cnvkit
                .map { meta, vcf, tbi, c, crai -> [ meta.id, meta, vcf, tbi, c, crai ] }
                .join(ch_bedgraph_map)
                .map { id, meta, vcf, tbi, c, crai, depth_bg, log2_bg ->
                    [ meta, vcf, tbi, c, crai, depth_bg, log2_bg ]
                }

            ch_other_sv = ch_sv_cnv_branched.other
                .map { meta, vcf, tbi, c, crai ->
                    [ meta, vcf, tbi, c, crai, no_depth_bg, no_log2_bg ]
                }

            ch_sv_cnv_all = ch_cnvkit_with_bg.mix(ch_other_sv)
        } else {
            ch_sv_cnv_all = ch_sv_cnv_with_cram
                .map { meta, vcf, tbi, c, crai ->
                    [ meta, vcf, tbi, c, crai, no_depth_bg, no_log2_bg ]
                }
        }

        IGVREPORTS_SV_CNV(ch_sv_cnv_all, ch_gff3_indexed, ch_fasta, ch_sample_template)
        versions = versions.mix(IGVREPORTS_SV_CNV.out.versions)

        // ---------------------------------------------------------------------
        // 12. Generate index.html dashboard
        // ---------------------------------------------------------------------

        ch_cnv_sv_data = ch_cn_data
            .mix(ch_sv_data)
            .mix(ch_contig_cn)
            .mix(ch_pass_stats)
            .collect()
            .ifEmpty(file("NO_FILE"))

        ch_all_sample_reports = IGVREPORTS_SAMPLE.out.report
            .mix(IGVREPORTS_SV_CNV.out.report)
            .collect()

        ch_prepared_cohort_vcf = ch_branched.cohort.map { meta, vcf, tbi -> vcf }

        // MULTIQC.out.report is emitted as .toList() upstream → each emission is a list:
        // [] when skipped, or [report.html] otherwise.
        ch_multiqc_report = multiqc_report
            .map { rep ->
                def r = rep instanceof List ? rep : [rep]
                r ? file(r[0]) : file("NO_FILE")
            }
            .ifEmpty(file("NO_FILE"))

        GENERATE_INDEX(
            IGVREPORTS_COHORT.out.report.collect(),
            ch_all_sample_reports,
            multiqc_data,
            ch_index_script,
            ch_templates_dir,
            ch_cnv_sv_data,
            ch_multiqc_report,
            ch_prepared_cohort_vcf.collect(),
            outdir_label,
            report_dir_label,
            run_info
        )
        versions = versions.mix(GENERATE_INDEX.out.versions)

        ch_report_index = GENERATE_INDEX.out.index

    } else {
        ch_report_index = Channel.empty()
    }

    emit:
    report_index = ch_report_index
    versions     = versions
}
