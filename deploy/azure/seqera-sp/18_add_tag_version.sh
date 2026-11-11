#!/usr/bin/env bash
# Add a version of the Launchpad entry that is pinned to a release TAG, keep the current default.
#
#   DRY_RUN=1 ./18_add_tag_version.sh      # print what would be sent, touch nothing
#   ./18_add_tag_version.sh                # add the version, restore the default, read both back
#
#   TAG=v1.1.0 VERSION_NAME=yAMP-prebuilt-inputs-v1.1.0 (the defaults)
#
# WHY. A Platform version stores the entry's launch settings and the revision NAME, never the code
# (azure_batch_execution.md, measured 2026-08-12). A version that says `main` runs whatever `main` is
# at launch, so the launch form of an older release is only reachable through a version whose
# revision is that release's tag. Tags never move, so such a version keeps its form and its behaviour.
#
# WHAT IT SENDS. The params box is the one committed AT THE TAG
# (`git show $TAG:deploy/azure/seqera-sp/launchpad_params_ottilie_test_az.yml`), which matches the
# profile at the tag; the revision is the tag; everything else (compute environment, work dir,
# profiles, engine pin, pre/post-run scripts) is sent back as the entry has it, as `--update` does in
# 14_register_pipeline.sh. Its test data must still exist where the tag's box points (`ottilie/v1`
# stays untouched).
#
# HOW PLATFORM TAKES IT (measured 2026-10-05 with `--update`): `PUT /pipelines/{id}` stores the change
# as a NEW DEFAULT version. So the script then (1) sets the version that was the default before back as
# the default and (2) renames the new version to VERSION_NAME. Between the PUT and step 1, a few seconds,
# the entry's default launches the tag: a launch in that window runs the older release, it does not
# fail. The pipeline id is unchanged throughout.
#
# The entry-level description is shared by every version. ENTRY_DESCRIPTION, when set, is sent in the
# same PUT (one request for both); keep it equal to PIPELINE_DESCRIPTION in 14_register_pipeline.sh,
# which a re-registration uses.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

NAME="${PIPELINE_NAME:-yAMP}"
WORKSPACE="${SEQERA_WORKSPACE:-DTU-Biosustain/RECON-ALE}"
TAG="${TAG:-v1.1.0}"
VERSION_NAME="${VERSION_NAME:-yAMP-prebuilt-inputs-${TAG}}"
BOX_PATH="deploy/azure/seqera-sp/launchpad_params_ottilie_test_az.yml"
API="${SEQERA_API:-https://api.cloud.seqera.io}"
DRY_RUN="${DRY_RUN:-}"
ENTRY_DESCRIPTION="${ENTRY_DESCRIPTION:-}"

SECRET_FILE="${SECRET_FILE:-$HOME/.config/ale-seqera/sp.env}"
if [[ -z "${TOWER_ACCESS_TOKEN:-}" && -r "$SECRET_FILE" ]]; then
    set -a; . "$SECRET_FILE"; set +a
fi
: "${TOWER_ACCESS_TOKEN:?TOWER_ACCESS_TOKEN not set — see 10_store_secret.sh}"

