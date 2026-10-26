# GENERATE_INDEX container — notes

## Current state (v1.0.0) — RESOLVED

`modules/local/generate_index/main.nf` runs `generate_index.py`, which needs two
Python libraries: **pandas** and **jinja2**. No slim biocontainer bundles both:

- `quay.io/biocontainers/pandas:2.2.1` → pandas ✓, jinja2 ✗
- `biocontainers/multiqc:1.25.1` → jinja2 ✓, pandas ✗ (MultiQC vendors pandas out of
  the default `python`; older multiqc tags behave the same)

So the process ships a **self-built image** (`containers/generate_index/Dockerfile`:
`python:3.12-slim` + pinned `pandas==2.2.3` + `jinja2==3.1.4` + `procps`, ~271 MB),
published to two registries:

| Role | Image | Visibility |
|------|-------|------------|
| **Canonical** (module pin) | `docker.io/aledbucsd/ale-reports:1.0.0` | Public |
| **Backup / mirror** | `ghcr.io/nnf-bright-biofoundry/ale-reports` (`main`, `latest`, `sha-74db1f6` since 2026-10-26; the `1.0.0` mirror is still `ghcr.io/aletechdev/ale-reports:1.0.0`, old org) | Private |

```
conda 'conda-forge::pandas conda-forge::jinja2'
container "${ params.report_container }"    // reads the single source below; no fixed tag here
```

On `-profile conda` / `-profile wave` the conda directive drives the build instead of
the pinned container.

### Single bump point: `params.report_container`

The image tag lives in exactly **one** place — `params.report_container` in `nextflow.config`:
```groovy
report_container = 'docker.io/aledbucsd/ale-reports:1.0.0'
```
The module's `container` directive reads it directly (no hardcoded literal, no config override),
so there is no second copy to drift. Only `ale-reports` is ours; every other module uses public
biocontainers (leave them). Under `-profile conda` the param is simply ignored (conda drives).

**Release step when the image changes:**
1. Edit the Dockerfile; pick a new immutable tag (the *container's* own version — it need not
   equal the pipeline version). Never `:latest` in the pin.
2. Publish it: push a **`v*` git tag** so the GHA's `semver` rule mints `ale-reports:X.Y.Z`
   (a plain push to `main` only yields `:latest`/`:sha-…`, not a clean semver).
3. In the **same** commit, bump `params.report_container` in `nextflow.config` to `:X.Y.Z`.
4. Let the Action go green (image pushed) **before** running/announcing the release.

You do **not** bump it on every pipeline release — only when the image contents change. A
release that doesn't touch `containers/generate_index/` keeps the existing pin. This replaced the previous "no container — runs on host Python
(nf-env)" approach, which fails on cloud executors (no host conda env on compute nodes).

A Seqera **Wave community container** (`community.wave.seqera.io/library/pandas_jinja2:...`)
was minted as an interim option (via `wave-cli`, anonymous/free) but superseded by the
self-owned image above. Kept as a fallback recipe:
`wave --conda-package conda-forge::pandas --conda-package conda-forge::jinja2 --freeze --await`.

> ⚠️ **procps/`ps` gotcha.** Any custom task container MUST include `procps` (`ps`) or
> Nextflow marks the task **failed (exit 1)** even though the command succeeds — the
> `.command.err` shows only "Command 'ps' … cannot be found", `.command.out` is empty,
> and no outputs are produced. `python:3.12-slim` omits it; the Dockerfile installs it.

## How it is built and published

### Registry accounts

- **Docker Hub** (canonical): namespace `aledbucsd`, accessed by signing in with the
  Google account **aledbsoftware@gmail.com** (Google SSO). This is the account that owns
  the `ale-reports` repo and issues the `DOCKERHUB_TOKEN` used by CI.
