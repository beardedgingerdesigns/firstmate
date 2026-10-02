#!/usr/bin/env bash
# Behavioral tests for bin/fm-release.sh: the per-project site record, the
# release call it raises through bin/fm-captain-hold.sh, and the sites[] list
# bin/fm-fleet-snapshot.sh publishes in the home summary.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-release)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
FAKEBIN=$(fm_fakebin "$HOME_DIR")
fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi

in_home() {  # <command...>
  (cd "$HOME_DIR" && PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" "$@")
}
release() { in_home "$ROOT/bin/fm-release.sh" "$@"; }
summary() {  # [snapshot-now]
  FM_SNAPSHOT_NOW=${1:-2026-10-02T16:00:00Z} in_home "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary
}
decision() {  # <task-id> [snapshot-now]
  summary "${2:-}" | jq -c --arg id "$1" '.decisions_open[] | select(.id == $id)'
}
site() { jq -c . "$HOME_DIR/data/sites/$1.json"; }

# --- record -----------------------------------------------------------------------
FM_RELEASE_NOW=2026-10-02T10:00:00Z release record truss --staging-url https://truss-staging.netlify.app \
  --production-url https://trussservicesllc.com --staging-sha abc1234def --waiting 3 --deploy staging --result ok >/dev/null
assert_equals "$(site truss)" \
  '{"project":"truss","updated":"2026-10-02T10:00:00Z","staging_url":"https://truss-staging.netlify.app","production_url":"https://trussservicesllc.com","staging_sha":"abc1234def","waiting":3,"last_deploy":{"env":"staging","result":"ok","at":"2026-10-02T10:00:00Z"}}' \
  "record writes every field"
FM_RELEASE_NOW=2026-10-02T11:00:00Z release record truss --waiting 0 >/dev/null
assert_equals "$(site truss | jq -c '{waiting,staging_url,last_deploy:.last_deploy.at,updated}')" \
  '{"waiting":0,"staging_url":"https://truss-staging.netlify.app","last_deploy":"2026-10-02T10:00:00Z","updated":"2026-10-02T11:00:00Z"}' \
  "omitted flags keep their stored value"
pass "record writes and merges the site record"

rc=0; release record truss --staging-url ftp://x 2>/dev/null || rc=$?
expect_code 1 "$rc" "a non-web link is refused"
rc=0; release record truss --staging-url 'https://x/(a)' 2>/dev/null || rc=$?
expect_code 1 "$rc" "a link with parentheses is refused"
rc=0; release record truss --deploy production 2>/dev/null || rc=$?
expect_code 1 "$rc" "--deploy without --result is refused"
rc=0; release record truss --waiting -1 2>/dev/null || rc=$?
expect_code 1 "$rc" "a negative count is refused"
for bad in xyz1234 abc12 ABC1234 "$(printf 'a%.0s' $(seq 41))"; do
  rc=0; release record truss --staging-sha "$bad" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "staging commit $bad is refused"
done
rc=0; release record ../x --waiting 1 2>/dev/null || rc=$?
expect_code 1 "$rc" "a path-like project is refused"
assert_equals "$(site truss | jq -c '{waiting,staging_sha}')" '{"waiting":0,"staging_sha":"abc1234def"}' "refused writes leave the record unchanged"
pass "record refuses invalid input"

# --- card -------------------------------------------------------------------------
rc=0; release card truss 2>/dev/null || rc=$?
expect_code 1 "$rc" "card refuses when nothing is waiting"
release record nolink --waiting 2 >/dev/null
rc=0; release card nolink 2>/dev/null || rc=$?
expect_code 1 "$rc" "card refuses without a staging link"
release record nosha --waiting 2 --staging-url https://nosha.example >/dev/null
rc=0; release card nosha 2>/dev/null || rc=$?
expect_code 1 "$rc" "card refuses without a staging commit"

release record truss --waiting 3 >/dev/null
CARD=$(FM_RELEASE_NOW=2026-10-02T12:00:00Z release card truss)
assert_equals "$CARD" "release-truss-1790942400" "card mints a release task id"
assert_equals "$(site truss | jq -c '{card,card_sha}')" "{\"card\":\"$CARD\",\"card_sha\":\"abc1234def\"}" \
  "card and its pinned commit are stored in the record"
assert_equals "$(decision "$CARD" | jq -c '{project,options,question}')" \
  '{"project":"truss","options":[{"key":"send","label":"Send"},{"key":"not-yet","label":"Not yet"}],"question":"Send truss to production? 3 changes waiting, staging https://truss-staging.netlify.app at abc1234"}' \
  "the call shows on the decisions list with send and not-yet"
pass "card raises a captain call with structured options"

release record truss --waiting 1 >/dev/null
assert_equals "$(FM_RELEASE_NOW=2026-10-02T13:00:00Z release card truss)" "$CARD" "an open call is re-held, not duplicated"
assert_equals "$(decision "$CARD" | jq -r .question)" \
  "Send truss to production? 1 change waiting, staging https://truss-staging.netlify.app at abc1234" "re-held wording follows the current count"
release record truss --waiting 2 --staging-sha def5678 >/dev/null
assert_equals "$(FM_RELEASE_NOW=2026-10-02T13:30:00Z release card truss)" "$CARD" "a moved staging commit re-holds the same call"
assert_equals "$(decision "$CARD" | jq -r .question)" \
  "Send truss to production? 2 changes waiting, staging https://truss-staging.netlify.app at def5678, staging moved from abc1234" \
  "re-held wording pins the new commit and says staging moved"
assert_equals "$(site truss | jq -r .card_sha)" def5678 "the re-held call pins the new commit"
pass "card reuses the open call"

# The answer returns through the one keyed-answer intake every channel feeds.
printf '%s\tsend\tSend\n' "$CARD" | in_home "$ROOT/bin/fm-captain-hold.sh" answers --source test >/dev/null
assert_contains "$(cd "$HOME_DIR" && tasks-axi show "$CARD")" "Answer: send" "the send answer is recorded on the call"
assert_equals "$(decision "$CARD")" "" "the answered call leaves the decisions list"
NEXT=$(FM_RELEASE_NOW=2026-10-02T14:00:00Z release card truss)
assert_equals "$NEXT" "release-truss-1790949600" "after an answer the next card is a new call"
pass "an answered call is not reused"

# --- an unanswered call that aged off the Decisions page is raised again -----------
assert_equals "$(decision "$NEXT" 2026-10-16T14:00:00Z)" "" "a call held 14 days ages off the decisions list"
assert_equals "$(FM_RELEASE_NOW=2026-10-15T14:00:00Z release card truss)" "$NEXT" "a call held 13 days is re-held"
AGED_AGAIN=$(FM_RELEASE_NOW=2026-10-16T14:00:00Z release card truss)
assert_equals "$AGED_AGAIN" "release-truss-1792159200" "an aged call is replaced by a new call"
assert_equals "$(site truss | jq -r .card)" "$AGED_AGAIN" "the replacement is stored in the record"
assert_equals "$(decision "$AGED_AGAIN" 2026-10-16T14:00:00Z | jq -r .question)" \
  "Send truss to production? 2 changes waiting, staging https://truss-staging.netlify.app at def5678" \
  "the replacement shows on the decisions list"
rc=0; in_home "$ROOT/bin/fm-captain-hold.sh" open "$NEXT" || rc=$?
expect_code 1 "$rc" "the aged call is closed"
AGED_BODY=$(cd "$HOME_DIR" && tasks-axi show "$NEXT")
assert_contains "$AGED_BODY" "Reconciliation evidence:" "the aged call records why it closed"
assert_contains "$AGED_BODY" "raised the release call again as $AGED_AGAIN" "the close names the replacement"
assert_not_contains "$AGED_BODY" "Captain decision:" "the close is never recorded as the captain's answer"
pass "an aged call is superseded by a fresh call"

# --- sites[] in the home summary --------------------------------------------------
FM_RELEASE_NOW=2026-10-02T15:00:00Z release record acme --production-url https://acme.example \
  --deploy production --result failed >/dev/null
printf 'not json' > "$HOME_DIR/data/sites/broken.json"
SITES=$(summary | jq -c '.sites')
assert_equals "$(printf '%s' "$SITES" | jq -c 'map(.project)')" '["acme","nolink","nosha","truss"]' "one row per readable record, sorted"
assert_equals "$(printf '%s' "$SITES" | jq -c '.[0]')" \
  '{"project":"acme","staging_url":null,"production_url":"https://acme.example","staging_sha":null,"waiting":null,"last_deploy":{"env":"production","result":"failed","at":"2026-10-02T15:00:00Z"}}' \
  "row carries links, waiting count, and last deploy result"
assert_equals "$(printf '%s' "$SITES" | jq -c '.[3] | {staging_sha,card:has("card"),card_sha:has("card_sha")}')" \
  '{"staging_sha":"def5678","card":false,"card_sha":false}' "the staging commit is published and the internal card fields are not"
rm -rf "$HOME_DIR/data/sites"
assert_equals "$(summary | jq -c .sites)" '[]' "no records publish an empty list"
pass "home summary publishes sites[]"
