# SV Merge Chain (SVDB) — Maintainer Reference

Mechanics of how the Manta + TIDDIT structural-variant calls become the cohort SV VCFs and the
cohort SV matrix. Maintainer view: steps, flags, provenance keys, CSV derivation, gotchas.

> **Keep in sync** with the user-facing "SV event matrix" section of the report Methodology in
> `docs/igvreports/templates/index.html.j2`. That section explains *how to read* the matrix; this
> doc explains *how it is built*.
>
> **Evidence base.** Every step and flag here was fixed by the 2026-08-28 SVDB-vs-Jasmine bench —
> `docs/benchmarking/ottilie_xenobiotic_ale/04_validate/sv_merge_bench/NOTES.md`, findings
> **F1–F10**, referenced below as (F*n*). Do not tune flags without re-running that bench.
> The previous SURVIVOR-based chain (retired 2026-08-31) is summarised at the bottom.

## The chain

```
joint Manta VCF ──▶ MANTA_CONVERTINVERSION ──▶ COLLAPSE_SV_PAIRS ──────────────┐
(per-sample VCFs when --joint_manta off ──▶ same, then SVDB_MERGE_MANTA)       │
                                                                               ▼
TIDDIT per sample ─▶ COLLAPSE_SV_PAIRS ─▶ TIDDIT_SV_FILTER ─▶ SVDB_MERGE_TIDDIT ─▶ CHECK_SV_SAMPLE_ORDER
                                          (soft tags)        (across samples)  │
                                                                               ▼
                              SVDB_MERGE_CALLERS (--priority manta,tiddit) ──▶ BUILD_SV_MATRIX
```

Run twice, as two **views**:

| View | Inputs | Meaning |
|------|--------|---------|
| `union` | collapsed VCFs as-is | every call from either caller |
| `union_pass` | collapsed VCFs pre-filtered `bcftools view -f PASS,.` | record-level PASS calls only |

⚠️ The pass view is built by **pre-filtering the inputs**, deliberately NOT with `svdb --pass_only`:
that flag only refuses to *merge* non-PASS records — it still emits them (F2).

Wired in `subworkflows/local/mutation_report/main.nf` §5; process config in
`conf/modules/mutation_report.config`. Files:
- `modules/nf-core/manta/convertinversion` — Manta's own `convertInversion.py` + bgzip/tabix
- `modules/local/collapse_sv_pairs` + `bin/collapse_sv_pairs.py` — one record per breakend junction
- `modules/nf-core/svdb/merge` (svdb 2.8.4) — aliased `SVDB_MERGE_{MANTA,TIDDIT,CALLERS}`
- `modules/local/check_sv_sample_order` — sample-column guard for `--same_order`
- `modules/local/tiddit_sv_filter` — Manta-inspired soft filters on TIDDIT's merge input (below)
- `modules/local/build_sv_matrix` + `bin/sv_cohort_matrix.py` — the CSV builder

Published outputs (under `<outdir>/mutation_reports/data/`):

| File | Producer | Content |
|------|----------|---------|
| `sv_cohort_merged_{union,union_pass}.vcf.gz` (+ `.tbi`) | `SVDB_MERGE_CALLERS` | **the SV cohort deliverable** — one record per event, one genotype column per sample, cross-caller provenance in INFO. Filenames are load-bearing: `generate_index.py` probes them for the download buttons |
| `sv_cohort_matrix_{union,union_pass}.csv` | `BUILD_SV_MATRIX` | the matrix (below) |
| `sv_merge_inputs/<sample>.tiddit.vcf`, `sv_merge_inputs/<patient>.manta.vcf` | `COLLAPSE_SV_PAIRS` | the exact (union) merge inputs — re-merge by hand from these |
| `sv_merge_inputs/sv_tiddit_cohort_{union,union_pass}.vcf.gz` | `SVDB_MERGE_TIDDIT` | TIDDIT across samples (the L1 layer) |
| `<sample>.{manta,tiddit}.pass_stats.tsv` | `FILTER_PASS_VCF` (not part of the merge) | "PASS / all" counts for the Samples table |

The raw per-caller VCFs (`variant_calling/manta/`, `variant_calling/tiddit/`) remain the complete
troubleshooting record — every FORMAT field, pre-collapse.

## Step rationale (each verified in the bench)

1. **`convertInversion.py`** rewrites Manta's INV3/INV5 breakend *pairs* as single `<INV>` records,
   which then merge with TIDDIT's typed `<INV>` calls (F5). Inter-chromosomal junctions stay BND on
   both sides. Needs the reference FASTA (REF base at the rewritten POS).