# The tag must exist on GitHub: Platform clones it from there, never from this checkout.
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null \
    || { echo "FATAL: tag $TAG is not on origin" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
git show "$TAG:$BOX_PATH" > "$WORK/box.yml" \
    || { echo "FATAL: $BOX_PATH does not exist at $TAG" >&2; exit 1; }

auth=(-H "Authorization: Bearer $TOWER_ACCESS_TOKEN")
WS_ID=$(tw -o json workspaces list 2>/dev/null | python -c "
import json,sys
want='$WORKSPACE'.lower()
for w in json.load(sys.stdin)['workspaces']:
    if f\"{w['orgName']}/{w['workspaceName']}\".lower()==want: print(w['workspaceId']); break")
PID=$(tw -o json pipelines list -w "$WORKSPACE" 2>/dev/null | python -c "
import json,sys
for p in json.load(sys.stdin)['pipelines']:
    if p['name']=='$NAME': print(p['pipelineId']); break")
: "${WS_ID:?workspace $WORKSPACE not found}"; : "${PID:?no entry named '$NAME' in $WORKSPACE}"

versions() {  # id <TAB> name <TAB> isDefault, one line per version
    curl -sS "${auth[@]}" "$API/pipelines/$PID/versions?workspaceId=$WS_ID&max=100" | python -c "
import json,sys
for v in json.load(sys.stdin)['versions']:
    v=v['version']; print(v['id'], v.get('name') or '', v['isDefault'], sep='\t')"
}
versions > "$WORK/before.tsv"
OLD_DEFAULT=$(awk -F'\t' '$3=="True"{print $1}' "$WORK/before.tsv")
OLD_DEFAULT_NAME=$(awk -F'\t' '$3=="True"{print $2}' "$WORK/before.tsv")
: "${OLD_DEFAULT:?could not find the default version}"
if awk -F'\t' -v n="$VERSION_NAME" '$2==n{f=1} END{exit !f}' "$WORK/before.tsv"; then
    echo "FATAL: '$NAME' already has a version named $VERSION_NAME" >&2; exit 1
fi

curl -sS "${auth[@]}" "$API/pipelines/$PID/launch?workspaceId=$WS_ID" > "$WORK/cur.json"
curl -sS "${auth[@]}" "$API/pipelines/$PID?workspaceId=$WS_ID" > "$WORK/pipe.json"
python - "$WORK/cur.json" "$WORK/pipe.json" "$WORK/box.yml" "$TAG" "$WORK/req.json" "$ENTRY_DESCRIPTION" <<'PY'
import json, sys, yaml
cur, pipe, box_file, tag, dst, new_desc = sys.argv[1:7]
l, p = json.load(open(cur))['launch'], json.load(open(pipe))['pipeline']
box = open(box_file).read()
b = yaml.safe_load(box)
routes = [k for k in ('genbank', 'fasta') if b.get(k)]
if len(routes) != 1:
    sys.exit(f"FATAL: the box at {tag} names {routes or 'no'} reference route(s); exactly one expected")
keep = ['pipeline', 'workDir', 'revision', 'configProfiles', 'nextflowVersion', 'configText', 'towerConfig',
        'preRunScript', 'postRunScript', 'mainScript', 'entryName', 'schemaName', 'userSecrets',
        'workspaceSecrets', 'pullLatest', 'stubRun', 'headJobCpus', 'headJobMemoryMb', 'launchContainer',
        'optimizationId', 'optimizationTargets']
launch = {k: l.get(k) for k in keep}
launch['computeEnvId'] = l['computeEnv']['id']
launch['revision'] = tag
launch['paramsText'] = box
print(f"  entry         : {p['pipelineId']} '{p['name']}', default now @ {l.get('revision')}, -p {','.join(l.get('configProfiles') or [])}")
print(f"  new version   : revision {tag}, box from {tag} (reference route: {routes[0]}, qc_only: {b.get('qc_only')})")
desc = new_desc or p.get('description')
print(f"  description   : {desc!r}" + (" (changed)" if desc != p.get('description') else " (kept)"))
req = {'name': p['name'], 'description': desc, 'icon': p.get('icon'), 'launch': launch}
if p.get('labels'):
    req['labelIds'] = [lab['id'] for lab in p['labels']]
json.dump(req, open(dst, 'w'))
PY
echo "  default kept  : $OLD_DEFAULT ($OLD_DEFAULT_NAME)"
echo "  version name  : $VERSION_NAME"
if [[ -n "$DRY_RUN" ]]; then
    echo "  DRY-RUN: would PUT $API/pipelines/$PID, rename the new version, set $OLD_DEFAULT back as default"
    exit 0
fi

code=$(curl -sS -o "$WORK/put.json" -w '%{http_code}' -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
            --data @"$WORK/req.json" "$API/pipelines/$PID?workspaceId=$WS_ID")
[[ "$code" == 200 ]] || { echo "FATAL: PUT returned HTTP $code:" >&2; head -c 800 "$WORK/put.json" >&2; echo >&2; exit 1; }
versions > "$WORK/after.tsv"
NEW=$(awk -F'\t' '$3=="True"{print $1}' "$WORK/after.tsv")
if [[ -z "$NEW" || "$NEW" == "$OLD_DEFAULT" ]]; then
    echo "FATAL: no new default version after the PUT (default: ${NEW:-none}); nothing renamed" >&2; exit 1
fi
# tw 0.38.0 sends the name and the default flag together (measured 2026-11-11): `--new-name` alone sends
# "not default" (refused on the current default), `--set-default` alone sends an EMPTY name (blanked
# -5's name). So restore the default WITH its name, then rename the new version, which is no longer default.
if [[ -n "$OLD_DEFAULT_NAME" ]]; then
    tw pipelines versions manage -i "$PID" -w "$WORKSPACE" --version-id "$OLD_DEFAULT" --set-default --new-name "$OLD_DEFAULT_NAME"
else
    tw pipelines versions manage -i "$PID" -w "$WORKSPACE" --version-id "$OLD_DEFAULT" --set-default
fi
tw pipelines versions manage -i "$PID" -w "$WORKSPACE" --version-id "$NEW" --new-name "$VERSION_NAME"
echo "  added $NEW as $VERSION_NAME; default back on $OLD_DEFAULT ($OLD_DEFAULT_NAME)"

# Readback: the tag version and the default, each as the launch form would receive it.
echo; echo "=== verifying ==="
curl -sS "${auth[@]}" "$API/pipelines/$PID/launch?workspaceId=$WS_ID&versionId=$NEW" > "$WORK/v_tag.json"
curl -sS "${auth[@]}" "$API/pipelines/$PID/launch?workspaceId=$WS_ID" > "$WORK/v_def.json"
versions > "$WORK/final.tsv"
python - "$WORK/v_tag.json" "$WORK/v_def.json" "$WORK/final.tsv" "$TAG" "$NEW" "$VERSION_NAME" "$OLD_DEFAULT" "$OLD_DEFAULT_NAME" <<'PY'
import json, sys, yaml
vt, vd, final, tag, new, vname, old, old_name = sys.argv[1:9]
bad = []
def chk(ok, msg):
    print(("  OK    " if ok else "  FAIL  ") + msg)
    if not ok: bad.append(msg)
rows = [l.rstrip('\n').split('\t') for l in open(final)]
t, d = json.load(open(vt))['launch'], json.load(open(vd))['launch']
tb, db = yaml.safe_load(t['paramsText']), yaml.safe_load(d['paramsText'])
chk(any(r[0] == new and r[1] == vname and r[2] == 'False' for r in rows), f"version {new} is named {vname} and is not the default")
chk(any(r[0] == old and r[1] == old_name and r[2] == 'True' for r in rows), f"version {old} is the default again, still named {old_name!r}")
chk(t['revision'] == tag, f"{vname}: revision {tag} (got {t['revision']})")
chk(bool(tb.get('fasta')) and not tb.get('genbank'), f"{vname}: box names the pre-built route (fasta={tb.get('fasta')!r})")
chk(d['revision'] == 'main', f"default: revision main (got {d['revision']})")
chk(bool(db.get('genbank')) and not db.get('fasta'), f"default: box names genbank ({db.get('genbank')!r})")
for name, l in ((vname, t), ('default', d)):
    chk(l.get('nextflowVersion') == '25.10.4', f"{name}: nextflowVersion 25.10.4 (got {l.get('nextflowVersion')!r})")
    print(f"  info  {name}: -p {','.join(l.get('configProfiles') or [])}, CE {l['computeEnv']['name']}, qc_only {yaml.safe_load(l['paramsText']).get('qc_only')}")
if bad:
    sys.exit("\n🚨 VERIFICATION FAILED")
PY
