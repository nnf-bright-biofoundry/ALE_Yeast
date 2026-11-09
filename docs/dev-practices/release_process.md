# Release process (SOP)

How to cut a versioned release of this pipeline. Written from the v1.0.0 release
(2026-07-28) — the **Field notes** at the bottom record behaviours that were verified
empirically and are easy to get wrong.

## What a release consists of

| Artifact | Where | How it's produced |
|---|---|---|
| **git tag** `vX.Y.Z` | `nnf-bright-biofoundry/ALE_Yeast` | manual (`git tag -a`) |
| **container image** `ale-reports:X.Y.Z` | Docker Hub (canonical) + ghcr (mirror) | **automatic** — the tag push fires `.github/workflows/build-generate-index-container.yml` |
| **`manifest.version`** | `nextflow.config` | manual, before tagging |
| **CHANGELOG entry** | `CHANGELOG.md` | manual, before tagging |

**Container and pipeline versions are decoupled.** `ale-reports` supplies only
pandas + jinja2 + procps; `generate_index.py` is staged at runtime, **not baked in**. So
ordinary pipeline work (Nextflow modules, the report script, configs) never requires an image
rebuild — the image only changes when `containers/generate_index/Dockerfile` does. The release
tag rebuilds it anyway, which is fine and gives a provenance-linked build.

---

## 1. Pre-release checklist

Everything here must be done **before** tagging — a tag is immutable, and re-pointing it means
`git tag -f` / `git push -f`, which re-triggers CI and breaks anyone who already fetched it.

- [ ] **`CHANGELOG.md`** has the release section (Added / Changed / Fixed / Known limitations).
- [ ] **`nextflow.config` manifest** — `version`, `description`, `name`, `homePage` correct.
- [ ] **Container pin is the image the release ships:**
      ```bash
      grep -n report_container nextflow.config      # -> docker.io/aledbucsd/ale-reports:<image version>
      git log --oneline <last release tag>..HEAD -- containers/generate_index/
      ```
      This is the single source of truth; `modules/local/generate_index/main.nf` just reads it. The
      image version follows the pipeline version only when `containers/generate_index/` changed since
      the last release. With no change the pin stays (v1.1.0 kept `ale-reports:1.0.0`): the image
      `X.Y.Z` does not exist until the tag is pushed, so a pin moved before tagging breaks the
      contract test, and the tag push still publishes an unused `ale-reports:X.Y.Z`.
- [ ] **Docs cross-references resolve:**
      ```bash
      python docs/dev-practices/check_docs.py --mode links     # must be 0; exits non-zero if not
      python docs/dev-practices/check_docs.py --mode paths     # triage: compare to last release
      ```
      The `paths` pass is *not* expected to be zero — historical notes and proposed designs
      legitimately name files that don't exist. Read it as a diff, not a gate.
- [ ] **No plan artifacts in committed files** — work-package numbers and plan-step names
      belong in commit messages and plan files, never in shipped code or docs:
      ```bash
      git grep -nE '\bWP[0-9]' -- '*.md' '*.nf' '*.config' '*.py' '*.sh'
      ```
- [ ] **Tests green:**
      ```bash
      nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test
      nf-test test -c tests/nf-test-ottilie.config tests/split_joint_vcf.nf.test
      ```

## 2. Pre-flight

```bash
git rev-parse --abbrev-ref HEAD        # must be main
git fetch origin
git status -sb                         # <-- READ THE AHEAD/BEHIND COUNT
```

⚠️ **Check that `main` is actually pushed.** At v1.0.0 the branch was **19 commits ahead of
`origin/main`** — the whole release was local-only. Tagging in that state creates a tag whose
commit isn't reachable from `origin/main`, and CI builds from a ref that isn't on the release
branch.

```bash
git push origin main
```

Pushing `main` does **not** rebuild the image unless the push touches
`containers/generate_index/**` or the workflow file (the `paths:` filter). Verify:

```bash
git diff --stat origin/main..main -- containers/generate_index/ .github/workflows/
```

## 3. Record the baseline

The image tag is being **overwritten**, so capture what it was — this is how you prove CI
actually republished it:

```bash
curl -s "https://hub.docker.com/v2/repositories/aledbucsd/ale-reports/tags?page_size=25" \
  | python -c "import json,sys;[print(f\"{t['name']:<16}{t.get('tag_last_pushed')} {t.get('digest','')[:26]}\") for t in json.load(sys.stdin)['results']]"
```

## 4. Tag and push

```bash
git tag -a vX.Y.Z -m "vX.Y.Z — <one-line summary>"
git push origin vX.Y.Z
```

## 5. What CI produces

`docker/metadata-action` emits these for a **tag** push, to **both** registries in a single
build-push step:

| Rule | Produces on `vX.Y.Z` |
|---|---|
| `type=semver,pattern={{version}}` | **`X.Y.Z`** ← the release image (note: **no `v`**) |
| `type=sha,format=short` | `sha-<short>` — immutable provenance for the tagged commit |
| `type=raw,value=latest,enable={{is_default_branch}}` | `latest` — **does** move on a semver tag (see field notes) |
| `type=ref,event=branch` | nothing (no branch on a tag ref) |

## 6. Verify

