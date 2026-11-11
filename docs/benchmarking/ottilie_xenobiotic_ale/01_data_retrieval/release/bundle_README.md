# Ottilie yeast ALE test data

*Canonical copy of the note that ships as `README.md` inside `ottilie_test_data.tar.gz` and is
published at `<base>/README.md`. **Edit this file, then re-run `publish_test_data.sh`** so the two
never drift.*

---

Everything here is *Saccharomyces cerevisiae* S288C, derived from SRA **PRJNA590203**
(Ottilie et al., *Commun Biol* 5:128, 2022). Public data — no credentials, no SAS token.

Base URL for everything below — versioned, so a bundle always names the version it came from:

```
<base>
```

**Version 2 (`ottilie/v2`, 2026-11-11).** What changed from version 1, which stays published
unchanged under `ottilie/v1`:

- **The test reads are a new cut.** Version 1 was every read pair on chromosomes I, IV, VII and XV,
  taken from alignments of an earlier pipeline run. Version 2 is cut from the SRA reads directly,
  includes the mitochondrial contig, and keeps a seeded fraction of the pairs (0.67 of both
  samples: about 30x for the parent, 60x for the evolved clone). `fastq_test/CUT_PARAMETERS.tsv`
  records the seed, fractions, pair counts and md5s; the file names carry seed and fraction.
- **The test reference has five contigs**: I, IV, VII, XV and Mito.
- **Both snpEff databases carry the yeast mitochondrial genetic code** (a `codonTable` line in
  `snpeff_cache/R64-1-1.105/snpEff.config`). Version 1's annotated mitochondrial genes with the
  standard code.
- `fastq_test/TRUTH_GATE.txt` lists the checks the cut passed on a pipeline run before it was
  published (the four SNVs, the chr I gain, ten structural-variant records, the read counts).

The 4-sample pilot recipe, its truth set and the name dictionary are as in version 1.

## What is in this bundle

| Path | Size | What |
|---|---|---|
| `fastq_test/` | ~267 MB | 2 samples × paired reads, **chromosomes I, IV, VII, XV and Mito only**, a seeded 0.67 of the pairs; plus `CUT_PARAMETERS.tsv` and `TRUTH_GATE.txt` |
| `S288C_reference_test/` | ~41 MB | **slimmed** reference — those 5 contigs, + `.fai`, `.dict`, `.gb`, `snpeff_cache/` |
| `S288C_reference/` | ~84 MB | **full** reference — all 16 chromosomes + Mito, + `.gb`, `.gff3`, `chromosomes/`, `snpeff_cache/` |
| `download_pilot_fastq.sh` | 4 KB | fetches the **4-sample pilot** reads from SRA and writes their samplesheet (see below) |
| `pilot_truth_set.csv` | 6 KB | the paper's published mutations for the pilot's 3 evolved clones — 43 events, one per row |
| `sample_name_dictionary.csv` | 42 KB | clone names across the paper's tables ↔ SRA run/library ↔ EAW id, for all 363 runs |

Both references are included so either is ready to use without a second download. Neither ships
BWA indices; the full one also has no `.fai`/`.dict` (build them with `samtools faidx` and
`gatk CreateSequenceDictionary`, or let your pipeline generate them).

## Samples, and which FASTQ belongs to which

Filenames are **sample-first**, then the contig subset, then the seed and fraction of the cut. The
SRA accession is *not* in the test FASTQ names — this table (and `fastq_test/CUT_PARAMETERS.tsv`)
is how you map one to the other.

| Sample | SRA | Role | FASTQ |
|---|---|---|---|
| `NODRUG-GM2` | SRR10985539 | parent, un-evolved control | `NODRUG-GM2_chrI_IV_VII_XV_Mito_seed42_frac0.67_R{1,2}.fastq.gz` (54 / 57 MB; 717,457 pairs, about 30x) |
| `CBR110-15-R3a` | SRR10985585 | evolved | `CBR110-15-R3a_chrI_IV_VII_XV_Mito_seed42_frac0.67_R{1,2}.fastq.gz` (78 / 80 MB; 1,288,606 pairs, about 60x) |

Both samples are **haploid (ploidy 1)** and both are **normal / untreated** — there is no
tumor-normal pairing here, which is what puts a germline caller into joint-cohort mode.

**Truth set:** 4 SNVs + a whole-chromosome duplication of **chr I** in `CBR110-15-R3a`: every event
the paper reports for this clone. This is what makes the set a correctness test rather than a
"did it finish" test.

**How the reads were chosen.** By position and at random, never by site: every pair with both
mates aligned to one of the five contigs (bwa-mem2 against the full genome), then
`samtools view -s 42.67`, which keeps or drops a pair by a hash of its name. Duplicates and QC-fail
reads are kept; pairs with a mate on another contig or unmapped are dropped. The reads are as
sequenced (untrimmed). The evolved clone is kept deeper than the parent on purpose: its library
gives about a third of the parent's junction-spanning pairs per unit depth, and at 30x a joint
Manta call genotypes it hom-ref at half of the strain's cassette junctions. The mitochondrial
contig is at about 300x in the parent and 125x in the evolved clone.

