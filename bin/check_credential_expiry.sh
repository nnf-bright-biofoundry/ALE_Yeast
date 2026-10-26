#!/usr/bin/env bash
# Warns when a tracked credential approaches expiry. Run automatically by the
# Claude Code SessionStart hook (.claude/settings.json); safe to run by hand too.
# Prints NOTHING while every credential has more lead time than its threshold,
# so sessions stay quiet until action is actually due.
#
# After any rotation: update the entry here AND in deploy/azure/seqera-sp/RUNBOOK.md
# (the audit record). Dates and names only — no secrets, no GUIDs (deploy/azure/README.md).

set -u

today_s=$(date -u +%s)
warned=0

# args: name | expiry (UTC date) | lead-days | action when it fires
check() {
    local name="$1" expiry="$2" lead="$3" action="$4"
    local expiry_s days_left
    expiry_s=$(date -u -d "$expiry" +%s 2>/dev/null) || { echo "⚠️ $0: bad date '$expiry' for $name"; warned=1; return; }
    days_left=$(( (expiry_s - today_s) / 86400 ))
    if (( days_left < 0 )); then
        echo "🚨 EXPIRED $(( -days_left )) days ago: $name (expired $expiry) — $action"
        warned=1
    elif (( days_left <= lead )); then
        echo "⏰ $name expires $expiry ($days_left days left) — $action"
        warned=1
    fi
}

check "Azure SP client secret (sp-bright-recon-ale-mutations-pipeline-seqera-deploy, hint 'seqera-platform')" \
      "2027-07-31" 60 \
      "mint a new secret with deploy/azure/seqera-sp/03_create_secret.sh (operator terminal ONLY — it prints the secret), update the Seqera credential and ~/.config/ale-seqera/sp.env, then delete the old keyId. Expired = opaque auth error at launch."

# No GitHub credential is tracked since 2026-10-26: the repository is public and Platform clones it
# anonymously over HTTPS; the fine-grained PAT (would have expired 2027-08-07) was retired with the transfer to
# nnf-bright-biofoundry (RUNBOOK → GitHub PAT). Add an entry here again if a token is ever registered.

check "Sister-SP secret 'rotated-2026-08' (sp-bright-recon-ale-mutations-pipeline — the ALE-mutations service, not Seqera)" \
      "2027-08-14" 60 \
      "mint + swap per the live-swap recipe in deploy/azure/seqera-sp/RUNBOOK.md (03_create_secret.sh with SP_DISPLAY_NAME/SECRET_LABEL overrides); coordinate with the app's co-owners. Expired = the ALE-mutations service loses Azure auth."

if (( warned )); then
    echo "(bin/check_credential_expiry.sh — update its dates after any rotation)"
fi
exit 0
