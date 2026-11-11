#!/bin/bash
# Ottilie test: 2 samples (NODRUG-GM2 + CBR110-15-R3a), chromosomes I, IV, VII, XV + Mito
# Uses the ottilie_test profile (conf/test/ottilie_test.config)
# Truth variants: 4 SNVs + chr I whole-chromosome duplication in CBR110-15-R3a
# Source: Ottilie et al., Commun Biol 5:128 (2022)
pipeline_folder="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Pin the Nextflow runtime: 25.10.x is the validated line; 26.x can't parse this config.
export NXF_VER=25.10.4
nextflow run ${pipeline_folder}/main.nf -profile ottilie_test,azureD4as,docker \
    -w ${pipeline_folder}/work_ottilie_test \
    --outdir ${pipeline_folder}/output_ottilie_test \
    --generate_reports \
    -resume