## The bigger 4-sample set — the pilot

Same experiment at full depth across all 16 chromosomes, ~4.2 GB of reads. The reads are **not**
re-hosted here; `download_pilot_fastq.sh` (in this bundle) pulls the four SRA runs and writes a
`samplesheet_pilot.csv` for them. The full reference in this bundle is the one they need.

```bash
# sra-tools 3.2.1 — do NOT use 3.4.1, it segfaults
conda create -n sra -c bioconda -c conda-forge sra-tools=3.2.1 && conda activate sra
OUT=/path/for/pilot bash download_pilot_fastq.sh     # → $OUT/fastq/SRR*.fastq.gz + $OUT/samplesheet_pilot.csv
```

**It does have a truth set** — the paper's own calls (Supplementary Data 4 for SNV/INDEL, Data 5 for
CNV), extracted for these clones into `pilot_truth_set.csv`:

| Sample | SRA | Paper's clone name | Published events |
|---|---|---|---|
| `NODRUG-GM2` | SRR10985539 | `NODRUG--GM2` | parent, un-evolved control — none by definition |
| `CBR110-15-R3a` | SRR10985585 | `CBR110-15R3a` | 4 SNVs + whole-chromosome duplication of chr I |
| `Carmaphycin-R9-2` | SRR10985678 | `Carmaphycin--R9-2` | 15 SNVs (all substitutions; YRM1 N660I is the likely driver) |
| `Doxorubicin16-R2b` | SRR10985527 | `Doxorubicin-16--R2b` | 2 SNVs + 21 INDELs — a *PMS1* K724\* mismatch-repair mutator (CRISPR-confirmed causal in Data 7); the indels are mostly 1-bp homopolymer deletions |

That is 21 SNVs, 21 INDELs and 1 CNV, covering every consequence class the paper reports
(missense, nonsense, frameshift, synonymous, intergenic, mitochondrial) but **no focal
amplification** — for that class use a Data 5 clone such as `Doxorubicin-135-R2b` (SRR10985529).

**Where the truth set comes from.** Three supplementary tables of the paper (PMC 8837787), not
shipped here because they are the paper's own files:

