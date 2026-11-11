# Setting up yAMP on a new machine

Bare Linux VM → a verified pipeline run. Follow it top to bottom.

**The pipeline needs exactly two things: Docker and Nextflow.** Every bioinformatics tool it runs
(GATK, BWA, CNVKit, Manta, TIDDIT, SnpEff, SURVIVOR, …) is pulled as a container at runtime, so
nothing else has to be installed.

> **This document is validated by being followed.** Written on a machine that already worked, then
> walked end-to-end on a second machine (8 vCPU / 15 GB, 2026-07-30); every gap that run exposed is
> fixed below. If a step is wrong, fix it here in the same session; that is the only test this guide
> gets. Mark anything you *infer* rather than observe with **[unverified]** so the next person knows
> where to look. See [Reporting deviations](#reporting-deviations).

---

## 0. Prerequisites

| | Requirement |
|---|---|
| **OS** | Linux **x86_64**. Apple Silicon / ARM is **not supported**: GATK and MultiQC tasks stall or hang. |
| **CPU / RAM** | 4 vCPU / 16 GB is the validated dev size. Less RAM works if you lower the clamp (step 4), but tasks run less concurrently. |
| **Disk** | **~30 GB free**, and check *which* filesystem (see below). |
| **Network** | Needed for: git clone, conda, the test-data download (~330 MB), the Nextflow engine self-fetch, and container pulls on first run. |
| **Privileges** | `sudo` for installing Docker. |

### Disk, in detail

The container images dominate, and they land somewhere different from everything else:

| What | Size | Where it lands |
|---|---|---|
| **Container images** | **~16 GB** (26 images) | `/var/lib/docker`, *not* your repo |
| Work dir (`work/`) | ~8 GB | launch directory, or wherever `-w` points |
| Test data | ~450 MB | `data/ottilie/` |
| Output | ~200 MB | `--outdir` |

Every tool the pipeline runs is a container, so a first run pulls the lot. Later runs reuse them and
cost only work + output. The rows sum to ~25 GB; **~30 GB** is the recommendation because a pull
needs transient room to download and unpack on top of the final size.

Measured on a workstation after an ottilie run (2026-07-30): **26 pipeline images totalling 16.05 GB**,
within a host-wide `docker system df` of 19.46 GB across 32 images. Summing `docker images` sizes
double-counts shared layers, so the true on-disk figure is somewhat *lower* than 16 GB; treat it as a
safe upper bound. Re-measure on any machine with:

```bash
docker images --format '{{.Repository}}\t{{.Size}}' | grep -E 'biocontainers|wave.seqera|nf-core'
```

It is top-heavy; 8 images are 79% of the total:

| Image | Size | |
|---|---|---|
| `gatk4_gcnvkernel` | 4.97 GB | **`GATK4_VARIANTFILTRATION`**, see the warning below |
| `cnvkit` (×2 versions) | 2.58 GB | |
| `mulled-v2-780d63…` | 1.26 GB | |
| `mulled-v2-d9e7ba…` | 1.15 GB | |
| `gatk4` | 1.13 GB | |
| `multiqc` | 0.90 GB | |
| `snpeff` | 0.70 GB | |

⚠️ **Do not prune `gatk4_gcnvkernel` as unused.** At 4.97 GB it is 31% of the footprint and its name
suggests GATK germline-CNV calling, which ALE does not run, but it is the container for
`GATK4_VARIANTFILTRATION` (`modules/nf-core/gatk4/variantfiltration/main.nf`), i.e. the Tier-1
`VARIANTFILTRATION_FALLBACK` soft-filter on the joint VCF. The `gcnvkernel` in the name is nf-core
packaging, not a tool ALE invokes. Deleting it just forces a 5 GB re-pull on the next run.

⚠️ **Budget for `/var/lib/docker` separately.** It is usually on the root filesystem, while you may
be running the pipeline from a larger data disk, so `df -h .` in your repo can look comfortable
while the images fill `/` and the run dies with `No space left on device`. Check both:

```bash
df -h /var/lib/docker .    # same filesystem, or different?
docker system df           # what is already cached
```

If they share a filesystem, you need the full ~30 GB there. If the work dir is on a bigger disk, put
it there explicitly with `-w /path/to/big/disk/work`, but the images still go to `/var/lib/docker`
regardless, so that filesystem alone needs ~20 GB.

> `docker system df` reporting most of the cache as "reclaimable" does **not** mean it is wasted.
> Images show as reclaimable once no container is using them, but the next run needs them again.
> Pruning only makes sense if you are done with the pipeline, or short on space and willing to
> re-pull. *(Also ignore the 64 GB `data/ottilie/` on the original dev VM: full-depth pilot FASTQs
> from earlier work, not part of setup.)*

---

## 1. Docker

Install per the [official instructions](https://docs.docker.com/engine/install/) for your
distribution.

Then add yourself to the `docker` group so Nextflow can launch containers without `sudo`:

```bash
sudo usermod -aG docker $USER
```

⚠️ **You must start a new login session for this to take effect**: log out and back in, or run
`newgrp docker`. This is the single most common setup failure: `docker ps` works under `sudo` but
the pipeline fails with a permission error on the Docker socket.

Verify **without sudo**:

```bash
docker run --rm hello-world
```

---

## 2. Conda + the Nextflow environment

Install [Miniforge](https://github.com/conda-forge/miniforge#install) if conda isn't present, then:

```bash
git clone git@github.com:nnf-bright-biofoundry/ALE_Yeast.git
cd ALE_Yeast
conda env create -f environment.yml
conda activate nf-env
```

This installs Nextflow **25.10.4**, Java 17, and **`nf-test` 0.9.3** (runs the contract test that
verifies the install in step 7). The Nextflow version is the same one the launch scripts pin via
`NXF_VER`, on purpose (see below).

`nf-test` is a separate tool, not part of Nextflow. If you add it to an existing environment instead
of creating `nf-env`, match the pinned version:

```bash
conda install -c bioconda nf-test=0.9.3        # or: curl -fsSL https://get.nf-test.com | bash
```

> In this environment use `python`, not `python3`: the env's interpreter is at the conda prefix.

### Which Nextflow actually runs

`nextflow` is a launcher, not the engine. If `NXF_VER` is set it fetches and runs **that** version,
ignoring what is installed; if not, you get the installed one. Hence two rules:

- **Pin it.** `export NXF_VER=25.10.4` is the primary control. The launch scripts set it, but a fresh
  shell, an ad-hoc `nextflow run`, or a Seqera CE does not, so make it durable:
  `echo 'export NXF_VER=25.10.4' >> ~/.bashrc` (or drop the same line in
  `$CONDA_PREFIX/etc/conda/activate.d/nxf_ver.sh` to scope it to the env).
- **Never `conda install nextflow` unpinned.** That resolves to 26.x, which **cannot parse this
  pipeline's config**: `Cannot read project manifest -- Config parsing failed`, with no mention of
  the version. This is what you fall back to whenever the pin is missing. Why it breaks:
  [`ale_sarek_upgrade_runbook.md`](../dev-practices/ale_sarek_upgrade_runbook.md). The
  `manifest.nextflowVersion = '<26.0.0'` guard will not save you: on 26.x the parse dies before
  Nextflow reads the manifest, so the guard never fires.

Because the pin overrides the install, **a machine with an existing Nextflow (even 26.x) can skip the
conda env**, but it still needs `nf-test` for step 7, which ships in `nf-env`, not with Nextflow.

Check the engine, the parse, and `nf-test` (this runs no pipeline):

```bash
NXF_VER=25.10.4 nextflow -version                                    # must report 25.10.4
NXF_VER=25.10.4 nextflow config -profile ottilie_test,docker >/dev/null && echo "CONFIG OK"
nf-test version                                                      # must report 0.9.3
```

---

## 3. Fetch the test data

Public Azure Blob, no credentials, no `az login`:

```bash
bash docs/benchmarking/ottilie_xenobiotic_ale/01_data_retrieval/release/download_test_data.sh
```

Downloads ~330 MB into `data/ottilie/` (gitignored), verifies a SHA256 checksum, and **writes
`data/ottilie/samplesheet_test.csv` with this machine's absolute paths**.

⚠️ **Never copy that samplesheet between machines.** It contains machine-local absolute FASTQ paths;
the script regenerates it correctly per machine. Full lineage:
[`DATA_PROVENANCE.md`](../benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md).

**Or skip this step entirely.** `bash bin/test_ottilie_blob.sh` runs the same test straight off the
public blob URLs (`ottilie_test_ci` profile): no `data/ottilie/`, no samplesheet to write, and no
pre-launch step, since the reference is one GenBank file that streams like the reads.
Use the download above when you want the data on disk (nf-test, repeat runs, offline work); use the
streaming script for a one-shot check that the install works.

> Streaming doesn't save disk: Nextflow downloads each remote file once into
> `<workdir>/stage-<session-uuid>/` (~278 MB here), so the inputs move *into* the work dir rather than
> disappearing. `rm -rf work_ottilie_test_blob` reclaims all of it; **`nextflow clean` does not**: it
> skips `stage-*` dirs. Full breakdown:
> [`DATA_PROVENANCE.md`](../benchmarking/ottilie_xenobiotic_ale/DATA_PROVENANCE.md).

---

## 4. Tell the pipeline how big this machine is

`conf/base.config` sizes every task for the cloud target (4 vCPU / 32 GB). On a smaller machine
tasks would request more RAM than exists and never get scheduled, so you must supply a **clamp**:

```bash
cp conf/mymachine.config conf/$(hostname).config
```

Measure the machine:

```bash
echo "cpus: $(nproc)  ram: $(free -g | awk '/^Mem:/{print $2}')GB  disk: $(df -h --output=avail . | tail -1)"
```

Edit the three numbers in the copy:

```groovy
process {
    resourceLimits = [ cpus: <your vCPUs>, memory: '<RAM minus ~2 GB>.GB', time: '72.h' ]
}
executor {
    cpus = <twice your vCPUs>
}
```

`resourceLimits.cpus` is the full vCPU count. It's a **per-task ceiling**, not a pool size, so it
doesn't set concurrency. Subtract ~2 GB from RAM for the OS, the Docker
daemon, and the Nextflow JVM itself, none of which are inside the clamp. `free -g` truncates, so
read `free -m` if you're near a boundary: a "16 GB" VM usually reports ~15 GB.

`executor.cpus` is the scheduler's CPU **budget**, a bookkeeping number and not a hardware count,
set to twice the ceiling on purpose: the scheduler starts a task only when its request fits what
the budget says is free, the budget can lose a unit when a completion and a submission coincide
(seen 2026-11-09), and a task that asks for all of it is then stranded with nothing running and no
error. Leave the memory budget to Nextflow (it takes the machine's RAM); a hand-set memory pool that
barely exceeds one task's request deadlocks the same way
([`nextflow_local_executor_deadlock.md`](nextflow_local_executor_deadlock.md)).

Keep the file **params-free**: `-c` outranks `-profile`, so any `params.*` in it would silently
override the profile. Background:
[`compute_resources.md`](../dev-practices/compute_resources.md).

> ❌ Do **not** use `-profile azureD4as`: that profile hard-codes the original dev VM's ceilings
> and per-task tuning.

---

## 5. (Optional) swap

On a memory-tight VM, swap gives failing tasks somewhere to go instead of being OOM-killed. The dev
VM runs 8 GB: [`azure_vm_swap_setup.md`](azure_vm_swap_setup.md).

---

## 6. First run

Run inside **tmux** so a dropped SSH connection doesn't kill the pipeline: the first run is
considerably slower than the warm ~15 min below (engine download + every container pulled), and a
closed laptop lid is enough to lose it:

```bash
tmux new -s yamp        # `sudo apt install tmux` if missing
```

Then, inside that session:

```bash
export NXF_VER=25.10.4
nextflow -c conf/$(hostname).config run main.nf -profile ottilie_test,docker \
    --outdir ./output_ottilie_test --generate_reports
```

tmux essentials (every command is the prefix `Ctrl-b`, released, *then* the key):

| Action | Keys |
|---|---|
| **Detach** (leave it running, back to your normal shell) | `Ctrl-b` `d` |
| **Reattach** later, even from a new SSH login | `tmux attach -t yamp` |
| List sessions | `tmux ls` |
| **Scroll back** through output | `Ctrl-b` `[` then `↑`/`PgUp`; `q` to exit scroll mode |
| Close the session for good | `exit` inside it, or `tmux kill-session -t yamp` |

⚠️ The mouse wheel scrolls your *terminal's* history, not tmux's: inside tmux you must enter scroll
mode with `Ctrl-b` `[` or you'll only see the last screenful. Nextflow's progress display redraws in
place, so scrolling back shows less than you'd expect; `.nextflow.log` in the launch directory is the
real record.

Expect the first run to be slower than later ones:

- `NXF_VER` makes Nextflow **download that exact engine** before starting (needs network).
- Every process pulls its container image on first use.

Runtime once warm is roughly **15 minutes** on 4 vCPU / 16 GB.

---

## 7. Verify

**Outputs exist:**

```bash
ls output_ottilie_test/mutation_reports/index.html
ls output_ottilie_test/mutation_reports/data/    # cn_cohort_*.csv, sv_cohort_matrix_*.csv
```

Open `output_ottilie_test/mutation_reports/index.html` in a browser.

**Biological truth set.** The test data has known variants in `CBR110-15-R3a`: **4 SNVs**
(chr IV:205,738 · IV:1,184,212 · VII:233,903 · XV:639,861) and a **chr I whole-chromosome
duplication**. They should appear in the sample's reports.

**Contract test** (the authoritative check; asserts file tree, cohort CSV contents, report data,
and the joint VCF):

```bash
NXF_VER=25.10.4 nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test
```

`nf-test` comes from the **`nf-env` conda environment** (step 2): `conda activate nf-env` first, or
you'll get `nf-test: command not found`. If you skipped step 2 because the machine already had a
usable Nextflow, install it on its own:

```bash
conda install -c bioconda nf-test=0.9.3        # or: curl -fsSL https://get.nf-test.com | bash
```

Match **0.9.3**: that is the version [`environment.yml`](../../environment.yml) pins and the one the
contract test is written against. A newer patch release is not a blocker: the contract test **passed
unmodified under nf-test 0.9.5** on a separate server (2026-09-17, same command, `NXF_VER=25.10.4`).
The snapshot's `meta` block records 0.9.3 but nf-test does not compare it. Stay on 0.9.3 for anything
that **re-records** the snapshot, so the committed provenance stays consistent.

⚠️ **The `NXF_VER=` prefix is load-bearing.** No nf-test config can pin the engine: nf-test 0.9.3's
config supports only `workDir`/`testsDir`/`profile`/`configFile`/`options`/`stageMode`/`ignore`/
`requires`/`triggers`/`plugins`, with no version or env field. nf-test spawns `nextflow` as a
subprocess and inherits your environment, so without the prefix the engine is whatever your PATH
resolves to, possibly a 26.x that cannot parse the config (step 2).

The failure mode is misleading if you don't: the test reports a **missing output file**
(`NoSuchFileException: .../cohort_report.html`), not a config error; the real cause is buried in the
`Nextflow stdout` block underneath. Verified 2026-07-30 by running the command above with
`NXF_VER=99.99.99`, which made nf-test try to fetch a nonexistent engine.

> **Do not "fix" this to match nf-core.** Upstream CI never passes a version to nf-test; it pins at
> the *install* layer (`nf-core/setup-nextflow` puts the chosen engine on PATH, then nf-test uses
> whatever it finds). That works in CI because the runner is clean. The prefix here is a
> **local-machine safeguard** for the common case where a system Nextflow (often 26.x) is already
> on PATH and `nf-env` was never created. Redundant if you followed step 2; harmless either way.

The nf-test path uses its own resource file (`tests/ottilie_nftest_resources.config`: clamp 4 cpu / 14 GB,
a scheduler CPU budget of 8 and trimmed memory requests)
and **ignores** your `conf/<hostname>.config`. That is deliberate, so that the contract test gives the same
answer on every machine instead of varying with the host. Confirmed 2026-07-30 on a second VM
(8 vCPU / 15 GB): the test passed with no `-c conf/<hostname>.config` and no edits. On a machine
*smaller* than the dev VM you may still need to lower those numbers; see
[`compute_resources.md`](../dev-practices/compute_resources.md) § "nf-test resources".

---

## 8. Running your own data

See [the root README](../../README.md#running-your-own-data). You'll additionally need a reference
FASTA and a SnpEff cache; build both from a GenBank file with
`docs/prepare_input/process_GeneBank/process_genbank_auto.sh`.

---

## 9. (Optional) Seqera Platform and Azure Batch credentials

Only needed to launch or inspect runs on Seqera Platform (`tw`, `seqera`) or to run on Azure Batch.
Local runs need none of this.

1. **Store the secrets once, outside the repo.** In a real terminal:
   ```bash
   deploy/azure/seqera-sp/10_store_secret.sh
   ```
   It prompts for the Azure service-principal secret (from `03_create_secret.sh`; Enter to skip) and
   the Seqera Platform token (cloud.seqera.io → *Your tokens*; Enter to skip) and writes
   `~/.config/ale-seqera/sp.env` (mode 600). Re-run it to rotate either value; Enter keeps the other.
2. **Export the token into every shell** (token only; the SP secret stays on-demand). Add this
   *above* the "If not running interactively" guard in `~/.bashrc`, so agent and IDE shells get it too:
   ```bash
   if [ -r "$HOME/.config/ale-seqera/sp.env" ]; then
       TOWER_ACCESS_TOKEN="$(sed -n 's/^TOWER_ACCESS_TOKEN=//p' "$HOME/.config/ale-seqera/sp.env")"
       [ -n "$TOWER_ACCESS_TOKEN" ] && export TOWER_ACCESS_TOKEN SEQERA_ACCESS_TOKEN="$TOWER_ACCESS_TOKEN" || unset TOWER_ACCESS_TOKEN
   fi
   ```
   Then `exec bash -l && tw info` should print the API endpoint instead of `Missing TOWER_ACCESS_TOKEN`.
3. **For Azure Batch runs**, `source deploy/azure/seqera-sp/00_vars.sh` loads both secrets and the
   Azure identifiers; see [`README.md`](../../README.md) → *Cloud execution* and
   [`deploy/azure/seqera-sp/RUNBOOK.md`](../../deploy/azure/seqera-sp/RUNBOOK.md).

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Cannot read project manifest -- Config parsing failed` | Nextflow 26.x. Use 25.10.x (step 2). |
| Permission denied on the Docker socket | Not in the `docker` group, or the group hasn't taken effect; start a new login session (step 1). |
| Tasks queue but never start; `No more task to compute` | A queued task needs the scheduler's whole CPU or memory budget (pool too tight, or one unit lost); see [`nextflow_local_executor_deadlock.md`](nextflow_local_executor_deadlock.md). |
| A task is OOM-killed | Clamp exceeds real RAM (step 4), or add swap (step 5). |
| "sample-sheet only contains normal-samples" | Usually an upstream schema/config failure, not the samplesheet; see [`troubleshooting.md`](../dev-practices/troubleshooting.md). |
| Pipeline aborts without `--skip_tools baserecalibrator` | Expected. BQSR needs known-sites VCFs, which custom microbial genomes lack. The `ottilie_test` profile sets this for you. |
| nf-test prints 12 × `Warning: Module … Dependency '…/main.nf' not found` | **Expected, ignore.** Five vendored nf-core module tests (`spring/decompress`, `sentieon/bwamem`, `sentieon/haplotyper`, `fgbio/callmolecularconsensusreads`, `ngscheckmate/ncm`) reference sibling modules that sarek never installs; identical in upstream 3.5.1. Emitted by nf-test's dependency-graph scan; none of those tests run. [`roadmap.md`](../dev-practices/roadmap.md) § Robustness. |
| nf-test executes ~90 module tests instead of the ottilie test | The `-c tests/nf-test-ottilie.config` didn't take: without it the root `nf-test.config` applies, which is unscoped and loads upstream sarek test params. |

---

## Reporting deviations

If a step here didn't match reality, **fix this file** rather than working around it. Note which
step, what actually happened, and on what OS/VM size.

Mark any claim you write from inference rather than observation with **[unverified]**; it is how the
next person knows which parts have actually been exercised. Open item today: **machines materially
smaller than 4 vCPU / 16 GB**: both validation runs were at or above that size.
