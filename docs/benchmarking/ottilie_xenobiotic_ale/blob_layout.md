# `az://aletest/ottilie/` — which dataset is which

Canonical copy of the note published at `az://aletest/ottilie/README.md`. **Edit this file, then
re-upload** (command at the bottom) so the two never drift.

> ⚠️ **Two ottilie datasets share this prefix, and they are NOT interchangeable.** One is a
> contig subset of two samples, downsampled; the other is four samples at full depth across all
> chromosomes. Mixing them yields results that look plausible and mean nothing — a variant "missing"
> because its chromosome was never in the input, or a runtime that reflects 267 MB when you thought
> it was 4 GB.

**Two versions, side by side.** `ottilie/v2/` (2026-11-11) is what the code on `main` reads.
`ottilie/v1/` is frozen: the `v1.1.0` tag, its Launchpad version and the baselines cut before that
date read it, and no script writes there any more. What v2 changed: the test reads are a new cut
(from SRA, Mito added, 0.67 of the pairs), the test reference has five contigs, and every snpEff
database carries the mitochondrial genetic code. The pilot FASTQs are the same files in both.

## The two datasets

| | **Test set** — 2 samples, 4 chromosomes + Mito | **Pilot set** — 4 samples, all chromosomes |
|---|---|---|
| FASTQs | `ottilie/v2/fastq_test/` | `ottilie/v2/fastq_pilot_full/` |
| Reference | `ottilie/v2/S288C_reference_test/` | `ottilie/v2/S288C_reference/` |
| Samplesheet | `ottilie/v2/samplesheet_test_az.csv` | `ottilie/v2/samplesheet_pilot_az.csv` |
| Samples | `NODRUG-GM2`, `CBR110-15-R3a` | those two **+** `Doxorubicin16-R2b`, `Carmaphycin-R9-2` |
| Chromosomes | **I, IV, VII, XV and Mito only** | all 16 + Mito |
| Depth | 0.67 of the pairs: about 30x parent, 60x evolved | as sequenced |
| Size | 267 MB FASTQ · 41 MB reference | ~4.0 GB FASTQ · ~79 MB reference |
| Truth set | 4 SNVs + a chr I duplication | 43 published events (Sup Data 4+5: 21 SNV, 21 INDEL, 1 CNV) — `pilot_truth_set.csv`; a benchmark, not the release contract test |
| Purpose | the **release contract test** | benchmarking · the cold-pool disk measurement |
| Also published publicly? | ✅ yes, see *Access* below | ❌ **no** — private only |

**Telling them apart at a glance.** Every file names its own dataset. Test-set files carry `_test` or
the contig list, seed and fraction (`NODRUG-GM2_chrI_IV_VII_XV_Mito_seed42_frac0.67_R1.fastq.gz`,
`S288C_R64_test.fa`); pilot FASTQs carry the sample name, the SRA accession and `_allchr`:

```
fastq_test/       NODRUG-GM2_chrI_IV_VII_XV_Mito_seed42_frac0.67_R1.fastq.gz   ← 5 contigs, 0.67 of the pairs
fastq_pilot_full/ NODRUG-GM2_SRR10985539_allchr_R1.fastq.gz                    ← full depth, all 16 + Mito
```

`fastq_test/CUT_PARAMETERS.tsv` (seed, fractions, pair counts, md5s) and `fastq_test/TRUTH_GATE.txt`
(the checks the cut passed before upload) sit next to the test FASTQs.

⚠️ **Never stage pilot FASTQs under their bare SRA names.** `SRR10985539_1.fastq.gz` says nothing
about sample, depth or chromosome coverage — it is the one naming that could sit beside the test
files without looking wrong. [`upload_pilot_data.sh`](01_data_retrieval/release/upload_pilot_data.sh) does the
renaming; use it rather than uploading by hand.

## What the pilot reference does and does not contain

| Consumed as | File | |
|---|---|---|
| `fasta` | `S288C_R64.fa` | 12 MB |
| `genbank` | `S288C_R64_ensembl_chrnames.gb` | 32 MB |
| `snpeff_cache` | `snpeff_cache/R64-1-1.105/` | 23 MB — with the `Mito` codon-table line since v2 |
| `chr_dir` | `chromosomes/` (17 files) | 12 MB — Control-FREEC only; optional |
| `report_gff3` | `S288C_R64.gff3` | 5.5 MB — was already here, shared with the test run |

