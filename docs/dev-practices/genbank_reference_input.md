# Reference genome from one GenBank file: design note

**Status: design agreed 2026-11-02; O.1 (the codon-table line in today's caches, §4.3) and O.2 (the two build tasks of §5.1, module-tested) done the same day; O.3, the wiring, done 2026-11-09: `--genbank` runs both tasks before alignment, fills upstream's `fasta` / `snpeff_cache` / `report_gff3` channels and `snpeff_db`, both routes at once or neither is a start-up error, `reference/<db>/` is published, the pre-built route gained the cache-vs-FASTA preflight row, the four verdict rows reach the input-checks table in a QC-only run (`tests/genbank_route.nf.test`). O.4, the output scripts, done 2026-11-09: the two cohort-table scripts take the reference's `.fai` and follow its order (the roman-numeral lists are gone), `generate_index.py` reads the manifest's `type` column for the multi-copy contigs and has no name list any more (§5.4, §5.6). O.5, the contract test, done 2026-11-11: the three ottilie test profiles give `genbank`, the e2e snapshot is re-recorded on this route (§7), the pre-built route keeps the gate, a DAG-build test and two module cases. Not yet: the launch form (§6; O.6), the user docs (O.7) and `ottilie/v2` (O.8).** Opened 2026-10-29 from a question about why
the pipeline takes FASTA + SnpEff cache where the legacy AMP v1 pipeline took a single GenBank; reviewed
decision by decision on 2026-11-02 with the launch form and a future ALEdb registration in view. Every
number here was measured with the pipeline's own snpEff image (`quay.io/biocontainers/snpeff:5.1--hdfd78af_2`)
or CNVKit image; the commands are in §9 so the measurements can be repeated. The task itself is tracked in
`PLAN_next_checklist.md` §O and the roadmap rows under *Onboarding* (`roadmap.md`).

## 0. Decisions (2026-11-02 review)

| # | Decision | Where it is explained |
|---|---|---|
| 1 | **The contig identifier is LOCUS.** Replaces the 2026-10-29 choice of VERSION | §3 |
| 2 | **No display alias.** One name everywhere: VCF, CSV, dashboard, IGV pages, filenames. An alias stays a possible later option for a single yeast run, flagged for ALEdb | §8 |
| 3 | **A contig manifest is always published**: LOCUS, VERSION, length, sequence md5, type, chromosome number when stated, record order, plus the file checksum | §5.2 |
| 4 | **Mitochondrion and plasmids are known from the GenBank qualifiers** (`/organelle`, `/plasmid`), through the manifest's type column; the name lists `Mito`, `chrM`, `MT` go. Only the dashboard consumes this | §5.4 |
| 5 | **The builder rewrites VERSION to LOCUS in the copy it hands snpEff.** snpEff names contigs from VERSION, then `/chromosome`, then LOCUS, never ACCESSION (measured) | §3.2 |
| 6 | **Two build gates**: protein check `Errors: 0`, and the cache's contig names equal the FASTA headers | §5.3 |
| 7 | **An identifier verdict row in the yAMP input-checks table**: OK, with a note naming the records without a versioned accession (a lab-made file is a first-class input; revised 2026-11-09, it was a WARN), ERROR on duplicate or unparseable names. Runs in the QC-only path by construction | §5.5 |
| 8 | **Order of work**: codon-table fix in today's caches first, then builder, wiring, output scripts, form, docs, test data `ottilie/v2` last | `PLAN_next_checklist.md` §O |
| 9 | **The build runs inside the pipeline**, two tasks on stock biocontainers, published under `reference/`; `--genbank x --build_only_index` is the standalone mode. The snpEff build task is written in nf-core shape for a later `snpeff/build` contribution (nf-core has `snpeff/download` and `snpeff/snpeff` only, re-checked 2026-11-02) | §5, §8 |
| 10 | **`snpeff_db` on the GenBank route = the file's basename**; `--snpeff_db` stays as an override | §6 |
| 11 | **The pre-built route stays** (`fasta`, `snpeff_cache`, `snpeff_db`, `report_gff3`): it is upstream sarek code, removing it would grow the rebase diff, and older runs stay reproducible from their caches. **Error when both routes are given** | §6 |
| 12 | **Contig order = GenBank record order, everywhere.** The two hard-coded roman-numeral sort lists go; `.fai` order is file order, no tool sorts | §5.6 |
| 13 | **Launch form: `genbank` visible, the four pre-built fields hidden** (still settable behind the hidden-params toggle) | §6 |
| 14 | **The ottilie contract test moves to the GenBank route**; the pre-built route keeps a module test | §7 |
| 15 | ALEdb (Aletechdev/aledb) holds no contig length or md5 today; the pipeline publishes the manifest regardless, the database side is later work | §3.3 |
| 16 | CNVKit's chromosome X heuristic: documented, measured in the pipeline's container, no code change; cannot be measured on the 4-chromosome test set | `docs/variant-calling/cnvkit/cnvkit_sex_chromosome_heuristic.md` |
| 17 | Gzipped GenBank input works for both snpEff and BioPython (measured), so `.gz` is accepted at no cost; low priority either way | §9 |
| 18 | **`/transl_table` flow (2026-11-02, while building O.2):** one `codonTable` line per contig whose table is not 1, keyed on LOCUS, plus a `transl_table` manifest column. **Absence is the standard code** (the INSDC default; NCBI's S288C file states no table on any nuclear CDS), silently; an **organelle** contig without a table gets a WARN (standard assumed, run proceeds); mixed tables on one contig or a number snpEff has no table for is an ERROR. The build's protein check is skipped only when the file has no `/translation` | §4.3, §5.5 |
| 19 | **snpEff simplifies stored chromosome names** (measured 2026-11-02): a leading `chr` / `chromo` / `chromosome` (any case) and leading zeros are stripped, `chrB` is stored as `B`; a VCF's CHROM is simplified the same way, so outputs keep LOCUS and still annotate. Gate 2 compares against the simplified expectation; two LOCUS names that collapse to one are an ERROR; a record without any feature is dropped from the database | §3.2, §5.3 |

## 1. Why one GenBank is enough, for every microbe

The Tier-1 tools (bwa-mem2, HaplotypeCaller, CNVKit, Manta, TIDDIT, igv-reports) read a FASTA and its
indexes. Annotation (snpEff) reads a pre-built database directory. Neither reads GenBank, which is why the
sarek-derived pipeline splits the reference into `--fasta` + `--snpeff_cache` (+ `--report_gff3`).

GenBank is still the right *input* format, because every annotation route for a microbial genome ends in one,
or converts to one in a single step, and because sequence and features in one file agree with each other by
construction:

| Genome | Where the GenBank comes from |
|---|---|
| Prokaryote, public strain | NCBI download (`.gbff`) |
| Prokaryote, custom assembly | Bakta or Prokka (GenBank is a primary output; `--proteins <ref.gbk>` transfers names), or NCBI PGAP |
| Prokaryote, edited reference (cassette, plasmid) | the published GenBank edited in SnapGene / Benchling / Geneious |
| Yeast, same species as an annotated reference (CEN.PK vs S288C) | Liftoff maps the reference GFF3 onto the custom FASTA; FASTA + GFF3 to GenBank with NCBI `table2asn` or a BioPython script |
| Saccharomycotina without a same-species reference | YGAP (synteny to S. cerevisiae) |
| Any fungus, de novo | Funannotate (GenBank via `table2asn` is its output), BRAKER3 / Helixer / AUGUSTUS (GFF3 out, convert) |

snpEff reads GenBank natively (`snpEff build -genbank`) and breseq, the Tier-2 bacterial caller, already takes
the same file through the same `--genbank` parameter. The FASTA for alignment is extracted from the GenBank in
the builder, so contig names match.

Requirements on the file: a full GenBank with the `ORIGIN` sequence for every record (feature-table-only files
cannot be built from); one record per contig; CDS features with `/translation` (standard in every source
above; snpEff uses them for the protein check, §4). The files seen on the dev VM show the spread of inputs to
expect: a stock NCBI RefSeq file (S288C: LOCUS `NC_001133`, VERSION `NC_001133.9`, `/chromosome="I"`), an
NCBI WGS scaffold set (Ogataea: `AECK01000001.1`, no `/chromosome`), a single-record bacterial genome
(E. coli: `U00096.3`), and a lab draft whose records are `chr1`..`chr16`, `mit` with no accession at all
(the CEN.PK reference breseq and ALEdb used).

## 2. What Path A does today, and what the direct build does instead

`docs/prepare_input/process_GeneBank/process_genbank_auto.sh` (user page `docs/usage/prepare_reference.md`,
Path A) never hands the GenBank to snpEff. It extracts a FASTA with `any2fasta`, writes a GFF3 with an inline
BioPython loop (one flat line per feature: no gene/mRNA/CDS parents, no phase, `join()` collapsed to the outer
span, `/gene` dropped), and builds the cache from that GFF3 with `-noCheckCds -noCheckProtein`.

Measured on the 4-chromosome S288C test GenBank (`data/ottilie_backup/S288C_reference_test/S288C_R64_test.gb`),
annotating `tests/fixtures/joint_soft_filtered.vcf.gz` (100 records) and comparing with the project's
Ensembl-built cache `R64-1-1.105`:

| Against the Ensembl cache | Path A (today) | `snpEff build -genbank` |
|---|---|---|
| Same primary effect | 89 / 100 | 91 / 100 |
| Same impact | 92 / 100 | 92 / 100 |
| Same gene symbol | 7 / 100 | 88 / 100 |
| Same HGVS.c / HGVS.p | 86 / 91 | 89 / 92 |
| Introns in the cache | 0 | 87 |
| `WARNING_TRANSCRIPT_NOT_FOUND` at build | 27 | 0 |
| Protein check | skipped | 1946 OK, 0 errors, 3 not found |
| Build time | 19 s | 3 s |

The 4 truth SNVs (RPO21, TRR1, ROG1, YRR1) are identical in all three. EFB1 (YAL003W, two exons) is stored as
one CDS span by Path A and as two CDS + one intron by the direct build, exactly like the Ensembl cache. The 9
sites where the direct build still differs from the Ensembl cache are annotation-set differences (NCBI omits
dubious ORFs such as YAL004W; the Ensembl GFF3 treats a few tRNAs as coding), and both GenBank routes agree
with each other there. Transcript ids become RefSeq `NM_…` accessions; gene ids and symbols are unchanged.

**Conclusion:** the builder calls `snpEff build -genbank` on the GenBank and keeps a GFF3 conversion only
for `--report_gff3` (the dashboard's gene track). These annotation differences are what the contract-test
snapshot will show when the test moves to the GenBank route (§7).

## 3. Contig names: LOCUS is the identifier

### 3.1 Why LOCUS, not VERSION (decision 2026-11-02, replacing 2026-10-29)

On NCBI files VERSION is LOCUS plus the sequence version suffix (`NC_001133` vs `NC_001133.9`); on lab files
VERSION is empty or equals LOCUS. The 2026-10-29 choice of VERSION valued the suffix: `.8` and `.9` are
different sequences. The database view reverses the weighing:

- **breseq writes LOCUS** as its sequence id, so the Tier-2 bacterial output of the same run and every legacy
  AMP v1 record use that spelling.
- **ALEdb keys on LOCUS.** Its *Reference Seq* column holds `chr13`, `mit`: the breseq names of the lab
  reference (`quality_control/qc_control_sample_v2/data/Mutations_Dev_Yeast_Adipic_Acid.csv`). A VCF row with
  the LOCUS name lands on the string the database already has; a VERSION name would give one chromosome two
  spellings inside one run and one database.
- **LOCUS is the only name a lab-made GenBank reliably has.**

The sequence version is not lost, only moved to where a database wants it: the manifest records VERSION,
length and md5 per contig and the file checksum (§5.2). Rule: identifier = LOCUS; the preflight row notes when
no accession is present (§5.5).

### 3.2 Gotcha 1, measured: who names the contig, and the rewrite that fixes it

The two readers Path A relies on disagree, and snpEff has a fallback chain of its own. Measured 2026-11-02 on
records chr I and Mito of the stock NCBI S288C file, five variants of the same two-record file (§9):

| Variant | Name snpEff gave chr I | Name for Mito |
|---|---|---|
| A: stock NCBI file (`VERSION NC_001133.9`) | `NC_001133.9` | `NC_001224.1` |
| B: VERSION rewritten to equal LOCUS | `NC_001133` | `NC_001224` |
| C: VERSION line removed | `I` | `NC_001224` |
| D: VERSION and `/chromosome` removed | `NC_001133` | `NC_001224` |
| E: as D, ACCESSION renamed to a dummy | `NC_001133` | `NC_001224` |
| G: variant B, gzipped (`genes.gbk.gz`) | `NC_001133` | `NC_001224` |

So snpEff uses **VERSION, then the `/chromosome` qualifier, then LOCUS, and never ACCESSION**. `any2fasta`
uses LOCUS. Variant C is the nasty one for a hand-made file: no VERSION line but `/chromosome="3"` gives a
cache named `3` against a FASTA header `chr3`, and snpEff then annotates **nothing, with no error**
(nf-core/sarek #415). The test GenBank did not show any of this because
`02_reference_prep/rename_genbank_chromosomes.sh` had set LOCUS and VERSION both to `I`, `IV`, `VII`, `XV`.

**The fix is one line per record.** The builder writes the FASTA and GFF3 from its own parse with the LOCUS
name (BioPython `record.name`; `record.id` is VERSION), and hands snpEff a *copy* of the GenBank whose
VERSION line is set to the LOCUS name. VERSION wins the chain above, so the cache name equals LOCUS in every
variant. The user's file is never touched; the copy is a build intermediate. The second build gate (§5.3)
asserts the result. **This wiring is a convention future work must keep**: whoever writes a contig name
into a FASTA, a GFF3, a config line or a manifest must take it from LOCUS, and whoever hands snpEff a GenBank
must rewrite VERSION first. Recorded in `SAREK_MODIFICATIONS.md` when the builder lands.

**A third rule, found by the O.2 module tests (2026-11-02): snpEff simplifies the name it stores.** On 18
LOCUS spellings built in the 5.1 container (`ChromosomeSimpleName`): leading zeros, then a leading
`chromosome` / `chromo` / `chr` in any case and an underscore after it are stripped, repeatedly; a name
that would become empty is kept. So `chr01`, `Chromosome_7`, `chromoX`, `CHR9`, `chr_B`, `0chr5` and
`Chr007` are stored as `1`, `7`, `X`, `9`, `B`, `5` and `7`, while `chrom1` becomes `om1`, `chr` stays
`chr`, and `scaffold_3`, `Mito`, `MT`, `NC_001224` are unchanged. A VCF's CHROM goes through the same
function at annotation time: a record on `chrB` annotates against the stored `B` and keeps `chrB` in the
output, an unknown name reads `ERROR_CHROMOSOME_NOT_FOUND`. Consequences: outputs keep the LOCUS name
everywhere (the convention above holds), the second build gate compares the stored names with the
*simplified* FASTA headers, and two LOCUS names that collapse to one (`chr1` and `1`) are an ERROR
in the extract task, since the cache would merge them. One more: a record with no feature at all is
removed by the build ("Remove empty chromosomes"); one `source` feature is enough to keep it, and the
expected list leaves such records out. `bin/genbank_to_reference.py` carries the function and its 19
measured cases are a test.

### 3.3 What this means for ALEdb registration

Nothing done now has to be undone then. The contig name matches. The work a future registration does need is
independent of the naming choice: a reference record per strain (the manifest), a converter from VCF rows
(REF, ALT, anchor base, left-aligned) to breseq-shaped rows (`C→T`, `Δ3 bp`, `(A)12→13`, gene, intergenic
distance), and the position shift for indels (VCF anchor base, so the deleted run starts at POS + 1). ALEdb
holds no contig length or md5 today; adding them is database-side work, and LOCUS keeps the simple
name-based match working until then.
The manifest exists only on the GenBank route; a pre-built-route output is registered from its FASTA's `.dict`
(`M5:` tags, same md5) or by recomputing the md5 from the FASTA (§5.2).

## 4. Gotcha 2: the genetic code (`/transl_table`) is not applied unless you say so

This is the one to come back to. It has three parts: what the problem is, where snpEff takes the genetic code
from, and what to change.

### 4.1 The biology

A GenBank CDS feature carries `/transl_table=N`, the NCBI genetic-code number that was used to produce its
`/translation`. Table 1 is the standard code. Microbial genomes routinely use others:

- **Yeast and fungal mitochondria** (table 3 in *Saccharomyces*, table 4 in most filamentous fungi): `TGA` is
  tryptophan, not stop; in table 3 `CTN` codons are threonine, not leucine, and `ATA` is methionine.
- **Mycoplasma / Spiroplasma** (table 4): `TGA` is tryptophan.
- **CTG-clade yeasts** such as *Candida albicans* and *Debaryomyces* (table 12): `CTG` is serine, not leucine.
- **Bacteria** (table 11): same amino acids as table 1; the difference is the set of allowed start codons
  (`GTG`, `TTG`, …), which decides `start_lost` calls.

If snpEff translates a table-3 gene with table 1, every `TGA` codon reads as a stop, so a synonymous change at a
tryptophan codon is reported as `stop_lost`, every missense near one gets a wrong `p.` string, and real
nonsense variants can hide.

### 4.2 Where snpEff takes the genetic code from (measured)

snpEff **ignores `/transl_table`** when it reads a GenBank. The genetic code is a *configuration property per
contig*, `<db>.<contig>.codonTable : <name>`, and it is applied **at annotation time**, not stored in the
built database. Four runs on a synthetic variant prove both halves. The variant is `NC_001224.1:73925 A>G`
(`Mito:73925` in Ensembl naming): the third base of the first in-frame `TGA` codon of COX2, a gene with no
intron on the + strand. Under table 3 this is `TGA>TGG`, Trp to Trp, synonymous. Under table 1 it is a lost stop.

| # | Cache | Config at annotation time | Result |
|---|---|---|---|
| a | built from the full GenBank | `-c` config with `s288c_full.NC_001224.1.codonTable : Yeast_Mitochondrial` | `synonymous_variant` `p.Trp56Trp` |
| b | same cache | `-dataDir` only (how the pipeline's `SNPEFF_SNPEFF` module runs), per-genome config holds **only** the `.genome` line | `stop_lost` `p.Ter56Trpext*?` |
| c | same cache | `-dataDir` only, the `codonTable` line added to `<dataDir>/<db>/snpEff.config` | `synonymous_variant` `p.Trp56Trp` |
| d | the project's Ensembl cache `R64-1-1.105`, as the pipeline ships it | `-dataDir` only | `stop_lost` `p.Ter56Trpext*?` |
| e | a copy of (d) with `R64-1-1.105.Mito.codonTable : Yeast_Mitochondrial` appended to `R64-1-1.105/snpEff.config` | `-dataDir` only | `synonymous_variant` `p.Trp56Trp` |

Reading of the table:

- (a) vs (b): the same `.bin` files give different answers, so the genetic code is **not inside the database**.
- (b) vs (c): snpEff reads the per-genome config `<dataDir>/<db>/snpEff.config` in addition to the bundled one,
  and honours `codonTable` from there. That file is already one of the "runtime files" every shipped cache
  carries (`prepare_reference.md`), so the fix needs no change to the module or to `nextflow.config`.
- (d) vs (e): **the pipeline mis-annotates mitochondrial variants today.** The Ensembl-built cache has no
  `codonTable` line (its `snpEff.config` is the single `.genome` line). 59 CDS lines on `Mito` in its
  `genes.gff` are translated with the standard code. The 2-sample test set has no Mito contig, so the contract
  test cannot see it; the 4-sample pilot and every real run can.

The build-time protein check shows the same thing from the other side: on the full GenBank, the check reports
`Errors: 19` without the line (exactly the 19 CDS with `/transl_table=3`) and `OK: 6021, Errors: 0` with it.
One detail for the builder only: when `-c` points at a *replacement* config, that file must also contain
snpEff's `codon.<Name> : …` table definitions (25 lines in the bundled `snpEff.config` of 5.1), or the build
stops with `No such codon table`. At pipeline time the bundled config is primary and already has them.

### 4.3 The fix

**For the builder (the GenBank-only task):**

1. Parse `/transl_table` from every CDS; group by contig; error if a contig mixes tables (never seen, but cheap).
   A CDS without the qualifier is table 1 by the INSDC rule (`/transl_table=1` may be omitted, and NCBI's
   S288C file omits it on every nuclear CDS), so absence is the standard code and says nothing; an organelle
   contig without any table is the one case that warns (decision 18).
2. Map the NCBI number to snpEff's table name and write `<db>.<contig>.codonTable : <name>` for every contig
   whose table is not 1 into `<cache>/<db>/snpEff.config`, next to the `.genome` line. The `<contig>` key is
   the LOCUS name (§3).
3. Run `snpEff build -genbank` and **fail the build unless the protein check reports `Errors: 0`** (a few
   `Not found` are normal: pseudogenes and CDS without `/translation`). That one number is the acceptance test
   for the gene models *and* for the codon tables.

Mapping, from snpEff 5.1's bundled config (verify each name in `snpEff.config` before relying on it; the number
assignment is NCBI's naming, the snpEff names are what the file lists):

| `/transl_table` | snpEff `codonTable` name | Where it occurs |
|---|---|---|
| 1 | `Standard` (default, no line needed) | nuclear genomes |
| 2 | `Vertebrate_Mitochondrial` | not microbial |
| 3 | `Yeast_Mitochondrial` | *Saccharomyces* mitochondria |
| 4 | `Mold_Mitochondrial` (snpEff also lists `Protozoan_Mitochondrial`, `Mycoplasma`, `Spiroplasma` with the same content) | filamentous fungi mitochondria, Mycoplasma |
| 5 | `Invertebrate_Mitochondrial` | not microbial |
| 6 | `Ciliate_Nuclear` | ciliates |
| 11 | `Bacterial_and_Plant_Plastid` | bacteria, plastids (start codons only) |
| 12 | `Alternative_Yeast_Nuclear` | CTG-clade yeasts (*Candida*, *Debaryomyces*) |
| 16 | `Chlorophycean_Mitochondrial` | green algae mitochondria |
| 23 | `Thraustochytrium_Mitochondrial` | thraustochytrids |

**For today's caches (independent of the GenBank task, one line each):**

- `data/ottilie/S288C_reference/snpeff_cache/R64-1-1.105/snpEff.config`, the pilot's cache and the published
  cache tarball: append `R64-1-1.105.Mito.codonTable : Yeast_Mitochondrial`.
- `docs/prepare_input/build_snpeff_cache.sh` (Path B): add an optional argument or a detection step for the
  mitochondrial contig name so a rebuilt cache carries the line.
- Under the §13 rule (`testing_best_practices.md`) this is a provenance event for any mitochondrial variant
  already quoted from a pilot; nuclear annotations are unaffected.

**Done 2026-11-02 (plan §O.1):** the line is in both local caches (`S288C_reference` and `S288C_reference_test`,
which are the same cache; parent and per-genome config); `build_snpeff_cache.sh` takes
`CODON_TABLES=contig=Table,...`, validated against the image's `codon.<Table>` list before the build and
appended after it, because a `codonTable` line in the build's `-c` replacement config triggers the
`No such codon table` stop described above (the bins do not depend on the line: rebuilt with the variable,
all four files equal the shipped cache). `04_validate/README.md` carries the provenance note; the only
mitochondrial site in the pilot results, `Mito:53278`, is intergenic. The `ottilie/v1` blob caches wait
for O.8, so cloud runs keep the standard code on Mito until then.

### 4.4 Unit test to carry along

The synthetic COX2 variant of §4.2 is the test: one VCF line, annotate with the cache under test using
`-dataDir` only, expect `synonymous_variant` and `p.Trp56Trp`. It fails on any cache that lost the line and on
any snpEff upgrade that changes where the config is read. It runs in seconds in the snpEff container.
Implemented 2026-11-02 as `tests/snpeff_codon_table.nf.test` (3 cases, ~85 s; a 4th on 2026-11-09 runs the `--genbank` chain on a record renamed `chrM`): the shipped cache through the
pipeline's own module and config, plus a committed 25 KB Mito-only cache with and without the line, the
latter the negative control (`stop_lost p.Ter56Trpext*?`), so the mechanism is tested on a fresh clone and
the shipped artefact on the dev machine.

## 5. The build, end to end

### 5.1 Flow

1. **Input.** One GenBank from `--genbank` (the launch form's only visible reference field, §6). Published
   untouched under `reference/`, with its checksum, as the reference record of the run.
2. **Extract task** (BioPython biocontainer). One parse of the file produces: the FASTA with LOCUS headers;
   the GFF3 with LOCUS sequence ids, `Parent` links and phase (the gene track only, nothing annotates from it);
   the contig manifest (§5.2); `snpEff.config` with the `.genome` line and one `codonTable` line per
   non-standard contig keyed on LOCUS (§4.3); and the snpEff input copy with VERSION set to LOCUS (§3.2).
3. **Build task** (snpEff biocontainer). `snpEff build -genbank` on that copy, in the flat `<db>/` layout the
   module expects. Two gates (§5.3). Written in nf-core module shape (`meta.yml`, nf-test) so it can be offered
   as `snpeff/build` later; the extract task is bespoke and stays local.
4. **Preflight row.** The manifest yields the identifier verdict in the *yAMP input checks* table (§5.5).
5. **Downstream, unchanged.** FASTA into `PREPARE_GENOME` and alignment; cache into `SNPEFF_SNPEFF` with
   `-dataDir`; GFF3 into the report gene track; manifest into `GENERATE_INDEX` (§5.4, §5.6). Published next to
   the reference: `reference/<db>/` holds FASTA, GFF3, cache and manifest, always, not only with
   `save_reference`, so a run's output is self-describing and `--build_only_index` is the standalone builder.

Both tasks sit before alignment, cost seconds (3 s for the 4-chromosome build, a few seconds for the full
S288C file), cache under `-resume`, and join the QC-only allow-list in `tests/qc_gate.sh`.

### 5.2 The contig manifest

One CSV per reference, `reference/<db>/contig_manifest.csv`, one row per record in file order:

| Column | Source | Note |
|---|---|---|
| `contig` | LOCUS | the identifier every output carries |
| `version` | VERSION | empty when the file has none; the sequence version lives here, not in the name |
| `length` | ORIGIN | |
| `md5` | ORIGIN, upper-cased sequence | the VCF `##contig` `md5=` convention; lets a database match a contig regardless of its local name |
| `type` | `/organelle` → `mitochondrion` (or the qualifier's value), `/plasmid` → `plasmid`, `/chromosome` → `chromosome`, else `other` | the only Mito signal the dashboard uses (§5.4) |
| `chromosome` | `/chromosome` qualifier | empty on lab drafts, scaffolds, single-record bacteria; informational |
| `transl_table` | the CDS `/transl_table` of the record | `3`, `11`, …; `1` when none is stated (INSDC default); `1 (assumed)` on an organelle contig without one (the WARN of §5.5); empty for a record without CDS |
| `order` | record index | the order every table follows (§5.6) |

Plus a header comment with the GenBank file name and its sha256. This is the reference record a future ALEdb
registration keys on (§3.3).

**The pre-built route produces no manifest, by decision (user, 2026-11-10): an output of that route carries no
accession and no sequence md5 anywhere.** `save_reference` is off by default, so neither the `.dict` nor the
`.fai` the run builds is published. A registration of such an output keys on the sequence md5 computed from the
FASTA the run was given (its path is in the parameter summary), or from the `.dict` next to that FASTA: GATK's
`M5:` tag is the same md5 of the upper-cased sequence (checked on the test reference, all four contigs equal
the manifest convention). `--save_reference` publishes `reference/dict/` and `reference/fai/` with the run when
that is wanted. The gap closes as the profiles move to the GenBank route (O.5, O.6).

### 5.3 The two build gates

1. **Protein check `Errors: 0`** from `snpEff build -genbank` (`Not found` entries are allowed). Catches broken
   gene models and a missing codon-table line in one number.
2. **Cache contig names equal the expected list.** `snpEff dump -bed` lists the cache's contigs; the set must
   equal the list the extract task derives from the same records: the FASTA headers after snpEff's name
   simplification (decision 19), minus records without any feature. This is the silent-failure case of §3.2
   turned into a stop; it also pins our model of snpEff's naming, which is what O.2 got wrong first.

Either failing stops the run with a readable message before alignment.

### 5.4 Mitochondrion and plasmids: from the manifest, not from names

The only computation in the pipeline that cares which contig is mitochondrial is in the dashboard's *Whole
chromosomes* table: a multi-copy contig is coloured and labelled gain or loss against the cohort median of
its fold change, not against 1, because mtDNA sits at tens of copies (`index.html.j2` around line 984). CNVKit
drops the contig by its GC mask whatever it is called (`cnvkit_gc_bin_mask.md`) and TIDDIT reports every
contig, so no caller changes. `generate_index.py` reads the manifest's `type` column (done 2026-11-09, O.4:
`--contig-manifest`, handed down from `GENBANK_REFERENCE` through `MUTATION_REPORT` to `GENERATE_INDEX`;
the standalone `generate_mutation_report.nf` picks it up from `reference/*/contig_manifest.csv` in the outdir):
every type other than `chromosome` and `other`, that is an organelle value such as `mitochondrion`, and `plasmid`,
gets the cohort-median rule, everything else the baseline of 1. A file without qualifiers yields `other` for
every contig and the mitochondrial cell then reads as a gain in every sample, which is what the data says; no
guessing from names. On the pre-built route there is no manifest at all and the same holds for Mito (user
decision 2026-11-09: no name-list fallback; dropping the special case from the table altogether is a later
review item, `roadmap.md` → dashboard follow-ups). The `MITO_CONTIGS` list and the template's fallback list
are gone; the table's legend and the Methods section say which rule applied to the run.

### 5.5 The identifier verdict row

One more row in the *yAMP input checks* MultiQC table (same id and header as `PREFLIGHT_REFERENCE`; keep the
two identical), written by the extract task from the manifest, so it runs under `--qc_only` by construction:

- **OK** in every case that is not an ERROR. When every record has a versioned accession (VERSION present
  and different from LOCUS) the row says so.
- **OK with a note** listing the records without one (VERSION empty or equal to LOCUS): a database
  registration matches those contigs by sequence md5 from the contig manifest. No console line. This was a
  WARN until 2026-11-10 (user decision 2026-11-09): a file made in SnapGene or Benchling, or written by
  Prokka, has LOCUS == VERSION or no VERSION as a matter of course, so it is a first-class input, and a warning
  on every such run would be noise about a database detail the manifest already records. The release test
  GenBank is such a file (`rename_genbank_chromosomes.sh` set both lines to `I`, `IV`, `VII`, `XV`) and stays
  as it is: it is the lab-draft case, and the zero-console-lines rule of the test profile holds on this route.
- **ERROR** when two records resolve to the same identifier (also after snpEff's simplification, decision 19),
  or an identifier contains a colon, pipe or
  whitespace. Those break the SV mate parser (`sv_cohort_matrix.py`), the IGV cross-links
  (`custom_template_sample.html`) and samtools region strings, so the run stops. Dots are safe everywhere
  (checked 2026-11-02 across `bin/`, the report code and the interval logic); the one hazard was
  `intervals.simpleName`, which cuts at the first dot and could collide two interval chunks of one contig
  under a user BED. Whole-contig intervals built from the `.fai` never collide. Fixed 2026-11-09 (O.3): the
  five `ext.prefix` closures in `conf/modules/mpileup.config` and `prepare_recalibration.config` and the
  interval-name meta of `bam_variant_calling_sentieon_dnascope` read `baseName`, as every other caller did
  ("four configs" in the 2026-11-02 count was two configs and one subworkflow).

A second row, *GenBank genetic code* (decision 18): **OK** listing the non-standard contigs and their snpEff
table names; **WARN** for an organelle contig whose CDS state no `/transl_table` (standard assumed, with the
instruction to add the qualifier and rerun); **ERROR** when one contig's CDS state different tables or a
table snpEff 5.1 has no name for. The build task adds two rows of its own, *snpEff build: protein check*
(OK / SKIPPED without `/translation` / ERROR) and *snpEff build: contig names* (§5.3). All four share the
table id and header of `PREFLIGHT_REFERENCE`; keep the copies identical.

The pre-built route got the mirror image on 2026-11-09: `PREFLIGHT_REFERENCE` now also compares the FASTA's
contig names with the database's (*snpEff cache vs FASTA contig names*; the names come from
`snpEffectPredictor.bin`, gzipped tab-separated text with one `CHROMOSOME` line per contig, and the FASTA's
are simplified the way snpEff looks them up). It is a **subset** rule, as O.1 found: the release test set is 4
chromosomes against the 17-contig cache (OK, with the 13 extra contigs noted); FASTA contigs the database
lacks are a WARN (their variants silently stay unannotated); no shared name, or no `<db>/` directory or
database file in the cache, is an ERROR. On the GenBank route the row reads SKIPPED: gate 2 is that check.

### 5.6 Contig order: the GenBank's record order, everywhere

No tool sorts. `samtools faidx` writes contigs in file order, GATK writes VCF records in reference order, the
dashboard takes its contig sequence from the order records first appear in the cohort VCF (TIDDIT row order as
fallback). The FASTA is written in record order, so the user's GenBank decides, and an NCBI file lists I to
XVI then Mito. Two scripts are the odd ones out: `bin/contig_copy_number.py` and `bin/sv_cohort_matrix.py`
sort by a hard-coded roman-numeral list, and with any other names the SV matrix puts every contig in one
bucket and interleaves rows by position. Both take `--fai` since 2026-11-09 (O.4) and follow its order, as
`bin/build_cn_matrix.py` already did; `tests/build_sv_matrix.nf.test` and `tests/build_contig_cn.nf.test` pin it
on fixtures whose `.fai` order (chrII, chrI, pA) is neither alphabetical nor roman. The index's own contig order
(`chromosomes` in the template context) is the manifest's when the run had one. A user-adjustable, cosmetic
order for the index tables is a deferred item (§8).

## 6. Launch form and the two routes

- **`genbank` becomes the first and only visible field of *Reference genome options***
  (`conf/schema_overlay.yml`: `visible`, `property_order`, a description, and a `pattern` of
  `^\S+\.(gb|gbk|gbff)(\.gz)?$`, which is also the file browser's filter). `fasta`, `snpeff_cache`,
  `snpeff_db` and `report_gff3` leave the allow-list: hidden, still settable and validated.
- **The pre-built route stays as code.** `fasta`, `snpeff_cache`, `snpeff_db` and the cache initialisation are
  upstream sarek; the GenBank route is an additive branch in `main.nf` that fills upstream's `fasta` and
  `snpeff_cache` channels and the `report_gff3` file from the builder. Older runs stay reproducible from their
  published caches.
- **Conflict rule:** `genbank` together with `fasta` or `snpeff_cache` is a start-up error naming both, never a
  silent preference.
- **`snpeff_db`** on the GenBank route is the file's basename without extension; `--snpeff_db` overrides it.
  It names the cache directory and the `reports/snpeff/` paths, nothing in a VCF.
- **breseq** keeps reading `params.genbank` as today; the parameter's description changes from "reference for
  breseq" to the Tier-1 reference input.

## 7. Validation

- **Contract test on the GenBank route (done 2026-11-11).** The three test profiles (`ottilie_test`, `_ci`,
  `_az`) give `genbank` in place of `fasta`, `snpeff_cache` and `report_gff3`, and `ottilie_common.config` no
  longer names `snpeff_db` (the paths were always in the profiles; the pilot profile keeps the pre-built files
  and names its database itself). `tests/ottilie_e2e.nf.test.snap` was re-recorded in the same commit. What
  moved, measured against a run of the previous commit on the pre-built files: 14 new output names (12 under
  `reference/S288C_R64_test/`, 2 input-checks tables), 157 tasks for 155, two new entries in the versions
  manifest; the annotation fields of §2 (RefSeq transcript ids on all 100 cohort records, another gene model or
  symbol in the first annotation of 12) in the cohort VCF, `snv_indel_sites.csv`, the eight snpEff `genes.txt`
  and eight report tables; the input-checks rows. What did not: the 100 sites, their FILTER and genotypes, the
  four truth SNVs' effect, gene and protein change, every CN and SV cohort table, every other snapshotted file.
  No record's first annotation is an intron effect, so the introns the direct build adds (§2) are not visible in
  the test set's outputs. Contig names do **not** change: the test GenBank's LOCUS lines are already `I`, `IV`,
  `VII`, `XV`. Dated row: `output_comparison.md` §2.10. Both blob accounts already hold the test GenBank under
  `ottilie/v1` (same sha256 as the local file), so the `_ci` and `_az` profiles moved without waiting for
  `ottilie/v2`; the Launchpad entry's parameters box is regenerated in the repo and must be put into the entry
  together with the push.
- **Module tests**: the build with both gates on the test GenBank; the manifest and verdict row (fixtures: the
  test GenBank, a lab-style copy without VERSION, a copy with a duplicate LOCUS); the COX2 codon-table test
  (§4.4); the pre-built route on the cache the builder produced (the last case of `tests/snpeff_codon_table.nf.test`
  and of `tests/preflight_reference.nf.test`, 2026-11-11).
- **Gate tests**: `tests/qc_gate.sh a` (new allow-list entries; `QC_GATE_PARAMS_FILE=tests/qc_gate_prebuilt_params.yml`
  for the pre-built route), `tests/preflight_reference.nf.test`.
- **Output scripts (O.4, 2026-11-09)**: `tests/build_sv_matrix.nf.test` (2 cases) and `tests/build_contig_cn.nf.test`
  (1 case) on the `contig_order/` fixtures; the e2e snapshot is unchanged because the test set's `.fai` order equals
  the old list and has no Mito. The Mito rule cannot be seen on the test set, so the evidence is the full-genome
  4-sample pilot on the pre-built route (`run_ottilie_pilot.sh`, 2026-11-09: no manifest, Mito graded against 1,
  see `PLAN_next_checklist.md` §O O.4 for what its index shows) plus a standalone render of the same bundle with
  a manifest typing Mito `mitochondrion` (Mito column *vs median*, legend names it).
- **Test data `ottilie/v2`** on both accounts as the closing package (`08_upload_test_data.sh` and
  `publish_test_data.sh` with `PREFIX=ottilie/v2`): the codon-table fix changes the full reference's cache,
  which under §13 is a new data version; `v1` stays untouched for older clones and baselines. Baseline
  2026-11-02: `az://aletest/ottilie/v1/` holds 56 blobs, the test GenBank among its four test-reference files;
  the public `v1/SHA256SUMS` answers 200. The 23 files that pin `ottilie/v1` move in one commit; one Platform run
  from the entry on `v2` is the acceptance check. Whether `v2` still ships pre-built cache directories is
  decided then.

## 8. Deferred, with the reason

- **Display alias** (`I` for `NC_001133`, from `/chromosome`): a later optional feature for a single
  yeast run. **Flag for ALEdb:** an alias must never reach a CSV or VCF, only the dashboard, or the database
  sees two spellings per contig. A chromosome number is available only on finished NCBI assemblies anyway
  (§1): lab drafts carry it in the name or nowhere, bacteria and scaffold sets have none.
- **User-adjustable chromosome order in the index tables**, cosmetic, independent of the file order the CSVs
  follow (`roadmap.md`, igvreports dashboard follow-ups).
- **ALEdb length and md5 per contig**: database-side work (§3.3).
- **nf-core `snpeff/build` contribution**: the build task is written in nf-core shape; a submission needs a
  small GenBank in nf-core/test-datasets, not checked.
- **Non-coding gene models and a GenBank plausibility check** (after O.9): the pre-built cache models every
  tRNA as protein-coding and `-genbank` gives tRNA/ncRNA genes no transcript at all; measurements, the 12
  test-set annotation differences by cause and the proposed check: [`genbank_noncoding_models.md`](genbank_noncoding_models.md).
- **Path B (`build_snpeff_cache.sh`) and Path A**: move to an appendix of `prepare_reference.md` for people
  who bring a pre-built cache; Path A's converter is retired by the builder.

## 9. Reproducing the measurements

All in the snpEff 5.1 container, as a non-root user, from a scratch directory `$W`.

```bash
IMG=quay.io/biocontainers/snpeff:5.1--hdfd78af_2
# direct build from a GenBank
mkdir -p $W/data/mydb && cp genome.gbff $W/data/mydb/genes.gbk
printf 'mydb.genome : mydb\nmydb.NC_001224.codonTable : Yeast_Mitochondrial\n' > $W/data/mydb/snpEff.config
docker run --rm -u $(id -u):$(id -g) -v $W:/w $IMG sh -c \
  'cat $(find / -name snpEff.config -path "*share/snpeff*" | head -1) | grep "^codon\." > /w/codon.cfg'
cat $W/data/mydb/snpEff.config $W/codon.cfg > $W/snpEff.config          # replacement config needs the tables
docker run --rm -u $(id -u):$(id -g) -v $W:/w $IMG \
  snpEff build -genbank -v -c /w/snpEff.config -dataDir /w/data mydb 2>&1 | grep 'Protein check'
# annotation exactly as the pipeline module does it (bundled config + per-genome config in dataDir)
docker run --rm -u $(id -u):$(id -g) -v $W:/w $IMG snpEff ann -noStats -dataDir /w/data mydb /w/in.vcf > out.vcf
# the chromosome names snpEff chose (gate 2 reads the same list)
docker run --rm -u $(id -u):$(id -g) -v $W:/w $IMG snpEff dump -bed -dataDir /w/data mydb | grep Chromosome_
```

The contig-name variants of §3.2 (2026-11-02): records 1 and 17 of `data/ottilie/S288C_reference/S288C_R64.gbff`
cut at the `//` record ends and concatenated; then, per variant, a copy of that two-record file as
`genes.gbk` with (B) `sed -E 's/^(VERSION +)([A-Z_0-9]+)\.[0-9]+/\1\2/'`, (C) `grep -v '^VERSION'`,
(D) also `grep -v '/chromosome='`, (E) also the ACCESSION line renamed, (G) variant B through `gzip` as
`genes.gbk.gz`; `snpEff build -genbank -noCheckCds -noCheckProtein` then `snpEff dump -bed … | grep Chromosome`
for the names. All six builds exit 0.

The synthetic COX2 variant: take the Mito sequence (Ensembl `Mito` = RefSeq `NC_001224`, same bases), CDS
`73758..74513` (+ strand, no intron), find the first in-frame `TGA` (at 73923), mutate its third base,
`73925 A>G`. A one-line VCF with that record and the contig name of the cache under test.

The three-way comparison of §2 was `snpEff ann` of each cache on `tests/fixtures/joint_soft_filtered.vcf.gz`,
then the first `ANN` entry's effect, impact, gene, HGVS.c and HGVS.p per record (fields 2, 3, 4, 10, 11),
counted equal or not against the Ensembl cache.

The CNVKit chromosome X measurement (decision 16) is in `docs/variant-calling/cnvkit/cnvkit_sex_chromosome_heuristic.md`.
