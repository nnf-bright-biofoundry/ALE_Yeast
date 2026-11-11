# Ottilie Test Data — Provenance & Lineage

How the ottilie benchmark/test data is produced, from public SRA reads down to the
2-sample nf-test dataset. Every stage below has a tracked script; the large data
artifacts are gitignored (see [Storage & durability](#storage--durability)).

## Source

- **Publication:** Ottilie et al., *Commun Biol* 5:128 (2022) — https://doi.org/10.1038/s42003-022-03076-7
- **BioProject:** PRJNA590203 (363 yeast ALE runs)
- **Run table:** `data/ottilie/PRJNA590203_runinfo.csv` (all SRR accessions)
- **Test samples (2):**
  | Sample | SRR | Role |
  |--------|-----|------|
  | NODRUG-GM2 | SRR10985539 | parent (ancestral) |
  | CBR110-15-R3a | SRR10985585 | evolved |

## Strain background — ABC16-Green Monster (matters when reading SV calls)

The parent is **not** wild-type S288C. Ottilie et al. used the **ABC16-Green Monster**, in which
**16 ABC transporters are replaced by a GFP cassette** (built by the Green Monster process,
Suzuki et al. 2011, *Nat Methods*) — the drug-efflux pumps are deleted so compounds work at lower
concentrations. Consequences for this dataset, verified from the pipeline's own output (2026-09-02):

- **Most Manta calls are engineered background, not ALE mutations.** They form a star of breakends
  anchored in a ~250 bp window at the 3' end of **ADH1** (XV:159,548–160,594, minus strand — so the
  anchors sit at the *terminator*), whose far ends land on the 5' ends of deleted transporters:
  BPT1 −39, PDR5 −106, ADP1 +29, PDR11 +104, NFT1 −5, PDR10 −103, YOR1 −73, PDR18 −6, VMR1 +14,
  PDR15 −40, AUS1 −35 bp — **11 of 11**. CNVKit independently shows those loci depleted
  (SNQ2 ≈ 0.07, PDR10 ≈ 0.14 fold change) because the genes are physically gone.
- **The junction inserts are deletion-collection barcodes.** `SVINSSEQ` across junctions shares an
  86 bp prefix and 18 bp suffix around a 20 bp variable middle; reverse-complementing gives the
  canonical **U1 `GATGTCCACGAGGTCTCT`** and **U2 `CGTACGCTGCAGGTCGAC`** primers (Winzeler et al.
  1999, U1-UPTAG-U2), plus a polylinker (XhoI, BglII, AscI, PacI, SmaI, BamHI, SalI, PstI). The
  20-mers are the per-gene UPTAG barcodes. So the cassette carries **ADH1 terminator** sequence,
  which is why junction reads map to the genomic ADH1 locus.
- **The paper reports no SVs** (SNVs/indels + 24 CNVs only), so there is no published truth set for
  these breakends — they are validated only by the internal evidence above.

Practical rule: treat the ADH1-anchored breakend star as expected background; compare evolved vs
parent columns, never absolute counts. The pipeline does **no** parent subtraction for SVs. This is
also why per-sample Manta misreports background as clone-specific — see
[`manta_calling_modes.md`](../../variant-calling/manta/manta_calling_modes.md).

## Truth set (must stay detectable through any subsampling)

- **CNV:** Chr I whole-chromosome duplication (cn=3, log2≈0.329) in CBR110-15-R3a
- **SNVs (4):**
  | Position | Change | Gene |
  |----------|--------|------|
  | IV:205738 | C>A | RPO21 |
  | IV:1184212 | G>T | TRR1 |
  | VII:233903 | G>A | ROG1 |
  | XV:639861 | G>T | YRR1 |

## Lineage

```
BioProject PRJNA590203
  │  PRJNA590203_runinfo.csv  (+ resolve_sra_accessions.py: sample ↔ SRR)
  ▼
[1] download_all_fastq.sh ──────────────► data/ottilie/fastq/     (full FASTQs, ~90 samples)
    (SRA fetch, batched)             └───► Azure Blob             (off-machine archive)
  │
  ▼
[2] run_ottilie_pilot.sh (--save_mapped) ► output_ottilie/preprocessing/markduplicates/*.cram
    (full pipeline run, 4 pilot samples)   (aligned CRAMs — 4 samples incl. the 2 test samples)
  │
  ▼
[3] generate_test_data.sh ──────────────► data/ottilie/fastq_test/     (chr I/IV/VII/XV subset)
    (chr-subset extraction)          └───► data/ottilie/samplesheet_test.csv   (auto-written)
  │
  ▼
[4] conf/test/ottilie_test.config  +  tests/ottilie_e2e.nf.test   (the nf-test)
```

## Stages

### [1] Download raw FASTQs — `01_data_retrieval/fastq/download_all_fastq.sh`
Reads SRR accessions from `PRJNA590203_runinfo.csv`, downloads from SRA in batches
(`prefetch`/`fasterq-dump`), and **uploads each batch to Azure Blob** (keeps local disk
under control). Sample↔SRR mapping via `resolve_sra_accessions.py`. Subset variants:
`download_pilot_fastq.sh`, `download_tier2_fastq.sh`, `download_tier2_from_blob.sh`.
- Output: `data/ottilie/fastq/` (full FASTQs) — gitignored; archived to Azure Blob.

### [2] Full pipeline run → CRAMs — `03_pipeline/run_ottilie_pilot.sh`
Runs the ALE pipeline on the 4 pilot samples (`samplesheet_pilot.csv`) with `--save_mapped`,
which publishes the aligned/dedup CRAMs. This is what produced `output_ottilie/`.
Canonical command (from `run_ottilie_pilot.sh`):
```bash
nextflow run main.nf -profile azureD4as,docker \
  -w work_ottilie \
  --input data/ottilie/samplesheet_pilot.csv \
  --outdir output_ottilie \
  --genome null --igenomes_ignore \
  --fasta data/ottilie/S288C_reference/S288C_R64.fa \
  --chr_dir data/ottilie/S288C_reference/chromosomes \
  --genbank data/ottilie/S288C_reference/S288C_R64_ensembl_chrnames.gb \
  --snpeff_db R64-1-1.105 --snpeff_cache data/ottilie/S288C_reference/snpeff_cache \
  --skip_tools baserecalibrator \
  --tools snpeff,cnvkit,tiddit,manta,controlfreec,haplotypecaller \
  --split_fastq 0 --joint_germline --save_mapped \
  --split_haplotypecaller_joint_vcf --hard_filter_haplotypecaller_joint \
  -resume
```
- Output: `output_ottilie/preprocessing/markduplicates/{CBR110-15-R3a,Carmaphycin-R9-2,Doxorubicin16-R2b,NODRUG-GM2}/*.md.cram` — gitignored.
- The 2 test samples' CRAMs (CBR110-15-R3a ~245 MB, NODRUG-GM2 ~218 MB) are the fast-path input for stage [3].

### [3] Generate test dataset — `01_data_retrieval/release/generate_test_data.sh`
Extracts reads on chromosomes I/IV/VII/XV for the 2 test samples and subsets the
S288C reference to match. Two modes:
- `--from-cram` (default): extract from the stage-[2] CRAMs (fast; needs `output_ottilie/`).
- `--from-sra`: fully reproducible — download from SRA → align → extract (no local deps).
- Fallback: if the CRAMs are gone but the full FASTQs (`data/ottilie/fastq/`) are present, it realigns from those.
- **Also writes** `data/ottilie/samplesheet_test.csv` with `$REPO_ROOT`-based absolute paths
  (machine-portable; regenerate on any machine — never copy the CSV between machines).
- Outputs (gitignored): `data/ottilie/fastq_test/` (~356 MB), `data/ottilie/S288C_reference_test/`, `data/ottilie/samplesheet_test.csv`.

### [4] nf-test — `conf/test/ottilie_test.config` + `tests/ottilie_e2e.nf.test`
The `ottilie_test` profile points at the stage-[3] outputs. Run:
```bash
nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test
```

## Storage & durability

| Artifact | Location | Gitignored? | Off-machine backup |
|----------|----------|-------------|--------------------|
| Full FASTQs (~90 samples) | `data/ottilie/fastq/` | yes | ✅ Azure Blob (via `download_all_fastq.sh`) |
| Pilot CRAMs (4 samples) | `output_ottilie/…/markduplicates/` | yes | ❌ regenerable from FASTQs or SRA |
| Test FASTQs (2 samples, chr-subset) | `data/ottilie/fastq_test/` | yes | ✅ Azure Blob bundle ([`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh)); also regenerable via `generate_test_data.sh` |
| Reference (test subset) | `data/ottilie/S288C_reference_test/` | yes | ✅ Azure Blob bundle ([`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh)); also regenerable |
| Samplesheet | `data/ottilie/samplesheet_test.csv` | yes | ❌ written by [`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh) / `generate_test_data.sh` (machine-local paths) |
| **Pilot FASTQs (4 samples, full depth)** | `data/ottilie/fastq/SRR109855*` | yes | ✅ **private** blob `az://aletest/ottilie/v1/fastq_pilot_full/` (`upload_pilot_data.sh`) |
| **Reference (full genome)** | `data/ottilie/S288C_reference/` | yes | ✅ **private** blob `az://aletest/ottilie/v1/S288C_reference/` (`upload_pilot_data.sh`) |

📌 **Two ottilie datasets share the `az://aletest/ottilie/v1/` prefix** — the 2-sample chromosome
subset and the 4-sample full-depth pilot. They are not interchangeable, and only the first is
published publicly. Naming convention and how to tell them apart: [`blob_layout.md`](blob_layout.md).

**Ultimate source of truth:** SRA (PRJNA590203). Everything downstream is reproducible via
`--from-sra`. The raw FASTQs are additionally archived on Azure Blob. The CRAMs are the only
intermediate with no dedicated backup, but they are cheaply regenerated from the FASTQs (stage [2])
or SRA.

## Fetch on a new machine — Azure Blob (stable PUBLIC URL, no SAS)

To run the ottilie nf-test / pipeline on a **fresh checkout without regenerating the data**, download the
bundle tarball from the **public** blob URL — no credentials, no SAS. The script verifies the checksum and
writes the machine-correct samplesheet:

```bash
bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/download_test_data.sh
# → data/ottilie/{fastq_test, S288C_reference_test, S288C_reference/S288C_R64.gff3} + samplesheet_test.csv
```

**Per-machine samplesheet (important for multi-VM deploy):** `data/ottilie/samplesheet_test.csv` (used by
the local `ottilie_test` profile) contains *machine-specific absolute* FASTQ paths and is gitignored.
[`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh) (and `generate_test_data.sh`) **rewrite it with the current machine's paths** from
`$OUT` — so it auto-adapts on each host. Never copy or hand-edit this CSV between machines; just re-run the
script. This is **local-only**; the blob-URL variant (`samplesheet_test_blob.csv`, below) is separate and
used only for Seqera/streaming — the two samplesheets are not interchangeable.

The data is published in **BOTH shapes** under a **versioned prefix** so each consumer picks the right one:

**Base URL:** `https://aletestdatapublic.blob.core.windows.net/releases/ottilie/v1`
(account + public `releases` container provisioned by `infra/azure/`; see `infra/azure/README.md`)

| Object (under `…/ottilie/v1/`) | For | Notes |
|---|---|---|
| `README.md` | **anyone handed the URL** | sample↔FASTQ↔SRA mapping, the truth set, and the reference-pairing rule. Ships inside the bundle too. Source: `01_data_retrieval/release/bundle_README.md` |
| `ottilie_test_data.tar.gz` | **local onboarding + CI** (download-then-run) | one atomic ~399 MB bundle; [`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh) uses this. Carries **both** references + `README.md` |
| `files/**` | **Seqera/Batch** per-file URL staging | mirrors `data/ottilie/` — fastq_test, S288C_reference_test, **and the full S288C_reference** (fa, gb, gff3, chromosomes/, snpeff_cache/) |
| `snpeff_cache.tar.gz` | Seqera + URL-streaming **fallback** | cache-only; untar → point `--snpeff_cache` at the `snpeff_cache/` dir. For a run on the pre-built reference files from https URLs; the streaming profile needed it until 2026-11 and now builds its database from the GenBank, see below |
| `SHA256SUMS`, `MD5SUMS` | integrity | same file set, generated from one list; each covers the individual files **and** both tarballs → proves they don't drift |
| `*.tar.gz.md5`, `files/fastq_test/*.fastq.gz.md5` | "did my download finish?" | per-file sidecars for the large objects. The FASTQ ones **also ship inside the bundle**, so `cd fastq_test && md5sum -c *.md5` re-verifies after extraction *and* after any later copy to cluster scratch — a root manifest cannot, once files have moved. ⚠️ Deliberately **absent inside `chromosomes/` and `snpeff_cache/`**: those stage as *directory* params, so stray files would be staged with the data |
| `samplesheet_test_blob.csv` | Seqera + URL-streaming | samplesheet whose `fastq_1/2` are the public per-file URLs |

⚠️ **`ottilie/v1` is a ROLLING prefix, updated in place** — re-running `publish_test_data.sh`
republishes it and every consumer picks the change up with no repointing. Additive changes (new
files, a bigger bundle) are safe; **removing or renaming** a published file is not, and needs a
prefix bump. Note the tarball's hash changes whenever the bundled set does.

**Both references are published**, so the same download serves the 2-sample test and the 4-sample
SRA set. ⚠️ Reads set a *minimum* reference: bigger is always allowed, smaller never is — 4-sample
reads against the slimmed 4-chromosome reference **mismap** rather than fail. See `bundle_README.md`.

Content is PRJNA590203 (public SRA) + public S288C reference/annotation → **safe to be world-readable**; the
URL is public **for zero-credential access (no expiring SAS to distribute/rotate)**, not because the data is
open by necessity. The individual `files/**` tree also backs the URL-streaming profile below.

### Run with zero local data — the `ottilie_test_ci` streaming profile

```bash
bash bin/test_ottilie_blob.sh        # == -profile ottilie_test_ci,azureD4as,docker
```

Same 2 samples / 4 chromosomes / same tools as `ottilie_test`, but `input` and `genbank` are the public
`files/**` URLs. Nextflow stages each into the task work dir, so nothing lands in `data/ottilie/`.

**The reference is one file since 2026-11.** The profile gives the test GenBank
(`files/S288C_reference_test/S288C_R64_test.gb`, the same file as the local one by `SHA256SUMS`) and the
run builds the FASTA, the snpEff database and the gene track from it, so the launcher is the launch
command and nothing else. Re-host the whole set with `OTTILIE_BLOB_BASE=…`.

**Before that, `snpeff_cache` was the one exception**, and it still is for a run on the pre-built files:
it is a *directory* param, the pipeline validates it with `file(...).isDirectory()` and stages the whole tree
([`annotation_cache_initialisation/main.nf`](../../../subworkflows/local/annotation_cache_initialisation/main.nf)),
and Nextflow's http provider has no directory listing, so an https "directory" URL can neither be validated
nor walked. (`az://` works but needs credentials.) `snpeff_cache.tar.gz` is published for that case: fetch it,
check it against `SHA256SUMS`, untar it and pass the local directory as `--snpeff_cache` with
`--snpeff_db R64-1-1.105`, `--fasta` and `--report_gff3` (and `--genbank null`, since the profile names one).

`chr_dir` (Control-FREEC) is a directory param too and is set to `null` in the streaming profile —
Control-FREEC is not in this test's `tools`, so nothing is lost. Adding it later would need the same
tarball treatment (`prepare_genome` already accepts a `.tar.gz` for `chr_dir`).

#### Local storage: streaming still writes to disk

Nextflow does not stream a remote file into a task — it downloads it **once per session** into
`<workdir>/stage-<session-uuid>/` and symlinks that copy into every task dir. So the inputs still land
locally; they just live **inside the work dir** instead of `data/ottilie/`. Measured on this test:

| | local `ottilie_test` | streaming `ottilie_test_ci` |
|---|---|---|
| persistent input data | `data/ottilie/` **402 MB** (symlinked into tasks, never copied) | none since 2026-11 (when measured: `.ottilie_ci_cache/` **23 MB**, the SnpEff cache) |
| staged copies in work dir | 0 | `stage-*/` **366 MB** (4 FASTQ + FASTA + GFF3) |
| task work dir | ~7.6 GB | ~7.6 GB |
| published outputs | 216 MB | 216 MB |

Net footprint is within ~15 MB of each other — the point is *where* it lives, not how much. Two
cleanup consequences, both verified:

- **`nextflow clean` does not touch `stage-*` dirs.** It deletes task hash dirs from the cache DB;
  the stage dir isn't one, so the 366 MB survives. Clean up with `rm -rf work_ottilie_test_blob`,
  which reclaims staged inputs and task dirs together.
- **A run without `-resume` re-downloads into a *second* `stage-<uuid>/`.** The session UUID names the
  dir, so a fresh session in the same work dir adds another full copy rather than reusing the first.
  `bin/test_ottilie_blob.sh` always passes `-resume`; keep it if you edit the launcher.

Only files a process actually consumes are fetched — e.g. `genbank` is set but breseq isn't in `tools`,
so the `.gb` is never downloaded.

### Publish — maintainer runbook (`publish_test_data.sh`)

**Provisioning is owned by `infra/azure/`** — the storage account (`aletestdatapublic`, denmarkeast) and the
public `releases` container (`publicAccess: blob`) are created once by the ARM template via
`infra/azure/deploy.sh` (see `infra/azure/README.md`). `publish_test_data.sh` only **uploads content** — it
never creates or re-permissions the container, so it can't alter the deployed public-access level.

Run from the repo root on a machine with `data/ottilie/` populated and `az login` done. It builds the
tarball + cache-tar + `SHA256SUMS` + URL-samplesheet, uploads both shapes under `ottilie/v1/`, and verifies
the public GET:

```bash
bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/publish_test_data.sh
```

Overrides: `ACCOUNT` (default `aletestdatapublic`), `CONTAINER` (default `releases`), `PREFIX` (default
`ottilie/v1` — bump to `ottilie/v2` for a new version), `AUTH` (`key` default = shared-key, needs no
data-plane RBAC; `login` = AAD). Uploads use shared-key auth, which works with control-plane access given
the account's `allowSharedKeyAccess: true`. If org policy ever forbids public access, re-provision the
container as `None` and fall back to a read-only SAS (consumers then need `BLOB_BASE` + the token).

**Scope:** local-FS download-then-run (turnkey multi-server deploy), Seqera/Batch per-file staging, **and**
the `ottilie_test_ci` URL-streaming profile — all off the same public blobs. Wiring that profile into
GitHub Actions remains post-v1.0.0. See Notes.

> **`gh` Release Assets considered, not adopted (2026-07-22):** clean for CI (built-in token) but the repo
> is **private** (no unauthenticated URL), assets are flat (breaks per-file streaming / the snpeff_cache
> tree), and a GitHub→Azure pull isn't same-region for the Seqera target. Public blob wins for the
> Seqera-first path. Revisit only as a smoke-tier CI tarball later.

## Notes / TODO

- **CI/cloud (post-v1.0.0):** GitHub Actions / Seqera Cloud can't use these local paths (data
  gitignored; two files >100 MB). Needs a blob-URL samplesheet variant + hosted data. See the
  v1.0.0 plan's "CI / cloud portability" task.
  - **Decision:** host the current 356 MB `fastq_test/` on blob (do NOT shrink) — keeps the
    validated truth set, zero empty-output risk. Intra-Azure streaming is fast.
  - ✅ **Public no-SAS blob, both shapes (v1.0.0):** `publish_test_data.sh` emits a tarball (local/CI) +
    an individual `files/**` tree (Seqera per-file staging) + a cache-only tarball (snpeff_cache fallback)
    under a versioned `ottilie/v1/` prefix; [`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh) curls the tarball (no creds).
    See "Fetch on a new machine" above.
  - ✅ **URL-streaming profile:** `ottilie_test_ci` + `bin/test_ottilie_blob.sh` run the test off the
    `files/**` per-file URLs with no local data (snpeff cache staged from `snpeff_cache.tar.gz` —
    see "Run with zero local data" above). Wiring it into GitHub Actions is the remaining post-1.0.0 bit.
- **CI-tier dataset (post-v1.0.0):** 356 MB is large for per-run CI. A `generate_ci_test_data.sh`
  doing chr-subset **+ calibrated read-subsampling with a truth-set validation gate** (assert the
  4 SNVs + chr I dup remain detectable) would give a fast CI dataset. SNV depth is the binding
  constraint — subsample only as far as the truth SNVs stay callable.
