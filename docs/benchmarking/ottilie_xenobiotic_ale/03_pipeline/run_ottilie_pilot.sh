#!/bin/bash
# Ottilie Benchmark - Full-depth pilot run (4 samples)
# Reference: S288C R64-1-1 (Ensembl) with locally built SnpEff R64-1-1.105 cache
# Samples: 1 parent (NODRUG-GM2) + 3 evolved (Doxorubicin16-R2b, Carmaphycin-R9-2, CBR110-15-R3a)
# Tools: the shared ottilie recipe (conf/test/ottilie_common.config) — snpeff, cnvkit, tiddit,
#        manta, haplotypecaller. Control-FREEC dropped 2026-08-26: Tier-2, not in the recipe the
#        Azure baselines were produced with, and 04_validate skips it.
#
# Each launch gets a DATED outdir + work dir. publishDir overwrites but never deletes, so reusing
# an outdir across pipeline versions silently mixes stale files into the result. No -resume for
# the same reason: a fresh run is the provenance. To resume a specific launch instead, pass its
# session id explicitly (`-resume <id>`, from .nextflow/history in the repo root) — a bare
# -resume picks up whatever ran last there, which is usually an unrelated test.
#
# Launch DETACHED (about 75 min on the dev VM; a dropped shell or Claude Code session SIGTERMs a child
# run, seen 2026-11-10): setsid nohup bash run_ottilie_pilot.sh > pilot.log 2>&1 < /dev/null & disown
# Recipe + how to resume a killed run with its session id: docs/usage/long_runs_detached.md
#
# Previous run: 2026-07-10, session feea0f276c82158b2065aad5a6bac696 -> output_ottilie/
#               (kept: 01_data_retrieval/release/generate_test_data.sh --from-cram reads its CRAMs)

set -euo pipefail

run_folder="/home/azureuser/Docs/ALE_nextflow"
stamp="$(date +%Y-%m-%d)"
outdir="${run_folder}/output_ottilie_pilot_${stamp}"
workdir="${run_folder}/work_ottilie_pilot_${stamp}"

source ~/miniforge3/etc/profile.d/conda.sh
conda activate /home/azureuser/miniforge3/envs/nf-env

cd "${run_folder}"   # .nextflow/history and .nextflow.log live here

nextflow run ${run_folder}/main.nf \
    -profile azureD4as,docker \
    -w "${workdir}" \
    --input ${run_folder}/data/ottilie/samplesheet_pilot.csv \
    --outdir "${outdir}" \
    --genome null \
    --igenomes_ignore \
    --fasta ${run_folder}/data/ottilie/S288C_reference/S288C_R64.fa \
    --skip_tools baserecalibrator \
    --tools snpeff,cnvkit,tiddit,manta,haplotypecaller \
    --split_fastq 0 \
    --joint_germline \
    --joint_manta \
    --save_mapped \
    --split_haplotypecaller_joint_vcf \
    --snpeff_db R64-1-1.105 \
    --snpeff_cache ${run_folder}/data/ottilie/S288C_reference/snpeff_cache \
    --generate_reports \
    --report_gff3 ${run_folder}/data/ottilie/S288C_reference/S288C_R64.gff3

echo "Pilot outputs: ${outdir}"
