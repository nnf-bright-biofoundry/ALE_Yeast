# 01_data_retrieval — Ottilie Benchmark Data Acquisition

This directory holds the data-retrieval stage of the ottilie benchmark: fetching the truth set and
FASTQ reads for SRA BioProject **PRJNA590203** ([Ottilie et al., *Commun Biol* 5:128, 2022](https://doi.org/10.1038/s42003-022-03076-7)),
and building/publishing the derived test and pilot datasets. Scripts run in the conda env defined by
[`environment_data_retrieval.yml`](environment_data_retrieval.yml) (env name `ottilie-benchmark`;
`sra-tools` pinned to 3.2.1 because 3.4.1 segfaults). Deeper provenance and blob layout live in
[`../DATA_PROVENANCE.md`](../DATA_PROVENANCE.md) and [`../blob_layout.md`](../blob_layout.md).

Subdirectories follow workflow order: `truth_set/` → `fastq/` → `release/`.

> **Status (2026-08):** the working dataset is the **2-sample chr-subset test set** built and
> published by `release/`; the **4-sample full-depth pilot** (staged by
> `release/upload_pilot_data.sh`) is the near-term target. **Tier 2 is deferred and may be
> retired** — the Tier 2 scripts in `truth_set/` and `fastq/` are kept functional but are not on
> the active path. See [`../README.md`](../README.md) for the tier table.

## truth_set/ — Truth set + sample-name resolution

Downloads the paper's supplementary tables and reconciles the three naming schemes (sup_4, sup_5,
SRA RunInfo) into a sample dictionary, then selects the Tier 2 clone list.

| Script | What it does | Key inputs / outputs |
|---|---|---|
| `download_truth_set.sh` | Download Ottilie supplementary data files (Sup 4/5/7 xlsx) from PMC — the benchmarking truth set | → `data/ottilie/supplementary/sup_{4,5,7}_*.xlsx` |
| `inspect_supplementary.py` | Inspect sup_4/sup_5 structure: columns, sample counts, pilot clone details (downloads if absent) | `data/ottilie/supplementary/` |
| `resolve_sra_accessions.py` | Reconcile naming across sup_4, sup_5, and SRA RunInfo into a sample name dictionary | `PRJNA590203_runinfo.csv` + sup xlsx → `data/ottilie/sample_name_dictionary.csv` |
| `validate_dictionary.py` | QC the dictionary: match completeness across sources, clones in both tables, naming differences | `data/ottilie/sample_name_dictionary.csv` |
| `select_tier2_crispr_validated.py` | Select ~85 Tier 2 clones: CRISPR-validated SNV/INDEL clones (Sup 7→4) + CNV clones (Sup 5) | sup xlsx + dictionary → `data/ottilie/tier2_crispr_validated_clones.csv` |
| `extract_pilot_truth_set.py` | Extract the 4-sample pilot's published events (Sup 4 SNV/INDEL + Sup 5 CNV, 43 rows) keyed by pipeline sample names — ships in the public bundle | sup xlsx → `data/ottilie/pilot_truth_set.csv` (**tracked in git**) |

`sample_name_dictionary.csv` and `pilot_truth_set.csv` are the two files under `data/ottilie/` that
**are tracked in git** (`.gitignore` exceptions): small, derived from public data, and both published
in the release bundle. Regenerate with the scripts above rather than editing by hand.

## fastq/ — FASTQ acquisition

Downloads reads per tier, from SRA (needs `ottilie-benchmark` env) or from the private `aledata`
blob (needs `az login`), plus optional subsampling for quick tests.

| Script | What it does | Key inputs / outputs |
|---|---|---|
| `download_pilot_fastq.sh` | Download the 4 Tier 1 pilot samples from SRA (parent + 3 evolved clones with 43 published events) and write `samplesheet_pilot.csv`. Self-contained — also ships in the public bundle; `OUT=` relocates it | → `data/ottilie/fastq/` (~2 GB gzipped) + `data/ottilie/samplesheet_pilot.csv` |
| `download_tier2_fastq.sh` | Download the 85 Tier 2 samples from SRA (resumable; ≥160 GB free needed for temp) | `tier2_crispr_validated_clones.csv` → `data/ottilie/fastq/` |
| `download_tier2_from_blob.sh` | Download the 86 Tier 2 SRRs from the private `aledata` blob instead of SRA (~15–30 min, no temp space) | `tier2_crispr_validated_clones.csv` → `data/ottilie/fastq/` |
| `download_all_fastq.sh` | Download all 363 samples from SRA in ~50-sample batches, uploading each batch to Azure Blob before deleting locally | `PRJNA590203_runinfo.csv` → blob; `data/ottilie/fastq_all/` scratch |
| `subsample_fastq.sh` | Subsample paired FASTQs with seqtk (fixed seed, matched R1/R2; default 500K pairs ≈ 8x) | `data/ottilie/fastq/` → `data/ottilie/fastq_subsampled/` |

## release/ — Test-set and pilot-set packaging

Builds the 2-sample chr-subset release test set, publishes it publicly, fetches it on a fresh
machine, and stages the full-depth 4-sample pilot set for Azure Batch.

| Script | What it does | Key inputs / outputs |
|---|---|---|
| `generate_test_data.sh` | Generate the test set (v2): align the 2 samples' SRA FASTQs, keep the pairs on chr I/IV/VII/XV/Mito, keep a seeded fraction of them, slim the S288C reference to the same contigs. `--align-only` prints the depth per contig; `OUT_ROOT`, `SEED`, `FRACTION_*` cut a candidate | `data/ottilie/fastq/SRR…` → `data/ottilie/fastq_test/` (+ `CUT_PARAMETERS.tsv`), `S288C_reference_test/`, `samplesheet_test.csv` |
| `check_test_data_truth.py` | The truth gate: on a pipeline run of the cut, checks the read counts, the 4 SNVs, the chr I gain, the SV floor (`test_set_sv_floor.tsv`) and the Mito manifest row, then stamps `fastq_test/TRUTH_GATE.txt`. The upload scripts refuse an unstamped cut | pipeline outdir → `TRUTH_GATE.txt` |
| `publish_test_data.sh` | Publish the test data to the public blob in both shapes: one atomic bundle tarball + individual `files/**` tree, with `SHA256SUMS`, blob samplesheet, README, the pilot recipe (`download_pilot_fastq.sh`), `pilot_truth_set.csv` and `sample_name_dictionary.csv`. `DRY_RUN=1` builds and verifies locally without uploading | `data/ottilie/` → `aletestdatapublic/releases` (PUBLIC, no SAS) |
| `bundle_README.md` | Canonical copy of the README shipped inside `ottilie_test_data.tar.gz` — edit here, then re-run `publish_test_data.sh` | — |
| `download_test_data.sh` | Fetch the published bundle from the stable public URL (curl + tar, no credentials) and write the machine-correct samplesheet | public blob → `data/ottilie/` |
| `upload_pilot_data.sh` | Stage the full-depth 4-sample pilot (renamed FASTQs, full reference, `az://` samplesheet) to the private `aletest` container for Azure Batch / Seqera runs | `data/ottilie/` → `aledata/aletest` (PRIVATE) |

### ⚠️ Public vs private targets

`publish_test_data.sh` and `upload_pilot_data.sh` are not the same thing and their targets must not
be conflated:

- `publish_test_data.sh` → **`aletestdatapublic/releases`** — PUBLIC, no SAS. The 2-sample
  chr-subset **test** set.
- `upload_pilot_data.sh` → **`aledata/aletest`** — PRIVATE. The 4-sample full-depth **pilot** set.

Both sets are public-SRA-derived (PRJNA590203), so neither is sensitive — but the public account
exists only so a fresh machine can fetch the release test set with no credentials; nothing else
belongs there. See [`../DATA_PROVENANCE.md`](../DATA_PROVENANCE.md) and
[`../blob_layout.md`](../blob_layout.md).
