# Test fixtures

Small, committed fixtures for the nf-test unit tests under `tests/`. All are derived from a real
ottilie pipeline run (`output_ottilie_test/`); the commands below make them regenerable.

## SPLIT_JOINT_VCF (`tests/split_joint_vcf.nf.test`)

Both fixtures are the **un-annotated soft-filtered joint VCF** — the actual channel
`SPLIT_JOINT_VCF` consumes in the pipeline (`BAM_JOINT_CALLING_GERMLINE_GATK.out.genotype_vcf`),
not the downstream annotated cohort copy. Samples are haploid (single-allele GTs), so the fixture
meta uses `ploidy:1`.

### `joint_soft_filtered.vcf.gz` (+ `.tbi`) — 2-sample, faithful

A verbatim copy of the real joint VCF (2 samples, 100 records; splits to CBR 69 / NODRUG 89 non-ref):

```bash
SRC=output_ottilie_test/variant_calling/haplotypecaller/joint_variant_calling/HaplotypeCaller_joint_calling_soft_filtered.vcf.gz
cp "$SRC" tests/fixtures/joint_soft_filtered.vcf.gz
bcftools index -t -f tests/fixtures/joint_soft_filtered.vcf.gz
```

### `joint_soft_filtered_single_sample.vcf.gz` (+ `.tbi`) — 1-column, **synthetic**

A single-column subset of the 2-sample VCF above (CBR only, 100 sites; splits to 69 non-ref),
used to exercise the single-column-joint code path (`.combine` with a 1-element cram channel):

```bash
bcftools view -s Ottilie_test_CBR110-15-R3a --force-samples "$SRC" \
    -Oz -o tests/fixtures/joint_soft_filtered_single_sample.vcf.gz
bcftools index -t -f tests/fixtures/joint_soft_filtered_single_sample.vcf.gz
```

> **Caveat — this is a column subset, NOT a genuine single-sample joint-calling run.**
> `bcftools view -s` keeps every cohort site (including sites only variant in the other sample,
> where CBR is reference), so it has the same 100 sites as the 2-sample VCF. A real one-sample
> GATK joint run would call its own site set. This fixture validates SPLIT_JOINT_VCF's *plumbing*
> on a 1-column input; it does not reproduce the real single-sample-joint scenario (that case is
> hand-verified in `docs/compare_single_pop_HpCaller/README.md`).

### `joint_manta_diploid_sv.vcf.gz` (+ `.tbi`) — 2-sample joint Manta, **two edited genotypes**

The `--joint_manta` diploid SV VCF of the 2-sample set (18 records, all PASS, both samples
genotyped at every record), with two CBR110 genotypes hand-edited so the Manta split's drop rule is
exercised (the real file has no hom-ref row): `I:206105` → `0/0:HomRef`, `IV:465972` → `./.`.
Splits to CBR 16 / NODRUG 18; CBR keeps its two genuine `0/1 FT=MinGQ GQ=10` breakends, which the
split promotes to `FILTER=MinGQ`.

```bash
# joint run, e.g.: nextflow run main.nf -profile ottilie_test,azureD4as,docker --step variant_calling \
#   --tools manta --joint_manta --joint_germline false --input <cram samplesheet>
SRC=<outdir>/variant_calling/manta/Ottilie_test/Ottilie_test.manta.diploid_sv.vcf.gz
python - "$SRC" <<'PY'
import gzip, sys
out, n = [], 0
for l in gzip.open(sys.argv[1], "rt").read().splitlines():
    if l.startswith("#"): out.append(l); continue
    f = l.split("\t"); n += 1
    s = f[10].split(":")                       # column 11 = Ottilie_test_CBR110-15-R3a
    if n == 1: s[0], s[1] = "0/0", "HomRef"
    if n == 2: s[0] = "./."
    f[10] = ":".join(s); out.append("\t".join(f))
open("joint_manta_diploid_sv.vcf", "w").write("\n".join(out) + "\n")
PY
bcftools view -Oz -o tests/fixtures/joint_manta_diploid_sv.vcf.gz joint_manta_diploid_sv.vcf
bcftools index -t -f tests/fixtures/joint_manta_diploid_sv.vcf.gz
```

