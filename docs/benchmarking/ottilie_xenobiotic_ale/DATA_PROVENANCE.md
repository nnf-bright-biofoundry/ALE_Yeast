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

These five events are everything the paper reports for CBR110-15-R3a (Sup Data 4 and 5,
`data/ottilie/pilot_truth_set.csv`); the parent has none. They are why the test set keeps
chromosomes I, IV, VII and XV.

- **CNV:** Chr I whole-chromosome duplication (cn=3, log2≈0.329) in CBR110-15-R3a
- **SNVs (4):**
  | Position | Change | Gene |
  |----------|--------|------|
  | IV:205738 | C>A | RPO21 |
  | IV:1184212 | G>T | TRR1 |
  | VII:233903 | G>A | ROG1 |
  | XV:639861 | G>T | YRR1 |

**The SV floor is the binding constraint on depth, not the SNVs.** The paper reports no SVs, so
this floor is internal evidence: ten joint-Manta records that both samples must carry, eight of
them the strain's cassette junctions (see the strain section above), listed in
[`test_set_sv_floor.tsv`](01_data_retrieval/release/test_set_sv_floor.tsv). Measured 2026-11-11 on
four cuts of the same alignment, each run through the pipeline
(`generate_test_data.sh` with `OUT_ROOT` and `FRACTION_*`, then `check_test_data_truth.py`; the
candidate outputs were throwaway, the numbers are from their joint Manta VCFs and traces):

| Cut (parent / evolved, nuclear depth) | Fractions | FASTQ | Nuclear Manta events ¹ | Evolved genotyped PASS, non-ref | Parent | 4 SNVs + chr I gain | Run ² |
|---|---|---|---|---|---|---|---|
| 20x / 20x | 0.45 / 0.22 | about 135 MB | 9 | 4 | 9 | yes | 6.3 min |
| 30x / 30x | 0.67 / 0.34 | 199 MB | 10 | 5 | 10 | yes | 7.1 min |
| 30x / 45x | 0.67 / 0.50 | 238 MB | 11 | 10 | 10 | yes | 7.7 min |
| **30x / 60x (published as v2)** | **0.67 / 0.67** | **267 MB** | **11** | **11** | **10** | **yes** | **8.0 min** |
| v1, for reference: 43x / 85x, no Mito | 1 / 1 | 370 MB | 11 | 10 | 11 | yes | 9.2 to 9.5 min ³ |

¹ A breakend pair counts once; Mito records left out. ² 157 tasks, first submission to last task end,
`-profile ottilie_test,azureD4as,docker` on the 4-vCPU dev VM. ³ From earlier comparable runs
(2026-11-09 and 2026-11-11), not re-measured with the others.

The SNVs (allele fraction 1) and the chromosome gain hold at every depth tried. The junctions do
not: the evolved clone's library yields about a third of the parent's junction-spanning pairs per
unit depth (10 against 25 reference-supporting pairs at 30x), so at 30x joint Manta genotypes the
evolved clone hom-ref at five of the ten events and the SV cohort table would show engineered
junctions as present in the parent only. That is why the evolved sample is kept at twice the
parent's depth (user decision 2026-11-11, replacing "30x for both" of 2026-11-02). The one event
the parent misses in the published cut, a 135 bp deletion at I:206105, is not a cassette junction
and is not in the floor.

## Lineage

