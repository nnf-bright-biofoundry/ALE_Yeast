# yAMP: yeast Automated Mutation Pipeline

A variant-calling pipeline for **Adaptive Laboratory Evolution (ALE)** experiments in microbial
genomes, forked from [nf-core/sarek 3.5.1](https://nf-co.re/sarek/3.5.1).

yAMP keeps Sarek's GATK4 best-practice preprocessing and adds ALE-specific calling: joint-germline
HaplotypeCaller with per-sample ploidy, CNV/SV calling with cohort matrices, SnpEff annotation from a
custom cache, and an integrated igv-reports mutation dashboard.

📖 **Full documentation index: [`docs/README.md`](docs/README.md)** ·
📋 [`CHANGELOG.md`](CHANGELOG.md) ·
🔀 [Changes vs upstream Sarek](docs/dev-practices/SAREK_MODIFICATIONS.md)

---

## Requirements

- **Linux x86_64.** Apple Silicon (ARM) is **not supported**: GATK/MultiQC tasks stall or fail.
  Development and validation run on an Azure D4as_v5 VM (4 vCPU / 16 GB).
- **Docker**: [install](https://docs.docker.com/engine/install/).
- **Nextflow 25.10.x**, plus the pipeline's dev toolchain. ⚠️ **Do not `conda install nextflow`
  unpinned**: that installs the latest release (26.x), which **cannot parse this config**. Use:
  ```bash
  conda env create -f environment.yml && conda activate nf-env
  ```
  The env also installs **`nf-test` 0.9.3**, which runs the contract test that verifies an install
  (see [Testing](#testing)). The launch scripts then `export NXF_VER=25.10.4`, which makes Nextflow self-fetch that exact
  engine on first run (so the first launch needs network access). Why 26.x is blocked:
  [`ale_sarek_upgrade_runbook.md`](docs/dev-practices/ale_sarek_upgrade_runbook.md).
- **Disk**: ~10 GB for the test run (≈400 MB test data + ~8 GB work dir + ~200 MB output).

Setting up a machine from scratch: [`docs/usage/new_machine_setup.md`](docs/usage/new_machine_setup.md).

## Quick start

```bash
git clone https://github.com/nnf-bright-biofoundry/ALE_Yeast.git
cd ALE_Yeast

# fetch the 2-sample test dataset from public blob storage (no credentials needed)
bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/download_test_data.sh
```

**Step 1: tell the pipeline how big your machine is.** `conf/base.config` sizes every task for the
cloud target (4 vCPU / 32 GB), so on a smaller machine tasks would request more RAM than exists and
never get scheduled. Copy the template and edit two numbers:

```bash
cp conf/mymachine.config conf/$(hostname).config
# then set:  cpus = <your vCPUs>,  memory = '<RAM minus ~2 GB>.GB'
```

**Step 2: run it.**

```bash
export NXF_VER=25.10.4
nextflow -c conf/$(hostname).config run main.nf -profile ottilie_test,docker \
    --outdir ./output_ottilie_test --generate_reports
```

Results land in `output_ottilie_test/`; open `output_ottilie_test/mutation_reports/index.html`.

> On the **16 GB Azure dev VM** there is a shortcut: a registered profile plus a launcher that pins
> the Nextflow version for you:
> ```bash
> bash bin/test_ottilie.sh     # == -profile ottilie_test,azureD4as,docker
> ```
> `azureD4as` hard-codes that VM's ceilings and per-task tuning, so **don't use it on other
> hardware**. Use your own `-c` file as above.

> **No-download variant.** `bash bin/test_ottilie_blob.sh` (`-profile ottilie_test_ci`) runs the same
> test with the samplesheet and every reference file read straight from the public blob URLs, so you can
> skip the `download_test_data.sh` step above. The SnpEff cache is the one exception: it is a
> *directory* param and cannot be streamed from an https URL, so the script fetches and untars the
> published `snpeff_cache.tar.gz` (~10 MB download, 23 MB unpacked, once) into `.ottilie_ci_cache/`.
> On a machine or cloud with no such pre-step (a Seqera Launchpad, AWS Batch, an HPC), put the
> unpacked `R64-1-1.105/` directory in your own bucket and pass `--snpeff_cache <bucket path>`; see
> [Running the SnpEff cache from cloud storage](#running-the-snpeff-cache-from-cloud-storage).
>
> This doesn't reduce disk use: Nextflow copies each remote file once into
> `<workdir>/stage-<session-uuid>/`, so the ~366 MB of inputs lands in the work dir instead of
> `data/ottilie/`. Clean up with `rm -rf work_ottilie_test_blob`; `nextflow clean` leaves `stage-*` behind.

### The test dataset

2 samples (parent `NODRUG-GM2` + evolved `CBR110-15-R3a`) from *S. cerevisiae* S288C, subset to
4 chromosomes (I, IV, VII, XV). Truth set: **4 SNVs + a chr I whole-chromosome duplication**
(Ottilie et al., *Commun Biol* 5:128, 2022). The data lives under `data/ottilie/` (gitignored) and is
described in
[`docs/benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md`](docs/benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md).

The profile is `conf/test/ottilie_test.config`, and the same run is the pipeline's automated contract
test (`tests/ottilie_e2e.nf.test`).

## Running your own data

### Where to put it: run from your own directory, not the repo

Nextflow doesn't need to be launched from the pipeline directory. Keep each project in its own
folder and point at `main.nf` by path:

```
~/projects/myproject/
├── data/              # FASTQs (or leave them wherever they already are)
├── ref/               # FASTA + GFF3 + SnpEff cache (docs/usage/prepare_reference.md)
├── samplesheet.csv    # ABSOLUTE paths to the FASTQs
├── run.sh
├── work/              # created here, not in the repo
└── output/
```

```bash
cd ~/projects/myproject
export NXF_VER=25.10.4
nextflow -c /path/to/ALE_Yeast/conf/$(hostname).config \
    run /path/to/ALE_Yeast/main.nf -profile docker \
    --input samplesheet.csv --outdir ./output   # …plus the params in "Launch" below
```

`work/` and outputs land in the project folder, so `git status` on the pipeline stays clean, a
finished project is one `rm -rf`, and `git pull` never touches your data.

Use the in-repo layout (`data/<name>/`, a launcher in `bin/`) only for things that should ship *with*
the pipeline, such as a shared benchmark or test set like `data/ottilie/`. Note `bin/` is not a general
script folder: Nextflow puts it on `PATH` inside every task container, and it is git-tracked.

> **Samplesheet paths must be absolute.** They're validated at launch (`exists: true`), and relative
> ones would resolve against whatever directory you happened to launch from. That makes the
> samplesheet machine-specific, so **generate it rather than hand-maintaining it** (`"$PWD"/data/…`),
> the same way `download_test_data.sh` regenerates the ottilie one per machine.

### Fitting the run to your machine

Same `-c` file as in the quick start. [`conf/mymachine.config`](conf/mymachine.config) is a
commented template; the load-bearing part is three lines:

```groovy
process {
    resourceLimits = [ cpus: 8, memory: '28.GB', time: '72.h' ]   // vCPUs, RAM − ~2 GB headroom
}
```

`resourceLimits` is a **clamp** applied after every other mechanism, including the retry escalation
`{ 16.GB * task.attempt }`, so it caps requests wherever they came from. That's why it's the one
setting you must get right; the rest is optional throughput tuning.

Notes:

- **It has to be a file.** `resourceLimits` cannot be set on the command line: `-process.` can't
  express a map, and there is no `--max_memory` param in this pipeline.
- **Give the scheduler a CPU budget of twice the clamp** (`executor { cpus = 8 }` for a 4-vCPU
  machine; the template carries it). It is a number for the scheduler's bookkeeping, not a hardware
  count: a task that asks for every CPU of the budget can be stranded, with nothing running and no
  error, when the scheduler loses one unit; see
  [`docs/usage/nextflow_local_executor_deadlock.md`](docs/usage/nextflow_local_executor_deadlock.md).
  Leave the memory budget to Nextflow (the machine's RAM); a hand-set pool that barely exceeds a
  single task's request deadlocks the same way.
- **Keep the file params-free.** `-c` outranks `-profile`, so any `params.*` in it will override the
  profile's settings.

If you'll reuse a machine often, promote the file to a named profile
(`<machine> { includeConfig 'conf/<machine>.config' }` in `nextflow.config`); that's what
`azureD4as` is. Full precedence rules, both porting options, and the cloud story:
[`docs/dev-practices/compute_resources.md`](docs/dev-practices/compute_resources.md).

### Launch

```bash
nextflow -c conf/mymachine.config run main.nf -profile docker \
    --input samplesheet.csv --outdir ./output \
    --fasta ref.fasta --snpeff_cache ./snpeff_cache --snpeff_db <genome_name> \
    --report_gff3 ref.gff3 \
    --genome null --igenomes_ignore \
    --skip_tools baserecalibrator \
    --tools snpeff,haplotypecaller,cnvkit,manta,tiddit \
    --joint_germline --split_haplotypecaller_joint_vcf --joint_manta --generate_reports
```

`--skip_tools baserecalibrator` is **required**: BQSR needs known-sites VCFs, which custom microbial
references don't have. Omitting it aborts the run.

Rather than a long command line, put the parameters in a **params file**: copy
[`docs/usage/params_template.yml`](docs/usage/params_template.yml) (every launch-form field in
launch-form order, at the Tier-1 recipe values, plus the hidden ones a run needs), fill the six
dataset lines, and launch with `-params-file my_project.yml`, upload it in the Seqera launch form, or
pass it to `tw launch --params-file`. Precedence and traps:
[`docs/usage/launch_params_file.md`](docs/usage/launch_params_file.md).

**Look at the reads first.** Add `--qc_only` to the same command and the run stops after read QC
(FastQC raw and after trimming, fastp, MultiQC; about five minutes on the test set), prints where
the report is and the exact follow-up command: the same command without the flag plus
`-resume <session id>`, which continues from alignment with the QC tasks cached. What to check
before signing off: [`docs/usage/qc_first_run.md`](docs/usage/qc_first_run.md).

### Input samplesheet

| Column | Description |
|--------|-------------|
| `experiment` | Experiment ID (maps to Sarek's "patient"); groups samples for joint calling |
| `sample` | Sample ID in ALE format (e.g. `A1-F6-I1-R1`) |
| `clonal_or_population` | `clonal` for isolate sequencing, `population` for bulk/pooled |
| `ploidy` | `1` = haploid, `2` = diploid (higher supported) |
| `lane` | Sequencing lane (e.g. `L001`); multiple lanes per sample are merged |
| `fastq_1`, `fastq_2` | Paired-end FASTQ paths (absolute, or `az://` blob URLs) |

Two sarek columns, `status` and `sex`, are optional and best left out: the schema fills `status = 0`
(every ALE sample is normal, which is what makes HaplotypeCaller run joint-germline) and `sex = NA`
(read only by the Tier-2 Control-FREEC / ASCAT, inert otherwise).

```csv
experiment,sample,clonal_or_population,ploidy,lane,fastq_1,fastq_2
Ottilie_test,NODRUG-GM2,clonal,1,L001,/data/NODRUG-GM2_R1.fastq.gz,/data/NODRUG-GM2_R2.fastq.gz
Ottilie_test,CBR110-15-R3a,clonal,1,L001,/data/CBR110-15-R3a_R1.fastq.gz,/data/CBR110-15-R3a_R2.fastq.gz
```

Full column reference and conventions:
[`docs/usage/input_samplesheet.md`](docs/usage/input_samplesheet.md).

### Preparing a reference (GenBank, or FASTA + GFF3)

**One GenBank, no preparation (since 2026-11-09).** `--genbank genome.gb` (also `.gbk`, `.gbff`, gzipped) replaces
`--fasta`, `--snpeff_cache`, `--snpeff_db` and `--report_gff3`: the pipeline derives the FASTA, the SnpEff
database and the report's gene track from the file before alignment and publishes them under
`reference/<db>/` (`<db>` = the file's basename). Contig names are the LOCUS names. Giving both routes is a
start-up error. Not yet in the Seqera launch form; the user guide follows
([`docs/dev-practices/genbank_reference_input.md`](docs/dev-practices/genbank_reference_input.md)). The
steps below prepare the files for the pre-built route.

Full page, both paths, rules and known limitations: [`docs/usage/prepare_reference.md`](docs/usage/prepare_reference.md).

**From GenBank.** `docs/prepare_input/process_GeneBank/process_genbank_auto.sh` converts a `.gbk`/`.gb` file into
everything the pipeline needs: the reference FASTA (`--fasta`), the GFF3 annotations (`--report_gff3`) and a SnpEff cache
(`--snpeff_cache` / `--snpeff_db`).

```bash
bash docs/prepare_input/process_GeneBank/process_genbank_auto.sh <input.gbk> [output_dir]
```

`--snpeff_db` is the genome name derived from the GenBank `ORGANISM` field (lowercase, spaces →
underscores), e.g. `Ogataea polymorpha` → `ogataea_polymorpha`, matching the
`snpeff_cache/ogataea_polymorpha/` subdirectory. The script prints the exact parameters to use and
records the name in `organism_info.sh`. Processed outputs are generated locally and are not tracked in git.
⚠️ Its GenBank → GFF3 step is lossy (no transcript hierarchy or phase, gene symbols dropped). That is fine for
yeast; see the page above before using it on an intron-rich genome.

**From FASTA + GFF3** (Ensembl, NCBI, your own annotation). This builds only the cache:

```bash
bash docs/prepare_input/build_snpeff_cache.sh <snpeff_db> <reference.fa> <annotation.gff3> [out_dir] [genome_description]
```

It checks that contig names match, strips the Ensembl ID prefixes that break snpEff's gene models, and
prints the parameters to use. Verified to reproduce the project's own S288C cache byte for byte. Name the
genetic code of any contig that does not use the standard one with `CODON_TABLES=contig=Table` (yeast:
`CODON_TABLES=Mito=Yeast_Mitochondrial`): snpEff does not read it from the annotation, and without the
line mitochondrial variants are translated with the standard code (see the page above).

### Running the SnpEff cache from cloud storage

`--snpeff_cache` is a *directory* parameter. It works from a local path or from `az://`, `s3://` or
`gs://`, but **not** from an https URL (Nextflow cannot list or stage a directory over http). So for a
run whose head job cannot prepare the cache first (a Seqera Launchpad entry, AWS Batch, an HPC), build
the cache once, upload the directory to your own bucket, and point the parameter at it. This is how the
project's own Seqera entry runs. What the directory must satisfy:

- **Layout:** `<snpeff_cache>/<snpeff_db>/snpEffectPredictor.bin` plus the `sequence*.bin` files and
  `snpEff.config`, with `--snpeff_db` equal to that directory name. Flat, not the `<db>/<db>/` form used
  by nf-core's `annotation-cache` bucket. `genes.gff` and `sequences.fa` are build inputs only and may
  be left out (the runtime set is ~6 MB for yeast).
- **snpEff version:** build with the same snpEff the pipeline runs, **5.1** (e.g.
  `quay.io/biocontainers/snpeff:5.1--hdfd78af_2`, which both preparation scripts pin). A cache built with 5.2 or
  later is refused: `Database version: '5.2', Program version: '5.1'`.
- **Azure with a service-principal credential:** the cache must sit in the same blob *container* as
  the work directory, like every other input
  ([`azure_batch_execution.md` §3](docs/dev-practices/azure_batch_execution.md)).
- **Seqera launch form:** a value set in a config profile survives: this pipeline ships `snpeff_cache`
  with no default, so the form has nothing to inject over it (upstream sarek would inject
  `s3://annotation-cache/snpeff_cache/`, [§13](docs/dev-practices/azure_batch_execution.md)). Typing it
  into the form is still fine and is what the project's own entry does, since the path differs per
  dataset. Without any cache, a run with `snpeff` in `--tools` fails at launch with a clear message.

For the ottilie test on your own infrastructure: download the published `snpeff_cache.tar.gz`, unpack
it, upload the `R64-1-1.105/` directory to your bucket, then launch `-profile ottilie_test_ci` with
`--snpeff_cache <bucket path>`. Every other input of that profile is an https URL and stages from
anywhere; the parameter override beats the profile's local default.

## Variant calling tools

**Tier 1, validated for ALE in v1.0.0** (exactly what the contract test exercises):

| Tool | Type | Ploidy support | Notes |
|------|------|----------------|-------|
| HaplotypeCaller | SNV / INDEL | `--sample-ploidy` per sample | Joint germline; cohort + per-sample VCFs; soft-filter fallback where VQSR can't run |
| CNVKit | CNV | Diploid baseline | `--ploidy` not passed; use `fold_change = 2^log2`. See [`cnvkit_ploidy_behavior.md`](docs/variant-calling/cnvkit/cnvkit_ploidy_behavior.md) |
| TIDDIT | SV | `-n` ploidy | Affects coverage normalization and DUP/DEL GT thresholds. See [`tiddit_ploidy_behavior.md`](docs/variant-calling/tiddit/tiddit_ploidy_behavior.md) |
| Manta | SV | Diploid only | Breakpoint caller: no ploidy parameter by design; used for cross-validation |
| SnpEff | Annotation | n/a | Custom cache built from GenBank or FASTA + GFF3 (`docs/usage/prepare_reference.md`) |

**Tier 2, functional but not release-validated for ALE:** Control-FREEC, breseq, Mutect2, FreeBayes,
DeepVariant, Strelka. Enable via `--tools`; they run as in upstream sarek. The fork's former AF
post-filters for Mutect2/FreeBayes were removed 2026-09-09
([`docs/archive/tier2/README.md`](docs/archive/tier2/README.md)).

## Output

```
<outdir>/
├── preprocessing/            # markduplicates CRAMs
├── variant_calling/          # per-caller VCFs (haplotypecaller, cnvkit, manta, tiddit)
├── variant_calling_filtered/ # per-sample hard-filtered HC VCFs (only with --hard_filter_haplotypecaller_joint)
├── annotation/               # SnpEff-annotated VCFs
├── reports/ multiqc/         # QC (preflight, fastqc, mosdepth, samtools, bcftools, snpeff) + three MultiQC
│                             #   reports: read-QC and alignment-QC (written while the run continues), complete
│                             #   (multiqc_report.html). See docs/usage/qc_first_run.md → The three MultiQC reports
├── mutation_reports/         # the ALE dashboard: start at index.html
└── pipeline_info/            # execution report, timeline, trace, software versions
```

The **mutation report bundle** is the ALE-specific deliverable. Start at its `index.html`. Its header
names the **run that produced the bundle** (run name, start time, pipeline version and commit, Nextflow version,
the session id that `-resume` takes and, on a Seqera Platform run, the Seqera run id) and prints the
**complete-output folder** (the run's resolved `outdir`, an `az://` URL on a cloud run) with a Copy button, so a
viewer in Seqera or of a downloaded copy knows where everything else lives. The Summary table below it counts
samples (with their QC verdicts: the thresholds are the hidden `report_qc_*` parameters), differing SNV / InDel
sites, SV events, aneuploid chromosomes and changed copy-number windows, each a link to its section. The SNV / InDel
table opens on the sites that differ between samples, protein-changing first; its *All PASS sites* view adds the rest:
the strain background every sample shares, and sites carried by one sample where every other sample has no reads at
the position. A sample with no reads counts as neither carrier nor reference, so such a site is not "differing"; on
an engineered strain these are mostly cassette junctions, as the page's Methods explain. The Seqera run id is a link to the run when
`--seqera_workspace_url` holds your workspace's browser URL
(`https://cloud.seqera.io/orgs/<organisation>/workspaces/<workspace>`). A run cannot find that address
itself; set it once in the Launchpad entry's parameters
([`launch_params_file.md`](docs/usage/launch_params_file.md#4-traps)):

```
mutation_reports/
├── index.html               # entry point, links everything below
├── cohort_report.html       # cross-sample igv-report
├── samples/                 # <sample>_{hc,cnvkit,manta,tiddit}_report.html
├── data/                    # snv_indel_sites.csv (every joint-call site: FILTER, SnpEff, per-sample GT/AD/DP/VAF),
│                            # cn_cohort_{full,collapsed}.csv, sv_cohort_matrix_union{,_pass}.csv,
│                            # sv_cohort_merged_union{,_pass}.vcf.gz (joint SV VCF, one GT column per sample),
│                            # contig_copy_number.csv (TIDDIT per-contig coverage ratio, the only Mito quantification),
│                            # cn_matrices/, sv_merged/ (per-sample SURVIVOR VCFs), *.{manta,tiddit}.pass_stats.tsv
└── vcf/                     # curated per-caller VCFs (see vcf/README.md in the bundle)
```

How the reports are built and how to read them:
[`docs/README.md#output--reporting`](docs/README.md#output--reporting).

**On Seqera Platform**, the run's *Outputs* tab lists the entry points of this bundle in reading
order: *1. Start here* (index), *2. SNV & InDel report* (+ *2b/2c* its CSV and VCF), *3. SV
table* (+ *3b* the SV VCF), *4./5.* the two copy-number tables (+ *4b* uncollapsed), *6. MultiQC*, *7.* the
per-sample IGV reports. The list and its numbered labels
come from [`tower.yml`](tower.yml) (the tab sorts by label). Two limits to know: files under 10 MB preview in the browser, 10–25 MB are
download-only, larger ones are listed by path only (per-sample HaplotypeCaller reports on a
full-depth run are 14–40 MB). The index's relative links to **pages** resolve inside the tab (verified
2026-09-11), so opening *index* there navigates like a local copy, subject to the size limits, but its
**download buttons do nothing there**: the preview is an iframe sandboxed without `allow-downloads`
(verified 2026-09-30), which is why every downloadable file is also its own numbered entry with the
tab's Download button. The index says so when it detects the frame. Links out of the
`mutation_reports/` folder (e.g. `../multiqc/`) are refused by the content host's cookie scope. To keep or share the whole bundle, download the `mutation_reports/` folder (Data Explorer
on the run's `outdir`, or `az storage blob download-batch`) and open `index.html` locally. The index
itself needs no internet (its table library is inlined); `cohort_report.html` and the per-sample IGV
pages load Tabulator and igv.js from a CDN, so open those once while online if you will present offline.

## Testing

```bash
conda activate nf-env      # provides nf-test 0.9.3
NXF_VER=25.10.4 nf-test test tests/ottilie_e2e.nf.test -c tests/nf-test-ottilie.config
```

This is the end-to-end contract test (~25 min). It is also how a fresh install is verified, not only a
development tool. It needs the local test data (`download_test_data.sh`, see Quick start) and uses
its own fixed resource clamp, so no machine config is passed. Keep the `NXF_VER=` prefix: nf-test
runs whatever `nextflow` is on `PATH`. Without the conda env:
`conda install -c bioconda nf-test=0.9.3`. Walkthrough:
[`new_machine_setup.md` §7](docs/usage/new_machine_setup.md#7-verify).

See [`docs/dev-practices/testing_best_practices.md`](docs/dev-practices/testing_best_practices.md).

## Cloud deployment

Two stages, and the difference is **where the Nextflow head process runs**; the tasks run on Azure
Batch either way:

| | Head process | Launched with | Status |
|---|---|---|---|
| **Local head job** | your machine | `nextflow run … -c conf/azure_batch.config` | ✅ validated end-to-end (2026-08-03) |
| **Cloud head job** | an Azure Batch node | `tw launch` / Seqera Platform UI | ✅ validated end-to-end (2026-08-06); reference baseline re-cut 2026-09-08 |

Start here: [`docs/dev-practices/azure_batch_execution.md`](docs/dev-practices/azure_batch_execution.md).
It opens with why the config differs from the stock Azure Batch tutorial (only 4 settings, 3 of them
forced by the account or by service-principal auth), then lists the execution gotchas. Azure service
principal + RBAC provisioning: [`deploy/azure/`](deploy/azure/).

```bash
source deploy/azure/seqera-sp/00_vars.sh
read -rs AZURE_CLIENT_SECRET && export AZURE_CLIENT_SECRET
bash bin/test_ottilie_azure_batch.sh
```

Platform-side checklist (April 2026, predates the service-principal work; verify against
`deploy/azure/seqera-sp/RUNBOOK.md`):
[`docs/seqera_cloud/seqera_cloud_deployment_checklist.md`](docs/seqera_cloud/seqera_cloud_deployment_checklist.md).
`conf/seqera_azure.config` is a small supplement pasted into the Platform config field, not the
executor config above.

## Credits

yAMP is a fork of [nf-core/sarek](https://nf-co.re/sarek) 3.5.1; upstream credits and tool citations
are retained in [`CITATIONS.md`](CITATIONS.md).

## License

[MIT](LICENSE). The yAMP modifications are © 2025–2026 Aletech; the upstream nf-core/sarek
copyright (Maxime Garcia, Szilveszter Juhos, Friederike Hanssen) is retained in the same file.
