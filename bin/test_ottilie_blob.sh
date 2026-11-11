#!/usr/bin/env bash
# Ottilie test, blob edition: same 2 samples (NODRUG-GM2 + CBR110-15-R3a) / 5 contigs
# (I, IV, VII, XV, Mito) as bin/test_ottilie.sh, but every input is streamed from the PUBLIC
# Azure Blob (no credentials, no SAS, no populated data/ottilie/).
# Uses the ottilie_test_ci profile (conf/test/ottilie_test_ci.config).
# Truth variants: 4 SNVs + chr I whole-chromosome duplication in CBR110-15-R3a
# Source: Ottilie et al., Commun Biol 5:128 (2022)
#
# The reference is ONE file, the test GenBank, streamed from its URL like the FASTQs and the
# samplesheet; the run builds the FASTA, the snpEff database and the gene track from it. Until
# 2026-11 this script first fetched and untarred the published snpeff_cache.tar.gz, because a
# pre-built snpEff cache is a directory and an https URL cannot be listed. That step is gone:
# the script is now the launch command and nothing else. (The tarball stays on the blob for a
# run on the pre-built files; a leftover .ottilie_ci_cache/ from an earlier run can be deleted.)
#
# STORAGE / CLEANUP — streaming does NOT mean "no local copy". Nextflow downloads each remote
# file ONCE per session into <workdir>/stage-<session-uuid>/ and symlinks it into every task dir
# (~278 MB for this test). Two consequences:
#   * `-resume` (passed below) reuses that stage dir. A run WITHOUT -resume gets a new session id
#     → a second full stage-* copy alongside the first. Never drop -resume when reusing the work dir.
#   * `nextflow clean` removes task dirs but NOT stage-* dirs (verified) — so cleaning up means
#     `rm -rf work_ottilie_test_blob` (which also reclaims the staged inputs), not `nextflow clean`.
# Nothing lives outside the work dir and the output dir.
#
# Usage (from anywhere):
#   bash bin/test_ottilie_blob.sh                    # extra args are passed through to nextflow
# Re-host / new version:
#   OTTILIE_BLOB_BASE=https://<acct>.blob.core.windows.net/<container>/ottilie/v2 bash bin/test_ottilie_blob.sh

set -euo pipefail

pipeline_folder="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BLOB_BASE="${OTTILIE_BLOB_BASE:-https://aletestdatapublic.blob.core.windows.net/releases/ottilie/v2}"

export NXF_VER=25.10.4
export OTTILIE_BLOB_BASE="$BLOB_BASE"

nextflow run ${pipeline_folder}/main.nf -profile ottilie_test_ci,azureD4as,docker \
    -w ${pipeline_folder}/work_ottilie_test_blob \
    --outdir ${pipeline_folder}/output_ottilie_test_blob \
    --generate_reports \
    -resume "$@"