```bash
# a) CI ran — GitHub -> Actions -> build-generate-index-container.
#    The run summary lists six refs, three per registry. ghcr is PRIVATE, so this summary
#    (or `gh`) is the only way to confirm the mirror; it can't be checked anonymously.

# b) the image tag was rewritten — digest must differ from the baseline in step 3
curl -s "https://hub.docker.com/v2/repositories/aledbucsd/ale-reports/tags?page_size=25" \
  | python -c "import json,sys;[print(f\"{t['name']:<16}{t.get('tag_last_pushed')} {t.get('digest','')[:26]}\") for t in json.load(sys.stdin)['results']]"

# c) pull it — your local cache still holds the PRE-release build under the same tag
docker pull docker.io/aledbucsd/ale-reports:X.Y.Z
docker run --rm --entrypoint python docker.io/aledbucsd/ale-reports:X.Y.Z \
    -c "import pandas,jinja2,sys;print(sys.version.split()[0],pandas.__version__,jinja2.__version__)"

# d) release gate — re-run the contract test against the image the release actually ships
nf-test test -c tests/nf-test-ottilie.config tests/ottilie_e2e.nf.test
```

Step (d) is the one that matters: the snapshot must be **unchanged**. Since the image only
supplies pandas + jinja2 + procps and the report script is staged at runtime, any delta here is
a real regression, not noise.

---

## Field notes (verified during the v1.0.0 release, 2026-07-28)

Behaviours that are counter-intuitive or that the documentation doesn't settle:

- **The `paths:` filter does *not* block the `v*` tag trigger.** The workflow declares
  `branches`, `paths` and `tags` in one `push:` block, and GitHub's docs do not say whether
  `paths` is evaluated for tag pushes. **Empirically it is not** — the `v1.0.0` push fired the
  workflow with no manual dispatch. Treat this as observed-once, not guaranteed: if a future tag
  doesn't fire, use **Run workflow** and select the tag ref (`workflow_dispatch` is declared, and
  `type=semver` reads `github.ref`, so it still emits the right image tag).
- **`latest` moves on a semver tag push**, despite `enable={{is_default_branch}}` — the tag ref
  is not the default branch, yet `metadata-action` set it anyway. Harmless (conventional, even),
  but don't assume `latest` tracks `main`.
- **The image tag has no `v`.** `pattern={{version}}` strips it: git `v1.0.0` → image `1.0.0`.
- **The image tag already exists and gets overwritten.** Success is *not* a new tag appearing —
  it's the existing row's digest and `tag_last_pushed` changing. At v1.0.0 the digest went from
  `a98647da…` (manual bootstrap) to `876246216…` (CI).
- **Your local Docker cache is stale after a release.** It holds the pre-release build under the
  same tag until you `docker pull`. Re-running tests without pulling silently validates the old
  image.
- **A rebuilt image legitimately has a different digest even from an unchanged Dockerfile.**
  Comparing the manual and CI builds: the four `python:3.12-slim` base layers were byte-identical;
  only the `apt` and `pip` layers differed. That's ordinary apt/pip non-reproducibility. Compare
  installed **versions**, not digests, to judge equivalence.
- **Stale `main` / `sha-*` tags on the registry are expected.** `main` is only rewritten when a
  push to `main` touches the Dockerfile, so it lags. Nothing in the pipeline resolves `main`,
  `latest`, or `sha-*` — `params.report_container` pins the exact release tag.

## Field notes from v1.1.0 (2026-11-09)

A release with no container change: `containers/generate_index/` had no commit since v1.0.0.

- **The pin stayed `ale-reports:1.0.0`** and the release commit (`62472dc`) moved one output line, the
  pipeline line of `versions.yml` (`v1.0.0` → `v1.1.0`); the contract-test snapshot was re-recorded in
  that commit.
- **The tag push fired CI again despite the `paths:` filter** (run `42681552697`, 2026-11-09): second
  observation of the v1.0.0 field note, still not a documented guarantee.
- **CI published an image nothing uses:** `1.1.0`, `sha-62472dc` and `latest`, all one digest
  (`sha256:82a0d4620ae1…`). `latest` moved again.
- **The pinned image was not rewritten:** `1.0.0` kept its digest (`sha256:0e52d5aec52f…`) and its push
  date (2026-08-31), compared against the step 3 baseline. So step 6(d), the contract test against the
  shipped image, was already satisfied by the pre-tag run and was not repeated. It is needed only when
  the pin moves or the pinned tag's digest changes.
- **Step 6(c) note:** with an unchanged pin there is nothing stale to pull.
- **CI warnings to act on before they bite:** the workflow's actions (`actions/checkout@v4`,
  `docker/build-push-action@v6`, `docker/login-action@v3`, `docker/metadata-action@v5`) target
  Node.js 20 and are forced onto Node.js 24; `ubuntu-latest` is moving to Ubuntu 26.
- **The annotated tag was created on the named commit** (`git tag -a v1.1.0 62472dc -m …`), after
  `main` was on origin: naming the commit keeps the tag off anything committed in between.

## If something goes wrong

- **CI didn't fire** → Actions → Run workflow → select the tag ref. No re-tagging needed.
- **CI failed at Docker Hub login** → repo secrets `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`
  (Read & Write). The login step precedes the build, so ghcr won't publish either.
- **Tagged the wrong commit** → if nothing has consumed the tag yet:
  `git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`, fix, re-tag. Avoid once published.
- **The e2e snapshot changed after the image rebuild** → do not ship. Diff the report
  `tableJson` (see the igv-reports determinism note in `testing_best_practices.md`) and check
  whether a dependency actually moved.
