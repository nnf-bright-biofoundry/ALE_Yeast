# Ottilie Xenobiotic ALE Benchmark

Benchmarking the NF_ALE Sarek pipeline against published variant calls from [Ottilie et al. (2022)](https://doi.org/10.1038/s42003-022-03076-7), a large-scale yeast ALE study with 363 drug-resistant clones.

For scientific background, tier rationale, and truth set details, see [RESEARCH_CONTEXT.md](docs/RESEARCH_CONTEXT.md).
For formal deliverables and acceptance criteria, see [statement_of_work.md](docs/statement_of_work.md).

## Tiered Benchmarking Strategy

| Tier | Samples | Purpose | Size | Status |
|------|---------|---------|------|--------|
| **1 — Pilot** | 4 (1 parent + 3 evolved) | Benchmark: 43 published events (`data/ottilie/pilot_truth_set.csv`) — 41/42 SNV/INDEL + 1/1 CNV detected (2026-08-26, `04_validate/pilot_results_v2/`; the 1 miss is `Mito:53278`, a petite-type mtDNA loss with no mappable breakpoints that CNVKit's GC mask also excludes — see `NOTES.md`) | ~4 GB | Complete |
| **2 — CRISPR + CNV** | 85 clones + parent | High-confidence SNV + CNV benchmark | ~40 GB | Deferred — may be retired. CRAMs archived 2026-09-09 (`az://aledata/Yeast/archive-projects/ottilie_tier2/`), results kept in `04_validate/tier2_results/` |
| **3 — Full cohort** | 355 clones + parents | Comprehensive benchmark | ~170 GB | Future |

**Current focus (2026-08):** day-to-day development and release validation run on the **2-sample
test set** (five contigs, a read subsample) cut from two of the pilot's libraries (`01_data_retrieval/release/`, the `ottilie_test`
profile); the **4-sample full-depth pilot** is staged on Azure (`az://aletest/ottilie/v2/`) and is
the near-term target for cloud-scale runs. Tier 2 is pushed out accordingly and may be retired —
its retrieval/selection scripts below remain functional but are not on the active path.

## Quick Start

```bash
# Prerequisites: conda activate nf-env, Docker running

# 1. Download truth set (supplementary xlsx files)
bash 01_data_retrieval/truth_set/download_truth_set.sh

# 2. Prepare S288C reference genome + SnpEff cache
bash 02_reference_prep/prepare_s288c_reference.sh

# --- Tier 1: Pilot (4 samples) ---
bash 01_data_retrieval/fastq/download_pilot_fastq.sh
bash 03_pipeline/run_ottilie_pilot.sh

# --- Tier 2: CRISPR-validated (85 samples) ---
python 01_data_retrieval/truth_set/select_tier2_crispr_validated.py  # generates clone list
bash 01_data_retrieval/fastq/download_tier2_fastq.sh                 # download from SRA
# bash 03_pipeline/run_ottilie_tier2.sh                     # TODO
```

## Directory Structure

```
ottilie_xenobiotic_ale/
├── 01_data_retrieval/                    # SRA data download and sample resolution
│   ├── environment_data_retrieval.yml    # Conda env (sra-tools pinned to 3.2.1)
│   │
│   ├── truth_set/                        # Truth set download + sample resolution + tier selection
│   │   ├── download_truth_set.sh         # Download Sup 4/5/7 xlsx from PMC
│   │   ├── resolve_sra_accessions.py     # Build sample_name_dictionary.csv
│   │   ├── validate_dictionary.py        # QC: check dictionary completeness
│   │   ├── inspect_supplementary.py      # QC: explore supplementary data structure
│   │   └── select_tier2_crispr_validated.py  # Select 85 Tier 2 clones (CRISPR + CNV)
│   │
│   ├── fastq/                            # FASTQ download (SRA / Azure Blob)
│   │   ├── download_pilot_fastq.sh       # Tier 1: 4 pilot samples
│   │   ├── download_tier2_fastq.sh       # Tier 2: 85 benchmark samples
│   │   ├── download_tier2_from_blob.sh   # Tier 2: fetch from the Azure Blob archive
│   │   ├── download_all_fastq.sh         # Tier 3: all 363 samples
│   │   └── subsample_fastq.sh            # Optional: subsample for quick testing
│   │
│   └── release/                          # Test-set generation + blob publishing
│       ├── generate_test_data.sh         # Build the 2-sample chr-subset test set
│       ├── publish_test_data.sh          # Publish the test set to the public blob
│       ├── download_test_data.sh         # Fetch the published test set (no creds)
│       ├── upload_pilot_data.sh          # Upload the pilot set to the private blob
│       └── bundle_README.md              # README shipped inside the data bundle
│
├── 02_reference_prep/                    # S288C R64-1-1 reference setup
│   ├── prepare_s288c_reference.sh        # Master script (all 5 steps, idempotent)
│   └── rename_genbank_chromosomes.sh     # NC_* -> Roman numeral chr names
│
├── 03_pipeline/                          # Sarek execution (customized nf-core/sarek 3.5.1)
│   ├── run_ottilie_pilot.sh              # Launch Tier 1 pilot benchmark
│   └── run_ottilie_pilot_subsampled.sh   # Launch Tier 1 with subsampled FASTQs
│
├── 04_validate/                          # Concordance analysis scripts
│   ├── snv_indel_concordance.py          # Task 1: HaplotypeCaller vs Sup Data 4
│   └── cnv_concordance.py               # Task 2: CNVKit/Control-FREEC vs Sup Data 5
│
├── docs/                                 # Background documentation
│   ├── RESEARCH_CONTEXT.md               # Science context and tier rationale
│   └── statement_of_work.md             # Deliverables and acceptance criteria
│
└── README.md                             # This file
```

### Data Files (generated, not in this directory)

```
data/ottilie/
├── fastq/                                # Downloaded FASTQ files
├── samplesheet_pilot.csv                 # Sarek input — Tier 1 (4 pilot samples)
├── tier2_crispr_validated_clones.csv     # Tier 2 clone list (64 samples + metadata)
├── sample_name_dictionary.csv            # Cross-source sample name mapping (356 samples)
├── PRJNA590203_runinfo.csv               # Full SRA metadata
├── supplementary/                        # Ottilie paper supplementary xlsx files
│   ├── sup_4_*.xlsx                      # 1,405 mutations (SNV/INDEL truth set)
│   ├── sup_5_*.xlsx                      # 24 CNVs (CNV truth set)
│   └── sup_7_*.xlsx                      # CRISPR/Cas9 validation (45 confirmed)
└── S288C_reference/                      # Reference genome and annotations
    ├── S288C_R64.fa{,.fai}               # Ensembl FASTA (chr: I-XVI, Mito)
    ├── S288C_R64.gff3                    # Ensembl GFF3 annotations
    ├── S288C_R64.gbff                    # NCBI GenBank (original NC_* names)
    ├── S288C_R64_ensembl_chrnames.gb     # GenBank with Ensembl chr names (for breseq)
    ├── chromosomes/                      # Per-chr FASTAs (for Control-FREEC)
    └── snpeff_cache/R64-1-1.105/         # Locally-built SnpEff cache
```

## Reference Genome

**Source**: S288C R64-1-1 from Ensembl release 105

**Why Ensembl?** Chromosome names (Roman numerals: I-XVI, Mito) must match the SnpEff `R64-1-1.105` database. NCBI uses `NC_*` accession-style names which cause mismatches.

**GenBank for breseq**: Downloaded from NCBI (has embedded sequences + rich annotations), then chromosome names sed-replaced to Ensembl convention via `rename_genbank_chromosomes.sh`.

**SnpEff cache**: Built locally using `snpEff build -gff3 -noCheckCds -noCheckProtein` inside the `quay.io/biocontainers/snpeff:5.2--hdfd78af_1` container.

All reference prep is captured in `prepare_s288c_reference.sh` (idempotent, skips existing files).

## Tier 1 — Pilot Samples

| Sample | SRR | Role | Coverage |
|--------|-----|------|----------|
| NODRUG--GM2 | SRR10985539 | Parent (ancestor) | 53x |
| Doxorubicin-16--R2b | SRR10985527 | SNV benchmark (23 mutations) | 116x |
| Carmaphycin--R9-2 | SRR10985678 | SNV benchmark (15 mutations) | 213x |
| CBR110-15-R3a | SRR10985585 | CNV benchmark (ChrI aneuploidy) | 104x |

All paired-end 100bp reads (Illumina HiSeq 2500), haploid BY4741-derived strain.

## Pipeline Configuration

This benchmark uses a **customized fork of nf-core/sarek 3.5.1** with ALE-specific modifications (ploidy support, breseq integration, AF-based somatic filtering, joint germline filter annotation fallback, etc.).

- **Tools (this release)**: HaplotypeCaller, CNVKit, Control-FREEC, SnpEff
- **Mode**: Joint germline (all status=0, ploidy=1)
- **Disabled**: baserecalibrator (no known-sites for S288C), FreeBayes (speed)
- **Not in scope**: breseq (still in development; will be validated in a future release after dev/test/deploy best practices are established)
- **Profile**: Adjust to your environment (e.g., `singularity,slurm` for HPC, `docker` for local)

## Resource Estimates

Based on Tier 1 actual measurements (4 samples on a 4 vCPU / 16 GB RAM node).
Tools: snpeff, cnvkit, tiddit, controlfreec, haplotypecaller (no breseq).

### Per-Tier Storage

| Tier | FASTQs | Work Dir | Output | Total | Temp (fasterq-dump) |
|------|--------|----------|--------|-------|---------------------|
| **1 — Pilot** (4 samples) | 4 GB | 13 GB | 2.8 GB | **~20 GB** | ~12 GB peak |
| **2 — CRISPR+CNV** (86 samples) | ~40 GB | ~280 GB | ~60 GB | **~380 GB** | ~120 GB peak |
| **3 — Full cohort** (363 samples) | ~170 GB | ~1.2 TB | ~255 GB | **~1.6 TB** | ~500 GB peak |

Work dir estimate: ~3.25 GB/sample (Tier 1 actual: 13 GB / 4 samples).
fasterq-dump temp: ~3x compressed FASTQ size (uncompressed intermediate before gzip).

### Peak RAM by Process (Tier 1 Actual)

| Process | Peak RSS | Notes |
|---------|----------|-------|
| GATK4_MarkDuplicates | 9.3 GB | Per sample (constant) |
| BWA-MEM | 4.8 GB | Per sample (constant) |
| GATK4_HaplotypeCaller | 1.7 GB | Per sample (constant) |
| FastQC | 1.2 GB | Per sample (constant) |
| SnpEff | 1.2 GB | Per sample (constant) |
| TIDDIT_SV | 918 MB | Per sample (constant) |
| MultiQC | 808 MB | Scales with samples |
| CNVKit_BATCH | 671 MB | Per sample (constant) |
| GATK4_GenotypegVCFs | 769 MB | JVM heap capped |
| Control-FREEC | 10 MB | Per sample (constant) |

**RAM is not a limiting factor** for yeast (12 Mb genome). Standard HPC nodes (16+ GB) are sufficient for all tiers.

### Runtime Estimates (single node, 4 CPU, serial)

| Process | Per Sample | 86 Samples (serial) | Notes |
|---------|-----------|---------------------|-------|
| BWA-MEM | ~5 min | ~7 hrs | Parallelizable |
| MarkDuplicates | ~3 min | ~4 hrs | Parallelizable |
| HaplotypeCaller | ~8 min | ~11 hrs | Parallelizable |
| CNVKit | ~3 min | ~4 hrs | Parallelizable |
| TIDDIT_SV | ~2 min | ~3 hrs | Parallelizable |
| Control-FREEC | ~1 min | ~1.5 hrs | Parallelizable |
| Joint calling | ~30 sec | ~5 min | Single job |

**Total (single node, serial)**: ~2-3 days.

### Feasibility by Tier

| | Tier 1 (4 samples) | Tier 2 (86 samples) | Tier 3 (363 samples) |
|--|---------------------|---------------------|----------------------|
| **Disk** | ~20 GB | **~380 GB** | **~1.6 TB** |
| **RAM** | 9.3 GB peak | 16 GB sufficient | 16 GB sufficient |
| **Runtime (4 CPU, serial)** | ~2 hrs | ~2-3 days | ~1-2 weeks |
| **Runtime (HPC, parallel)** | <1 hr | ~3-6 hrs | ~12-24 hrs |

**Tier 1** runs comfortably on a single workstation (4+ cores, 16 GB RAM, 25 GB disk).

**Tier 2** is feasible on a single node with sufficient disk (~400 GB), but HPC/cloud parallelism recommended for speed.

**Tier 3** should be run on HPC or cloud compute:
- Nextflow natively supports SLURM, PBS, LSF, and cloud executors
- Recommended: `nextflow run ... -profile singularity,slurm`

## Known Issues

- `sra-tools 3.4.1` segfaults — pinned to 3.2.1 in `environment_data_retrieval.yml`
- Sample naming inconsistencies across supplementary tables and SRA — handled by `resolve_sra_accessions.py` with 3 manual overrides
- 1 Tier 2 CRISPR clone (EAW901 / DDD01035522--1R2a) has no SRR accession in the dictionary