| Table | Holds | |
|---|---|---|
| [Data 4](https://pmc.ncbi.nlm.nih.gov/articles/instance/8837787/bin/42003_2022_3076_MOESM6_ESM.xlsx) | every SNV/INDEL called — 1,405 across 355 clones | `pilot_truth_set.csv` rows with `source = Sup Data 4` |
| [Data 5](https://pmc.ncbi.nlm.nih.gov/articles/instance/8837787/bin/42003_2022_3076_MOESM7_ESM.xlsx) | every CNV called — 24 events in 23 clones | `source = Sup Data 5` |
| [Data 7](https://pmc.ncbi.nlm.nih.gov/articles/instance/8837787/bin/42003_2022_3076_MOESM9_ESM.xlsx) | CRISPR/Cas9 validation — 68 mutations knocked into the parent, 45 confirmed causal by IC50 shift | not a sample list — see below |

Data 7 is **not** a list of sequenced samples: its EAW strains are engineered knock-ins with no
reads, identified only by gene + amino-acid change, so it has to be joined back to Data 4 on that.
It is the only *method-independent* ground truth in the paper — Data 4/5 are the authors' own GATK
calls, so agreement with them measures concordance with their pipeline, not correctness, and a
low "precision" against them is expected rather than a defect. For the pilot exactly one event is
Data 7-confirmed: `Doxorubicin16-R2b` *PMS1* p.Lys724\* (XIV:475560). *ELO2* is also a confirmed
doxorubicin-resistance gene, via a different allele (Q7\*) than the frameshift this clone carries.

⚠️ **Names differ between the paper's tables, SRA and this bundle.** Sup Data 4 and the SRA library
write `Doxorubicin-16--R2b`, the samplesheet here `Doxorubicin16-R2b`; Data 4/5 write `CBR110-15R3a`,
SRA and the samplesheet `CBR110-15-R3a`; and so on. An exact-string join silently drops clones. `sample_name_dictionary.csv` reconciles all 363 runs (columns
`clone_name_sup4`, `clone_name_sup5`, `library_name_sra`, `srr_accession`, `eaw_id`, `is_parent`);
`pilot_truth_set.csv` is already keyed by the sample names used in the samplesheet.

Two of the 43 are hard for any short-read pipeline, and are worth knowing before calling them misses:

- **`XIV:781921` PAU6 G>A** (Doxorubicin16-R2b) — *PAU6* is one of 24 near-identical seripauperin
  genes; most reads over the site have MAPQ 0. Expect a call that fails mapping-quality filters.
- **`Mito:53278` 14-bp deletion** (Doxorubicin16-R2b) — the reads carry no such deletion. Instead the
  clone's mtDNA is at ~10–40× across roughly 47–58 kb (the parent is at ~300× there) with
  clipped, chimeric reads at the edge: a large mitochondrial deletion/rearrangement, which the
  paper's caller apparently represented as a small indel. A coverage or SV view shows it; an
  indel caller will not.

The parent is a sequencing of the **ABC16-Green Monster** strain — an engineered background with
16 ABC-transporter deletions. Its differences from the S288C reference are strain construction,
not mutations; only evolved-minus-parent is biology. (Four later re-sequencings of the same parent
exist as `ParentStrain--GM*`, SRR14327619–22, if you want a parent-vs-parent noise baseline.)

⚠️ The two sets **share two sample names**. The 2-sample reads are a contig subset of these same
libraries **and** a read-level downsample (0.67 of the pairs), so per-base depth on the retained
contigs is about two thirds of the full set's. Keep the outputs apart.

## ⚠️ Reference pairing — the one thing to get right

**Reads set a minimum reference. Bigger is always allowed; smaller never is.**

| | slim ref (4 chr + Mito) | full ref (16 + Mito) |
|---|---|---|
| **2-sample reads** | ✅ fast e2e test — this pairing carries the truth set | ✅ valid, and a *truer* analysis |
| **4-sample reads** | ❌ **never** | ✅ the intended pairing |

- **2 samples + slim** is a *speed* optimisation, not a correctness requirement.
- **2 samples + full** is valid and arguably better: these reads were originally placed by an
  aligner that could see all 16 chromosomes, so the full reference restores the competing loci —
  repeats, Ty elements, subtelomeric and rDNA regions — that a 5-contig reference removes.
  Their absence inflates MAPQ for repetitive reads. Caveat: the truth set was established against
  the **slim** reference, so a full-reference run is no longer directly comparable to it.
- **4 samples + slim** is the corner to avoid. Reads from the 12 absent chromosomes do not vanish —
  they **mismap** onto the contigs that are present and manufacture false variants. The run completes
  and the output looks entirely plausible. Nothing warns you.

The **SnpEff cache is not slimmed**: the copies under `S288C_reference_test/snpeff_cache/` and
`S288C_reference/snpeff_cache/` are byte-identical in all 7 files (17 contigs, the mitochondrial
genetic code set), and are shipped twice only so
each reference tree stands alone. Only the FASTA, the GenBank and `chromosomes/` were ever subset,
so switching references means swapping three things, not four.

## Other things that will bite on any pipeline

- **Haploid.** Ploidy is **1**. Most callers default to 2 — set it explicitly (GATK
  `--sample-ploidy 1`, FreeBayes `-p 1`). Some tools have no ploidy parameter at all (Manta, by
  design — it is a breakpoint caller, not a genotyper).
- **No known-sites VCF exists for this genome**, so **BQSR and VQSR are impossible** — there is no
  resource to supply. Pipelines that assume GATK best practices need those steps disabled, and the
  failure mode is usually confusing: a starved input channel rather than a clear error.
- **Chromosome naming is Ensembl-style** — `I`, `II`, … `XVI`, `Mito`. Not `chrI`, not
  `NC_001133.9`. The GenBank file is the `_ensembl_chrnames` variant for exactly this reason.

## Verifying

**Checking one big file finished downloading** — each large object has a `.md5` sidecar next to it:

```bash
curl -fsSL -O <base>/ottilie_test_data.tar.gz.md5
md5sum -c ottilie_test_data.tar.gz.md5
```

**The FASTQ sidecars travel with the FASTQs**, both on the blob and inside this bundle — so after
extracting, and after any later copy to cluster scratch, you can re-verify in place:

```bash
cd fastq_test && md5sum -c *.md5
```

That is the point of shipping them rather than relying on a manifest at the blob root: once the
files have been moved, a root manifest's paths no longer match, but a sidecar still does.

**Checking everything** — `SHA256SUMS` and `MD5SUMS` each cover the whole published file tree plus
both tarballs, so a bundle can be proved to unpack to exactly the individual files. Use whichever
you prefer; they are generated from the same list and cover the same set.

```bash
curl -fsSL -O <base>/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

Note there are **no `.md5` sidecars inside `chromosomes/` or `snpeff_cache/`**. Those directories
are consumed whole as directory parameters by some pipelines, and stray files in them would be
staged along with the real data. `MD5SUMS` covers their contents instead.

## Also published alongside this bundle

| File | For |
|---|---|
| `files/**` | the same content as individual blobs, for per-file staging (the two CSVs are at `files/pilot_truth_set.csv` and `files/sample_name_dictionary.csv`) |
| `download_pilot_fastq.sh` | the pilot recipe, standalone — same file as in the bundle |
| `snpeff_cache.tar.gz` | cache-only, when a `snpeff_cache` *directory* will not stage from a URL |
| `samplesheet_test_blob.csv` | a ready-made sample sheet whose FASTQ paths are the public URLs |
| `SHA256SUMS`, `MD5SUMS` | integrity for all of the above — same file set, pick either |
| `*.tar.gz.md5`, `files/fastq_test/*.fastq.gz.md5` | per-file sidecars for the large objects |