## `fastp_R1.fastq.gz`, `fastp_R2.fastq.gz` — read-preprocessing module test

Used by `tests/fastp_preprocessing.nf.test`. The first 1 000 read pairs of the ottilie evolved clone
CBR110-15-R3a (`data/ottilie/fastq_test/`, real Nextera adapter read-through and real HiSeq 2500
qualities), with two synthetic edits so one small pair exercises every preprocessing step: read names
rewritten to a NovaSeq-style instrument prefix (`@A00123:…`, so fastp's read-name poly-G auto-detection
would fire if not disabled) and a 15-base Q2 poly-G tail appended to every read. Regenerate:

```bash
D=data/ottilie/fastq_test
for r in 1 2; do zcat $D/CBR110-15-R3a_chrI_IV_VII_XV_R$r.fastq.gz | head -4000 \
  | awk -v r=$r 'NR%4==1{n++; $0="@A00123:45:HXXXXDSXX:1:1101:"n":1000 "r":N:0:ACGTACGT"} NR%4==2{$0=$0"GGGGGGGGGGGGGGG"} NR%4==0{$0=$0"###############"} {print}' \
  | gzip -n > tests/fixtures/fastp_R$r.fastq.gz; done
```

`fastp_sra_R1.fastq.gz`, `fastp_sra_R2.fastq.gz`: the same reads with SRA-style names
(`@SRR10985585.<n> <n> length=100`), so the pair of fixtures isolates fastp's read-name poly-G
auto-detection (fires on the NovaSeq-named pair, never on this one). Same recipe with the
`NR%4==1` rewrite replaced by `$0="@SRR10985585."n" "n" length=100"`.

## FASTQC_TRIMMED_QC (`tests/fastqc_trimmed.nf.test`)

### `fastp_shards/000{1..4}.fx_{1,2}.fastp.fastq.gz` — the `fastp_sra` pairs as fastp-named shards, **synthetic**

The split case of the post-trim FastQC subworkflow needs a lane that fastp emitted as several shards
(`--split_by_lines`, i.e. `split_fastq > 0`), named `<NNNN>.<prefix>_<mate>.fastp.fastq.gz`. fastp
cannot make them from the 1 000-pair fixture — it hands out reads to shard files in packs of 1 000, so
everything lands in `0001` — hence the cut is done by hand: 400 / 400 / 200 pairs, plus `0004`, an
**empty 0-byte pair**, because fastp really leaves those behind (it pre-creates one shard file per
writer; measured 2026-09-23 with fastp 0.23.4: `--thread 3` on 1 000 pairs → `0001` full, `0002`–`0004`
0 bytes). Names and per-shard read counts are all the subworkflow depends on.

```bash
cd tests/fixtures/fastp_shards
for m in 1 2; do zcat ../fastp_sra_R$m.fastq.gz | split -l 1600 -d -a 4 --numeric-suffixes=1 --additional-suffix=.fx_${m}.fastq - ""; done
for f in 0*.fx_*.fastq; do gzip -n -9 "$f"; mv "$f.gz" "${f%.fastq}.fastp.fastq.gz"; done
: > 0004.fx_1.fastp.fastq.gz; : > 0004.fx_2.fastp.fastq.gz
```

## PREFLIGHT_REFERENCE (`tests/preflight_reference.nf.test`)

### `preflight_reference/ref.fa`, `genes.gff3`, `genes_renamed.gff3`, `genes_partial.gff3` — **hand-made**

A three-contig FASTA (`chrA` 60 bp, `chrB` 40 bp, `plasmid` 30 bp; the chromosome headers carry an
Ensembl-style description so the first-token rule is exercised, and the plasmid stands for an
engineered contig the annotation never mentions) plus three GFF3 files, for the FASTA-vs-GFF3
contig-name check of `bin/preflight_reference.sh`:

- `genes.gff3` — gene/mRNA/CDS on `chrA`, a gene on `chrB`, then an embedded `##FASTA` section with a
  contig `chrZ` that must be ignored (SGD and GenBank-converted GFF3 files carry one) → OK;