⚠️ **The bwa-mem2 indices are deliberately absent** (`.0123`, `.bwt.2bit.64`, `.amb`, `.ann`, `.pac`,
and `.fai`/`.dict`). The validated cloud run does not pass `fasta_fai`/`bwa`/`dict` as params, so Sarek
builds them in-run. Uploading them changes nothing unless they are *also* passed — and passing them
would alter the task graph, breaking comparability with the run being measured against.

## Lineage — the two sets share two libraries

```
SRA PRJNA590203 ─► 4 pilot samples, full depth  (the pilot set, as sequenced)
        │
        └─► 2 of the 4 runs ─► aligned, pairs on I/IV/VII/XV/Mito kept ─► seeded 0.67 of the pairs
                                                                              │
                                                                              ▼
                                                                         test set (267 MB)
```

So the test set is a **contig subset and a read subsample** of two pilot libraries, which is why the
two sets share sample names. (Version 1 was a chromosome subset at the pilot's depth, cut from the
CRAMs of a pipeline run.) Full lineage and the depth measurements:
[`DATA_PROVENANCE.md`](DATA_PROVENANCE.md).

## Access

| Account / container | Public? | Holds |
|---|---|---|
| `aledata` / `aletest` | **private** | everything above, plus `workDir` and run outputs |
| `aletestdatapublic` / `releases` | **public, no SAS** | the **test set only**, for credential-free onboarding |

⚠️ **Nothing else belongs on the public account** — in particular no real project data (dicarboxylic
acids / CENPK), which is not public. The pilot set stays private too. `upload_pilot_data.sh` refuses
to run against the public account or any container whose `publicAccess` is not `None`;
[`publish_test_data.sh`](01_data_retrieval/release/publish_test_data.sh) is the only script that writes there.

### Why the pilot set is private even though its source is public — decided 2026-08-12

PRJNA590203 is public, so this is a **cost-and-purpose** decision, not a governance one. Re-hosting it
publicly was considered and rejected:

- **It would duplicate two things that already exist.** SRA serves the reads, and
  [`download_pilot_fastq.sh`](01_data_retrieval/fastq/download_pilot_fastq.sh) already fetches exactly these
  four accessions. A public copy gives an external user nothing new.
- **It is the wrong artifact for external onboarding.** The pilot is a 4 GB benchmark, not a smoke
  test: the published test set (267 MB, 4 SNVs + a chr I duplication) is what an outside user needs to
  prove a pipeline runs correctly. The pilot's own truth set — 43 events from the paper's Sup Data 4+5
  — *is* published, as `pilot_truth_set.csv` in the same bundle, together with the recipe to fetch the
  reads from SRA (`download_pilot_fastq.sh`, revision 2026-08-26).
- **Egress and support.** ~4 GB per download at ~$0.087/GB, unthrottled and unattributable behind a
  no-SAS URL, versus ~$0.03 for the test set. Publishing also implies `SHA256SUMS`, a public-URL
  samplesheet, version discipline, and an artifact that can no longer be restructured quietly.

This set exists to **stress-test Azure resource usage** — node disks, pool scaling, staging throughput
— which is an internal question about our own infrastructure. If external stress-testing ever becomes a
goal, publish the *recipe* (`download_pilot_fastq.sh` + `upload_pilot_data.sh`) rather than the data:
anyone running it on their own Batch pool needs it in their own storage account regardless.
(`download_pilot_fastq.sh` ships in the public bundle since 2026-08-26; `upload_pilot_data.sh` stays
repo-only — it targets our private account.)

⚠️ **`workDir` must live in this same container** whenever a run uses the Entra service principal:
Nextflow mints one container-scoped SAS and reuses it for every blob URL, so a node cannot read
another container even in the same account. See
[`azure_batch_execution.md` §3](../../dev-practices/azure_batch_execution.md).

## Re-uploading this note

```bash
az storage blob upload --account-name aledata -c aletest --auth-mode login --overwrite \
    --name ottilie/README.md \
    --file docs/benchmarking/ottilie_xenobiotic_ale/blob_layout.md
```