2. **Collapse breakend pairs** (`collapse_sv_pairs.py`): Manta — drop a BND whose `MATEID` was
   already emitted; TIDDIT — drop `SV_<n>_2`. Required because svdb matches a BND as an **unordered**
   breakpoint pair and `--no_intra` only stops a cluster being *seeded* from a file, not *joined* by
   it — feeding both mates produces asymmetric merges (one Manta mate absorbs both TIDDIT mates, its
   own mate merges with nothing) (F3). The dropped mate carries identical GT/PR/SR — nothing is lost.
3. **TIDDIT across samples** (`SVDB_MERGE_TIDDIT`, `--no_intra`, inputs sorted by filename): appends
   one genotype column per sample; svdb tags provenance by input **filename**, so collapse output
   names are `<sample>.tiddit.vcf` on purpose.
4. **Cross-caller merge** (`SVDB_MERGE_CALLERS`, `--no_intra --same_order --bnd_distance 2000
   --priority manta,tiddit`): first tag wins — merged records keep Manta's split-read POS/END and
   FORMAT; TIDDIT's coordinates survive in `INFO/tiddit_POS` (F7, decision `81e01b5`). `--overlap`
   stays at the 0.95 default: 0.95/0.8/0.6 changed nothing on the pilot (F8).
5. **`CHECK_SV_SAMPLE_ORDER`** (before step 4): `--same_order` trusts column **positions**, never
   names — misaligned inputs exit 0 and silently mislabel genotypes (F6). Both sides are sorted by
   sample name upstream (joint Manta via `groupTuple(sort:{it.name})`, TIDDIT via filename sort);
   the guard fails the run if that invariant ever breaks.

## TIDDIT soft filters for the pass view (item 4, 2026-08-31)

TIDDIT's own PASS is a single check (enough discordant links given coverage) — on the pilot,
86 of 106 pass-view rows were single-sample TIDDIT-only calls in an experiment whose truth set
contains **no SVs**. Manta stays clean with several orthogonal *soft* vetoes, so
`TIDDIT_SV_FILTER` gives TIDDIT the same shape: three named tags appended (`--mode +`, nothing
removed) to the per-sample merge input, each an analogue of a Manta filter:

| Tag | Expression (config-tunable) | Manta analogue |
|-----|------------------------------|----------------|
| `LowSupport` | `MAX(FMT/DV+FMT/RV) < 6` | `NoPairSupport` (and raredisease's `-p 6`) |
| `LowQual` | `QUAL < 40` (TIDDIT's 0–80 scale) | `MinQUAL` |
| `HighMQ0` | `MAX(FMT/LQ) > 0.4` | `MaxMQ0Frac` (same 0.4 bar) |

Consequences: the pass view (input pre-filter `-f PASS,.`) excludes tagged records; the union
view keeps them with the tag visible in `tiddit_FILTERS`; the **published caller VCF is
untouched** (`variant_calling/tiddit/` keeps TIDDIT's own FILTER only). Soft tags deliberately
chosen over raising TIDDIT's `-p` at call time: `-p 6` would prevent the calls from existing at
all — gone even from the union view — where a tag only moves a record between views.

Calibration (2026-08-31 pilot, no-SV truth set): 56/86 TIDDIT-only pass rows removed,
0/6 Manta-corroborated rows affected (those sit at TIDDIT QUAL 80 with median 126 supporting
reads). The `LowQual` threshold measures specificity only — the truth set cannot price
sensitivity — which is the other reason the tags are soft. Thresholds live in
`conf/modules/mutation_report.config` (`TIDDIT_SV_FILTER` `ext.*`).

## Provenance keys in the cohort VCF

- `set=` — human-readable per-record origin: `Intersection`, `manta`, `tiddit`, `filterIntiddit`
  (TIDDIT called it non-PASS), `manta-filterIntiddit`, … `FOUNDBY=` — number of contributing inputs.
  `VARID=` — contributing record ids.
- `manta_POS`/`manta_QUAL`/`manta_FILTERS`/`manta_SAMPLE`/`manta_INFO` (and `tiddit_*`) — the
  priority-tagged contribution of each caller. **`manta_POS` present ⇔ Manta contributed** (ditto
  `tiddit_POS`).
- `<sample>.tiddit_SAMPLE` (`union`) / `<sample>.tiddit.pass_SAMPLE` (`union_pass`) — per-sample
  TIDDIT contributions, propagated up from the across-samples merge; **the key exists iff that
  sample's TIDDIT VCF contained the call**, and carries its full genotype string (`GT:…|CN:…|COV:…`).
- FORMAT columns belong to the **priority record's caller**: Manta's `GT:FT:GQ:PL:PR:SR` whenever
  Manta contributed, TIDDIT's otherwise.

⚠️ `bcftools` prints `[W::bcf_hrec_check] Invalid tag name` warnings for the sample-derived INFO ids
(dots/dashes are not spec-clean tag characters). Warnings only — everything downstream parses fine.

## BUILD_SV_MATRIX — how cells are populated

`sv_cohort_matrix.py` derives each cell **deterministically from the merged record** — there is no
proximity matching, no distance gate, and a cell can never disagree with the merge it annotates:

- **Manta cell** (`manta_POS` present): that sample's FORMAT GT carries an alt allele; the
  `union_pass` view additionally requires `FORMAT/FT == PASS`, so a weak genotype (e.g. `MinGQ`) is
  not read as support even though the record-level FILTER is PASS.
- **TIDDIT cell**: the `<sample>.tiddit*_SAMPLE` key exists (records Manta also touched), or —
  for TIDDIT-only records — that sample's GT in the TIDDIT FORMAT columns.

CSV schema (unchanged from the SURVIVOR era):
```
chrom, pos, chrom2, end, svtype, svlen, <sample_1>, <sample_2>, ...
```
Cells: `Manta` / `TIDDIT` / `Manta+TIDDIT` / `-`. Rows in the reference's contig order (the `.fai`,
`--fai`; since 2026-11-09, before that a hard-coded roman-numeral list), then `pos`. `DUP:TANDEM` and `DUP:INV` are normalised to `DUP` (exact subtype in `tiddit_INFO`); BND rows put the mate position in `chrom2`/`end` and
`svlen 0`. Coordinates are the priority caller's (Manta wherever it contributed). Line endings LF.

## Gotchas summary

- `union_pass` is a union of record-level-PASS calls, **not** a two-caller intersection — the
  caller-intersection lives in `set=Intersection`.
- `--pass_only` ≠ a PASS filter (F2). Pre-filter inputs instead.
- Feed svdb **collapsed** inputs only; raw mate pairs merge asymmetrically (F3).
- `--same_order` never checks column names (F6) — keep the guard.
- Provenance tags derive from input **filenames** (collapse output names are part of the contract).
- Sample ids containing `.` would break the `<sample>.tiddit*_SAMPLE` key parsing in
  `sv_cohort_matrix.py` (ALE sample ids have none).
- `DUP` vs `DUP:TANDEM` labels merge fine (svdb normalises; F10a). Manta `INS` vs TIDDIT `DUP` does
  not arise on this data (F10b) — revisit if a caller with different INS/DUP conventions (Delly)
  joins.
- **Multi-experiment samplesheets** (several `experiment` values): joint Manta runs **per
  experiment**, while everything from `SVDB_MERGE_TIDDIT` onward — the cross-caller merge, both
  views and the matrix — is **cohort-wide**. Group membership changes what Manta calls (`MaxDepth`
  tracks pooled depth), so one physical junction can surface as parallel rows that the 1 kb merge
  never unifies, and a sample absent from a row may be "filtered in its group", not "not present".
  Read the matrix **within** an experiment; group by biological ancestor, never split one experiment
  for size. Evidence and guidance: [`manta/manta_calling_modes.md`](manta/manta_calling_modes.md)
  → *Group by biological ancestor*.

## History — the SURVIVOR chain (retired 2026-08-31)

Until commit `0bc42a9`/its successor, the chain was two levels of `SURVIVOR merge` (per-sample
Manta∪TIDDIT, then across samples) plus a `proximity_match` heuristic re-deriving matrix cells. It
was replaced because of three reproduced failures: **cross-type swallowing** (a QUAL-15 non-PASS
TIDDIT breakend pair absorbed a PASS two-caller DEL at XV:722 kb and retyped the cluster INV — the
matrix blanked the sample), **positional provenance** (`SUPP_VEC` bit order coupled to a filelist
`echo`; "last file wins" coordinates, so TIDDIT's depth-derived `722257` shadowed Manta's split-read
`722249` and cohort coordinates depended on alphabetical sample order), and the **proximity
heuristic** itself (its OR-gate bug cross-credited events until 2026-08-25). Full mechanics and the
worked example: this file's history (`git log -- docs/variant-calling/sv_merge.md`, state at
`f17507b`) and the bench NOTES.md. The XV:722 kb case study is preserved as bench finding F1: under
SVDB the DEL survives as `DEL PASS set=Intersection` in every configuration.