- `genes_renamed.gff3` — the same features on `A` and `B`, no shared name → ERROR, exit 65;
- `genes_partial.gff3` — the `chrA` features plus a gene on `chrC`, which has no FASTA sequence → OK,
  with `chrC` noted in the row (a GFF3 with more contigs than the FASTA is the test set's own situation).

Written by hand (a few lines each); the two variants were derived from `genes.gff3`:

```bash
cd tests/fixtures/preflight_reference
sed 's/^chr\([AB]\)\t/\1\t/; s/^##sequence-region chr/##sequence-region /' genes.gff3 > genes_renamed.gff3
{ grep -v '^chrB' genes.gff3 | grep -v '^##FASTA' | grep -v '^>' | grep -v '^ACGT' | grep -v '^$';
  printf 'chrC\ttest\tgene\t1\t50\t.\t+\t.\tID=gene:G3;Name=G3\n'; } > genes_partial.gff3
```

The same script run on the real ottilie reference (not committed, `data/ottilie/S288C_reference/`)
gives OK on 17/17 contigs, ERROR on a copy of `S288C_R64.gff3` with a `chr` prefix added to column 1,
and an OK row noting `Mito, XVI` when those two contigs are removed from the FASTA (checked 2026-09-28).

### `preflight_reference/mito.fa`, `mito_chrz.fa` — **hand-made** (2026-11-09)

Two header-only-sized FASTAs (10 bp per contig; the cache check reads headers only) for the second check of
`bin/preflight_reference.sh`, the FASTA's contig names against the pre-built snpEff database's, run against
the Mito-only fixture cache `snpeff_cache_mito/with_codon_table/` (database `S288C_mito`, one chromosome
`Mito`): `mito.fa` (`Mito`, with a description after the name) → OK, exact; `mito_chrz.fa` (`Mito` + `chrZ`)
→ WARN naming `chrZ`; the three-contig `ref.fa` above → ERROR, no shared name. The subset case (OK with a
note) uses the shipped test cache and FASTA of the ottilie profile instead, like the codon-table test.

## VARIANTFILTRATION_FALLBACK (`tests/variantfiltration_fallback.nf.test`)

### `joint_germline_unfiltered.vcf.gz` (+ `.tbi`) — 2-sample, faithful, **unfiltered**

The GenotypeGVCFs output of the 2-sample test set *before* the soft filter: the real input of
`VARIANTFILTRATION_FALLBACK` (100 records, 61 SNPs / 39 indels by GATK's typing, FILTER `.` on every
record; FS, SOR, MQ, QD on all 100, MQRankSum / ReadPosRankSum on 28). Cut from the e2e output of
2026-09-24 (trimming on, the current recipe). A verbatim copy:

```bash
SRC=output_ottilie_test/variant_calling/haplotypecaller/joint_variant_calling/joint_germline.vcf.gz
cp "$SRC"      tests/fixtures/joint_germline_unfiltered.vcf.gz
cp "$SRC.tbi"  tests/fixtures/joint_germline_unfiltered.vcf.gz.tbi
```

The test pins the FILTER string of every record. The expected strings were re-derived from the INFO
fields under the thresholds in `conf/modules/joint_germline.config` and agree with GATK's own
`HaplotypeCaller_joint_calling_soft_filtered.vcf.gz` of the same run on all 100 records (83 PASS,
14 `MQ_filter`, 2 `SOR_FS_filter`, 1 `MQ_filter;QD_filter`; GATK joins several tags alphabetically).
After a recipe change that moves the joint VCF, re-cut the fixture **and** re-derive the map; do not
copy a FILTER tally from another run's VCF.

> **Caveat — `joint_soft_filtered.vcf.gz` above is NOT this run's filtered output.** It was cut on
> 2026-08-31 from an untrimmed-read run; the two share the record count (100) but differ at seven
> sites, and its FILTER column still reads the retired plain `SOR_filter`. It stays the SPLIT_JOINT_VCF
> fixture (that test reads genotypes, not FILTER), but it cannot serve as an oracle for this one.

### `reference/S288C_R64_test.fa.gz` (+ `.fai`, `.gzi`, `.dict`) — the test set's reference, bgzipped, faithful

The 4-chromosome test reference (`data/ottilie/S288C_reference_test/`, from `generate_test_data.sh`,
not in the repo), bgzipped so the test runs on a fresh clone: 1.2 MB instead of 4.0 MB. GATK accepts
a bgzipped FASTA given its `.gzi`, which the module takes in its fifth input (empty in the pipeline,
which passes the plain FASTA). The `.dict` is the test set's with the local-path `UR:` field removed;
contig names and lengths match the VCF header, which is all VariantFiltration checks.

```bash
R=data/ottilie/S288C_reference_test/S288C_R64_test; D=tests/fixtures/reference
bgzip -c $R.fa > $D/S288C_R64_test.fa.gz
samtools faidx $D/S288C_R64_test.fa.gz          # writes .fai and .gzi
sed -E 's/\tUR:[^\t]*//' $R.dict > $D/S288C_R64_test.dict
```

The negative-control case uses `tests/variantfiltration_fallback_typeeq.config` (no fixture of its own).

## `cox2_mito_73925.vcf`, `cox2_chrM_73925.vcf` + `snpeff_cache_mito/` — snpEff codon-table test

Used by `tests/snpeff_codon_table.nf.test`. The VCF is one synthetic record, `Mito:73925 A>G`: the third
base of the first in-frame `TGA` of COX2 (`Q0250`, CDS 73758..74513, + strand, no intron) of the S288C
R64 mitochondrion. Under the yeast mitochondrial code it is `TGA>TGG`, Trp56Trp, synonymous; under the
standard code it is a lost stop. Hand-written; the position was derived from the cache's `sequences.fa`
(`genbank_reference_input.md` §9). `cox2_chrM_73925.vcf` is the same record with CHROM `chrM` (2026-11-09),
for the `--genbank` case built from `genbank/mito_chrM.gbff`.

`snpeff_cache_mito/{with,without}_codon_table/S288C_mito/` are two copies of one Mito-only snpEff 5.1
cache (runtime files only: `sequence.bin`, `snpEffectPredictor.bin`, `snpEff.config`; 25 KB each),
differing in the one line `S288C_mito.Mito.codonTable : Yeast_Mitochondrial`. Built from the Mito
records of the project's `R64-1-1.105` cache inputs (Ensembl release 105), so the test needs no
`data/ottilie/` for its fixture cases. Regenerate:

```bash
SRC=data/ottilie/S288C_reference_test/snpeff_cache/R64-1-1.105; W=$(mktemp -d); mkdir -p $W/data/S288C_mito
awk '/^>/{keep=($1==">Mito"); if(keep)print ">Mito"; next} keep' $SRC/sequences.fa > $W/data/S288C_mito/sequences.fa
awk -F'\t' '/^#/ || $1=="Mito"' $SRC/genes.gff > $W/data/S288C_mito/genes.gff
printf 'S288C_mito.genome : S288C_mito\n' > $W/data/S288C_mito/snpEff.config
docker run --rm -u $(id -u):$(id -g) -v $W:/w quay.io/biocontainers/snpeff:5.1--hdfd78af_2 \
  snpEff build -gff3 -noCheckCds -noCheckProtein -dataDir /w/data -c /w/data/S288C_mito/snpEff.config S288C_mito
F=tests/fixtures/snpeff_cache_mito
for v in with_codon_table without_codon_table; do
  mkdir -p $F/$v/S288C_mito && cp $W/data/S288C_mito/{sequence.bin,snpEffectPredictor.bin} $F/$v/S288C_mito/
  printf 'S288C_mito.genome : S288C_mito\n' > $F/$v/S288C_mito/snpEff.config
done
printf 'S288C_mito.Mito.codonTable : Yeast_Mitochondrial\n' >> $F/with_codon_table/S288C_mito/snpEff.config
```

## `genbank/` — GenBank reference route (`tests/genbank_reference.nf.test`, `tests/snpeff_build.nf.test`)

- `mito_ncbi.gbff`: the real `NC_001224` record of NCBI's S288C R64 assembly (`data/ottilie/S288C_reference/
  S288C_R64.gbff`, cut at its `//`): `VERSION NC_001224.1`, `/organelle="mitochondrion"`, 19 CDS with
  `/transl_table=3` and `/translation`, 11 of them joined over introns. 176 KB. `mito_ncbi.gbff.gz` is
  `gzip -k` of it.
- `mito_draft.gb`: a lab-style copy of the same record made by `make_fixtures.py`: LOCUS `mito_draft`, no
  ACCESSION, VERSION or DBLINK line, `/chromosome="M"` added to the source feature (snpEff would name the
  contig `M` without the VERSION rewrite), every `/transl_table` and `/translation` removed (a draft annotated
  by a gene caller that writes neither).
- `mito_chrM.gbff` (2026-11-09): the NCBI record with only its LOCUS renamed to `chrM`, everything else kept
  (ACCESSION, `VERSION NC_001224.1`, `/transl_table=3`, `/translation`), the user-renamed case: snpEff stores
  the contig as `M`, the codonTable line stays keyed on `chrM`, and a VCF with CHROM `chrM` still annotates
  with the mitochondrial code. Written by `make_fixtures.py`.
- `synthetic_two_records.gb`, `synthetic_duplicate_locus.gb`, `synthetic_mixed_tables.gb`,
  `synthetic_name_collision.gb`: written by `make_fixtures.py` with BioPython 1.81 from seeded random
  sequences, so every coordinate in the tests is hand-checkable. `plasmidA` (2,400 bp, `/plasmid`, three CDS
  on table 11: + strand simple; - strand `join` over a 60-bp intron, parts 199 + 200 bp; + strand with
  `codon_start=2`) and `chrB` (1,500 bp, `/chromosome="B"`, one CDS without a table); the same plasmid twice;
  the plasmid with one CDS on table 4; two records `chr1` and `1`, which snpEff stores under one name.

Regenerate everything but `mito_ncbi.gbff` (deterministic, byte-identical on a second run):

```bash
docker run --rm -u $(id -u):$(id -g) -v $PWD:/r -w /r quay.io/biocontainers/biopython:1.81 \
    python -I tests/fixtures/genbank/make_fixtures.py tests/fixtures/genbank
```

## `contig_order/` — the cohort-table scripts' `.fai` order (`tests/build_sv_matrix.nf.test`, `tests/build_contig_cn.nf.test`)

Hand-made, a few hundred bytes, written 2026-11-09 when `bin/sv_cohort_matrix.py` and `bin/contig_copy_number.py`
switched from a hard-coded roman-numeral sort list to the reference's `.fai` order
(`docs/dev-practices/genbank_reference_input.md` §5.6). The order is chosen so that neither an alphabetical sort
nor the old list could reproduce it:

| File | Content |
|---|---|
| `ref.fa.fai` | three contigs in the order **chrII, chrI, pA** (lengths 500 000 / 300 000 / 5 000; offsets are placeholders, only columns 1-2 are read) |
| `sv_cohort_merged.vcf` | four records in the shape of the SVDB cross-caller cohort VCF (`docs/variant-calling/sv_merge.md`): a Manta-only DEL on chrI (S1 0/1 PASS), a TIDDIT-only DUP:TANDEM on chrII (S1 key present, GT 1/1), a Manta+TIDDIT BND chrII:100 → pA:50 (S2 0/1 with FT `MinGQ`: Manta support in the union view only, TIDDIT in both), a Manta INS on pA in both samples. Sample columns `Exp_S1`, `Exp_S2` (the `<patient>_<sample>` form the script matches by suffix) |
| `S1.tiddit.ploidies.tab`, `S2.tiddit.ploidies.tab` | TIDDIT's per-contig table (`Chromosome Ploidy Ploidy_rounded Mean_coverage`); S2 carries an extra contig `chrZ` that the `.fai` lacks, which must come last with empty S1 cells |

Expected rows (union view): chrII:100, chrII:2000, chrI:1000, pA:10; contig table: chrII, chrI, pA, chrZ.