- **ghcr** (mirror): the GitHub org that owns the repo (`nnf-bright-biofoundry` since the 2026-10-23 transfer; `Aletechdev` before, where the 1.0.0 mirror still sits). CI pushes via the repo's built-in
  `GITHUB_TOKEN`. In the old org the package was pre-created by hand and the `ALE_Yeast` repo
  granted Write (Package settings → Manage Actions access). In the new org the package did not
  exist after the transfer, and a `workflow_dispatch` of the build on 2026-10-26 (run
  `40326516830`, commit `74db1f6`) created it on first push with the built-in token alone, so no
  pre-creation is needed where the org lets members create packages; a package created this way
  is linked to the repo automatically. The run also refreshed `latest`/`main`/`sha-*` on Docker
  Hub; `1.0.0` is produced only from a `v*` tag and was untouched.

**GitHub Action (preferred, automated):**
`.github/workflows/build-generate-index-container.yml` builds the Dockerfile and pushes
to **both** Docker Hub (canonical) and ghcr (mirror). ghcr uses the built-in
`GITHUB_TOKEN`; Docker Hub needs two repo secrets:

- `DOCKERHUB_USERNAME` = `aledbucsd`
- `DOCKERHUB_TOKEN` = a Docker Hub access token (Read & Write)

Triggers: manual (`workflow_dispatch`), pushes to `main` touching
`containers/generate_index/**`, and `v*` tags.

**Manual (local):** `containers/generate_index/push.sh` (ghcr, needs a `write:packages`
PAT). Docker Hub manual push: `docker tag … docker.io/aledbucsd/ale-reports:<tag> &&
docker push docker.io/aledbucsd/ale-reports:<tag>` after `docker login docker.io`.

New Docker Hub repos push as **private** — set the repo Public once (repo → Settings →
Make public). Test anonymous pull: `DOCKER_CONFIG=/tmp/anon docker pull aledbucsd/ale-reports:1.0.0`.

## Deployment — registry access per executor

The canonical image is **public Docker Hub**, so most executors pull it anonymously with
no credential setup (local docker, Seqera Platform, CI). Caveat: Docker Hub anonymous
pulls are rate-limited (~100/6h per IP), which can throttle many-node cloud runs behind a
single NAT — if that bites, switch the module `container` pin to the ghcr mirror.

The **ghcr mirror is private**. To use it (as the pin or a fallback) the executor needs
read credentials:

- Local docker: `docker login ghcr.io` once.
- **Seqera Platform: register a Container-registry credential** (workspace → Credentials
  → Add → Container registry): server `ghcr.io`, GitHub user, a **read-only** PAT
  (`read:packages`). ➜ **TODO if pinning ghcr on Seqera Platform.**
- Raw Azure Batch / AKS: node `docker login` / an `imagePullSecret`.
- Alternatively make the ghcr package Public too (repo → Packages → settings) — then no
  credential is needed anywhere.

## Alternatives considered

**(a) Drop the pandas dependency** from `generate_index.py` (stdlib `csv` instead) —
leaves jinja2 as the only dep, so any jinja2 image works. Not done in v1.0.0 to avoid
touching the stats-parsing code; viable future cleanup.

**(b) Split GENERATE_INDEX into two processes** —
- Step 1 (data): pandas parses the MultiQC stats TSVs → emits context as JSON, using the
  stock `quay.io/biocontainers/pandas:2.2.1` image already used by BUILD_CN_MATRIX.
- Step 2 (render): jinja2 renders `index.html` from that JSON + templates.

Cleanly solves the pandas half with an existing image, but Step 2 still needs a
jinja2-bearing image, and it adds a second process + a JSON intermediate. Documented as
an option; not built in v1.0.0.

## Files

- `modules/local/generate_index/main.nf` — `conda` + `container` directives.
- `containers/generate_index/{Dockerfile,push.sh}` — image recipe + manual push.
- `.github/workflows/build-generate-index-container.yml` — dual-registry CI push.
- `docs/igvreports/generate_index.py` — imports `pandas`, `jinja2`.