```
BioProject PRJNA590203
  │  PRJNA590203_runinfo.csv  (+ resolve_sra_accessions.py: sample ↔ SRR)
  ▼
[1] download_all_fastq.sh ──────────────► data/ottilie/fastq/     (full FASTQs, ~90 samples)
    (SRA fetch, batched)             └───► Azure Blob             (off-machine archive)
  │
  ▼
[2] run_ottilie_pilot.sh ───────────────► the 4-sample pilot benchmark (not an input of the test set
    (full pipeline run, 4 pilot samples)   since v2; v1 was cut from this run's CRAMs)

    data/ottilie/fastq/ (the two test samples' SRA FASTQs)
  │
  ▼
[3] generate_test_data.sh ──────────────► data/ottilie/fastq_test/     (I/IV/VII/XV/Mito, 0.67 of the pairs)
    (align, keep 5 contigs, seeded cut) ├─► data/ottilie/S288C_reference_test/  (the same 5 contigs)
                                        └─► data/ottilie/samplesheet_test.csv   (auto-written)
  │
  ▼
[3b] pipeline run + check_test_data_truth.py ► fastq_test/TRUTH_GATE.txt  (required to publish)
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
Canonical command, as run in 2026 (from `run_ottilie_pilot.sh` of that time; a record, not a recipe:
since 2026-11-09 `--genbank` together with `--fasta` is a start-up error, and the script no longer passes it):
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
- Until test data v2 the 2 test samples' CRAMs were the input of stage [3]. They no longer are:
  the pipeline's CRAMs hold trimmed reads since 2026-09-04, and a test set cut from one would be
  trimmed before the pipeline sees it.

### [3] Generate test dataset — `01_data_retrieval/release/generate_test_data.sh`
Version 2 of the set (2026-11-11). One route, from the SRA FASTQs of the two samples
(`data/ottilie/fastq/SRR10985539_*`, `SRR10985585_*`):

1. **Align** each sample to the full 17-contig reference (bwa-mem2 2.2.1, `-K 100000000` so the
   result does not depend on the thread count) and keep the pairs with **both mates mapped to
   I, IV, VII, XV or Mito**. Pairs with a mate unmapped or on another contig are dropped (in the published
   cut 16,496 reads of the parent and 1,532 of the evolved clone lose their mate this way and are
   discarded); secondary and supplementary
   records are not written to FASTQ; duplicates and QC-fail reads are kept. This alignment only
   selects reads: the FASTQs hold them as sequenced, untrimmed.
2. **Subsample pairs** with `samtools view -s 42.67`: seed 42, fraction 0.67 of the read names, so
   a pair is kept or dropped as a whole. The same fraction for both samples: 717,457 pairs for
   NODRUG-GM2 and 1,288,606 for CBR110-15-R3a.
3. **Subset the reference** to the same five contigs: FASTA, `.fai`, `.dict`, the GenBank records
   (LOCUS I, IV, VII, XV, Mito; the Mito record carries `/organelle="mitochondrion"` and 19 CDS
   with `/transl_table=3`), `chromosomes/`, and a whole copy of the full genome's pre-built snpEff
   database (17 contigs, with the mitochondrial `codonTable` line).

Depth of the published cut, as the pipeline measures it after trimming (mosdepth, run of
2026-11-11): parent 28.7x on each nuclear chromosome and 299x on Mito; evolved 55.6x to 57.6x on
IV, VII, XV, 78.0x on chr I (the gain) and 126x on Mito. Before the cut the kept pairs gave 44.5x
and 89.6x on the nuclear chromosomes (`samtools coverage`).

- Every samtools and bwa-mem2 step runs in one pinned public image
  (`community.wave.seqera.io/library/bwa-mem2_htslib_samtools:e1f420694f8e42bd`), so the cut needs
  docker and nothing from a conda environment. Rerunning the script reproduces the published
  FASTQs byte for byte (checked 2026-11-11: two cuts, same md5s).
- `fastq_test/CUT_PARAMETERS.tsv` records seed, fractions, pair counts, md5s and the image; the
  FASTQ names carry seed and fraction (`<sample>_chrI_IV_VII_XV_Mito_seed42_frac0.67_R1.fastq.gz`).
- `--align-only` stops after step 1 and prints the depth per contig, for choosing fractions;
  `OUT_ROOT`, `SEED`, `FRACTION_PARENT`, `FRACTION_EVOLVED` cut a candidate set elsewhere. The
  region BAMs stay in `.ottilie_test_build/` so a recut takes a minute.
- **Also writes** `data/ottilie/samplesheet_test.csv` with `$REPO_ROOT`-based absolute paths
  (machine-portable; regenerate on any machine — never copy the CSV between machines).
- Outputs (gitignored): `data/ottilie/fastq_test/` (267 MB), `data/ottilie/S288C_reference_test/`
  (41 MB), `data/ottilie/samplesheet_test.csv`.

**[3b] The truth gate.** Run the pipeline on the cut, then
`python 01_data_retrieval/release/check_test_data_truth.py <outdir>`. It checks that the run read
exactly these FASTQs (md5s and fastp's read counts), the four SNVs (PASS, evolved only), the chr I
gain in the CNVKit and TIDDIT tables with every other nuclear contig neutral, the ten SV floor
records (PASS, non-reference in both samples) and the Mito row of the contig manifest, and writes
`fastq_test/TRUTH_GATE.txt`. `publish_test_data.sh` and `08_upload_test_data.sh` refuse a
`fastq_test/` without that stamp, or with one written for other FASTQs. A new cut deletes the stamp.

**Version 1** (2026-07 to 2026-11, still published under `ottilie/v1`, read by the `v1.1.0` tag):
every pair on I, IV, VII, XV extracted from the CRAMs of an untrimmed pilot run, at full depth
(43x / 85x), no Mito, snpEff databases without the mitochondrial genetic code.

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
| Test FASTQs (2 samples, 5 contigs, 0.67 of the pairs) | `data/ottilie/fastq_test/` | yes | ✅ Azure Blob bundle ([`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh)); also regenerable via `generate_test_data.sh` |
| Reference (test subset) | `data/ottilie/S288C_reference_test/` | yes | ✅ Azure Blob bundle ([`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh)); also regenerable |
| Samplesheet | `data/ottilie/samplesheet_test.csv` | yes | ❌ written by [`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh) / `generate_test_data.sh` (machine-local paths) |
| **Pilot FASTQs (4 samples, full depth)** | `data/ottilie/fastq/SRR109855*` | yes | ✅ **private** blob `az://aletest/ottilie/v2/fastq_pilot_full/` (`upload_pilot_data.sh`; the same files as under `v1`) |
| **Reference (full genome)** | `data/ottilie/S288C_reference/` | yes | ✅ **private** blob `az://aletest/ottilie/v2/S288C_reference/` (`upload_pilot_data.sh`) |

📌 **Two ottilie datasets share the `az://aletest/ottilie/v2/` prefix** — the 2-sample chromosome
subset and the 4-sample full-depth pilot. They are not interchangeable, and only the first is
published publicly. Naming convention and how to tell them apart: [`blob_layout.md`](blob_layout.md).

**Ultimate source of truth:** SRA (PRJNA590203). The test set is reproducible from the two runs'
FASTQs with `generate_test_data.sh`. The raw FASTQs are additionally archived on Azure Blob.

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

**Base URL:** `https://aletestdatapublic.blob.core.windows.net/releases/ottilie/v2`
(account + public `releases` container provisioned by `infra/azure/`; see `infra/azure/README.md`)

| Object (under `…/ottilie/v2/`) | For | Notes |
|---|---|---|
| `README.md` | **anyone handed the URL** | sample↔FASTQ↔SRA mapping, the truth set, and the reference-pairing rule. Ships inside the bundle too. Source: `01_data_retrieval/release/bundle_README.md` |
| `ottilie_test_data.tar.gz` | **local onboarding + CI** (download-then-run) | one atomic ~325 MB bundle; [`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh) uses this. Carries **both** references + `README.md` |
| `files/**` | **Seqera/Batch** per-file URL staging | mirrors `data/ottilie/` — fastq_test, S288C_reference_test, **and the full S288C_reference** (fa, gb, gff3, chromosomes/, snpeff_cache/) |
| `snpeff_cache.tar.gz` | Seqera + URL-streaming **fallback** | cache-only; untar → point `--snpeff_cache` at the `snpeff_cache/` dir. For a run on the pre-built reference files from https URLs; the streaming profile needed it until 2026-11 and now builds its database from the GenBank, see below |
| `SHA256SUMS`, `MD5SUMS` | integrity | same file set, generated from one list; each covers the individual files **and** both tarballs → proves they don't drift |
| `*.tar.gz.md5`, `files/fastq_test/*.fastq.gz.md5` | "did my download finish?" | per-file sidecars for the large objects. The FASTQ ones **also ship inside the bundle**, so `cd fastq_test && md5sum -c *.md5` re-verifies after extraction *and* after any later copy to cluster scratch — a root manifest cannot, once files have moved. ⚠️ Deliberately **absent inside `chromosomes/` and `snpeff_cache/`**: those stage as *directory* params, so stray files would be staged with the data |
| `samplesheet_test_blob.csv` | Seqera + URL-streaming | samplesheet whose `fastq_1/2` are the public per-file URLs |

⚠️ **`ottilie/v2` is a ROLLING prefix, updated in place** — re-running `publish_test_data.sh`
republishes it and every consumer picks the change up with no repointing. Additive changes (new
files, a bigger bundle) are safe; **removing or renaming** a published file, or changing the
content of one, is not, and needs a prefix bump. Note the tarball's hash changes whenever the
bundled set does.

**`ottilie/v1` is frozen** on both accounts since 2026-11-11: the `v1.1.0` tag, its Launchpad
version and every baseline cut before that date read it. The three upload scripts refuse to write
there. What differs: v1 holds full-depth reads cut from untrimmed CRAMs, four contigs, and snpEff
databases without the mitochondrial `codonTable` line.

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

Same 2 samples / 5 contigs / same tools as `ottilie_test`, but `input` and `genbank` are the public
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
locally; they just live **inside the work dir** instead of `data/ottilie/`. Measured on this test
with the v1 data (2026-07). With v2 the staged copies are 278 MB (measured 2026-11-11, a run of
`ottilie_test_ci` on the public `ottilie/v2`: 157 tasks, 8.2 min, the eleven report tables and the cohort
VCF records identical to the contract test's output):

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

Only files a process actually consumes are fetched. Since 2026-11-11 the `.gb` is one of them: the profile's
reference is the test GenBank, which the two reference tasks read before alignment.

### Publish — maintainer runbook (`publish_test_data.sh`)

**Provisioning is owned by `infra/azure/`** — the storage account (`aletestdatapublic`, denmarkeast) and the
public `releases` container (`publicAccess: blob`) are created once by the ARM template via
`infra/azure/deploy.sh` (see `infra/azure/README.md`). `publish_test_data.sh` only **uploads content** — it
never creates or re-permissions the container, so it can't alter the deployed public-access level.

Run from the repo root on a machine with `data/ottilie/` populated and `az login` done. It builds the
tarball + cache-tar + `SHA256SUMS` + URL-samplesheet, uploads both shapes under `ottilie/v2/`, and verifies
the public GET:

```bash
bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/publish_test_data.sh
```

Overrides: `ACCOUNT` (default `aletestdatapublic`), `CONTAINER` (default `releases`), `PREFIX` (default
`ottilie/v2` — bump to `ottilie/v3` for a new version; `ottilie/v1` is refused), `AUTH` (`key` default = shared-key, needs no
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
  - **Decision (v1.0.0, superseded by v2 on 2026-11-11):** host the 356 MB `fastq_test/` on blob
    unshrunk. Version 2 is smaller, and its cut passed the truth gate first.
  - ✅ **Public no-SAS blob, both shapes (v1.0.0):** `publish_test_data.sh` emits a tarball (local/CI) +
    an individual `files/**` tree (Seqera per-file staging) + a cache-only tarball (snpeff_cache fallback)
    under a versioned prefix (`ottilie/v1/` then, `ottilie/v2/` now); [`download_test_data.sh`](01_data_retrieval/release/download_test_data.sh) curls the tarball (no creds).
    See "Fetch on a new machine" above.
  - ✅ **URL-streaming profile:** `ottilie_test_ci` + `bin/test_ottilie_blob.sh` run the test off the
    `files/**` per-file URLs with no local data (snpeff cache staged from `snpeff_cache.tar.gz` —
    see "Run with zero local data" above). Wiring it into GitHub Actions is the remaining post-1.0.0 bit.
- **CI-tier dataset: done as test data v2 (2026-11-11).** The plan was a separate
  `generate_ci_test_data.sh` with calibrated subsampling and a truth gate, on the assumption that
  SNV depth would be the binding constraint. It became the one test set for local runs and CI, and
  the measurement showed the SV junction calls bind first (table under *Truth set*).
