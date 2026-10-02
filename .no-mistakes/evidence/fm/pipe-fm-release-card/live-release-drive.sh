#!/usr/bin/env bash
# Live drive of bin/fm-release.sh against a disposable firstmate lab home.
# Real scripts, real tasks-axi, plain FM_HOME (no FM_*_OVERRIDE), real home-summary publication.
set -u
WT=/Users/justinlobaito/.no-mistakes/worktrees/d2386019607f/01M3Z7A6P9S484M333QVY4KA6X
LAB=$1
export PATH="$HOME/.nvm/versions/node/v24.14.1/bin:$PATH"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB
cp "$WT/.tasks.toml" "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
R="$WT/bin/fm-release.sh"; H="$WT/bin/fm-captain-hold.sh"
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
refresh() { "$WT/bin/fm-home-summary-refresh.sh" >/dev/null 2>&1 || echo "REFRESH FAILED"; }
dec() { jq -c --arg id "$1" '.decisions_open[] | select(.id == $id) | {id,project,question,options}' "$LAB/state/home-summary.json"; }
fp() { jq -r --arg id "$1" '.decisions_open[] | select(.id == $id) | .question_fingerprint' "$LAB/state/home-summary.json"; }
drop() {  # <hold> <fingerprint> <option> - AIOS-UI drop-file answer, then the runner's poll + autohandle
  local n="$1-$(date +%s)000.json"
  mkdir -p "$LAB/state/answer-drop"
  jq -n --arg h "$1" --arg f "$2" --arg o "$3" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{hold_id:$h,question_fingerprint:$f,answer:{option:$o},answered_at:$t,source:"aios-ui"}' > "$LAB/state/answer-drop/.tmp"
  mv "$LAB/state/answer-drop/.tmp" "$LAB/state/answer-drop/$n"
  "$WT/bin/fm-procevent-answer-drop.sh" poll > "$LAB/state/.poll-result" 2>&1
  "$WT/bin/fm-procevent-answer-drop.sh" autohandle answer-drop 1 "$LAB/state/.poll-result" >/dev/null 2>&1
  "$WT/bin/fm-procevent-answer-drop.sh" read "$LAB/state/.poll-result"
}

echo "=== S1 record a site after a staging deploy ==="
run "$R" record truss --staging-url https://truss-staging.netlify.app --production-url https://trussservicesllc.com \
  --staging-sha abc1234def --waiting 3 --deploy staging --result ok

echo; echo "=== S2 refusals ==="
run "$R" record truss --staging-url 'https://x.example/a(b)'
run "$R" record truss --staging-url 'https://x.example/a b'
run "$R" record truss --staging-sha XYZ1234
run "$R" record truss --deploy production
run "$R" record onlywaiting --waiting 0
run "$R" card onlywaiting
run "$R" record nolink --waiting 2
run "$R" card nolink
echo "record after refusals:"; jq -c '{staging_url,staging_sha,waiting}' "$LAB/data/sites/truss.json"

echo; echo "=== S3 card raises the call; home summary shows it in decisions_open ==="
run "$R" card truss; A=$(jq -r .card "$LAB/data/sites/truss.json")
refresh; echo "decisions_open row:"; dec "$A"
echo "--- fm-captain-hold.sh open $A"; "$H" open "$A" && echo "open: yes"

echo; echo "=== S4 refresh re-holds same call; stale answer is refused ==="
OLDFP=$(fp "$A")
run "$R" record truss --waiting 4 --staging-sha def5678
run "$R" card truss
refresh; dec "$A"
echo "pinned: $(jq -c .pinned "$LAB/data/sites/truss.json")"
run "$R" record truss --waiting 5
run "$R" card truss
refresh; dec "$A"
echo "pinned: $(jq -c .pinned "$LAB/data/sites/truss.json")"
echo "--- AIOS answer with the fingerprint of the old wording:"; drop "$A" "$OLDFP" send
"$H" open "$A" >/dev/null && echo "call $A still open after stale answer"

echo; echo "=== S5 send answer through the AIOS drop folder ==="
drop "$A" "$(fp "$A")" send
refresh; echo "answers_seen[0]: $(jq -c '.answers_seen[0]' "$LAB/state/home-summary.json")"
echo "still in decisions_open? '$(dec "$A")'"
(cd "$LAB" && tasks-axi show "$A") | grep -E "Answer|Captain decision" | head -5

echo; echo "=== S6 staging moves after send; next card is a new call; pinned[A] unchanged ==="
run "$R" record truss --staging-sha 0123abcd --waiting 6
sleep 1; run "$R" card truss; B=$(jq -r .card "$LAB/data/sites/truss.json")
refresh; dec "$B"
echo "pinned: $(jq -c .pinned "$LAB/data/sites/truss.json")"
echo "A=$A -> $(jq -r --arg a "$A" '.pinned[$a]' "$LAB/data/sites/truss.json")  (the commit to release after send on A)"

echo; echo "=== S7 production deploy recorded; sites[] in state/home-summary.json ==="
run "$R" record truss --waiting 0 --deploy production --result ok
printf 'not json' > "$LAB/data/sites/broken.json"
refresh; echo "sites[]:"; jq '.sites' "$LAB/state/home-summary.json"
echo "sites[] leak card/pinned? $(jq -c '[.sites[] | has("card") or has("pinned")] | any' "$LAB/state/home-summary.json")"
rm -f "$LAB/data/sites/broken.json"

echo; echo "=== S8 an unanswered call aged 14 days is superseded and re-raised ==="
run "$R" record truss --waiting 2
C_NOW=$(date -u -v+15d +%Y-%m-%dT%H:%M:%SZ)
echo "B=$B open? $("$H" open "$B" >/dev/null && echo yes)"
FM_SNAPSHOT_NOW=$C_NOW "$WT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$LAB/state/.future.json"
echo "B in decisions_open 15 days later (before card)? '$(jq -c --arg id "$B" '.decisions_open[] | select(.id==$id) | .id' "$LAB/state/.future.json")'"
FM_RELEASE_NOW=$C_NOW run "$R" card truss; C=$(jq -r .card "$LAB/data/sites/truss.json")
FM_SNAPSHOT_NOW=$C_NOW "$WT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$LAB/state/.future.json"
echo "C in decisions_open: $(jq -c --arg id "$C" '.decisions_open[] | select(.id==$id) | {id,question}' "$LAB/state/.future.json")"
echo "B still open? $("$H" open "$B" >/dev/null 2>&1 && echo yes || echo no)"
(cd "$LAB" && tasks-axi show "$B") | grep -E "Reconciliation evidence|raised the release call again|Captain decision" | head -5
echo "pinned: $(jq -c .pinned "$LAB/data/sites/truss.json")"
