#!/usr/bin/env bash
# Behavioral tests for the captain-answer drop folder: structured hold options,
# the home-summary fields a local answer channel reads, and
# bin/fm-procevent-answer-drop.sh accept, reject, and replay paths through the
# real keyed-answer intake and the generic process-event runner.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-procevent-answer-drop)
HOME_DIR="$TMP_ROOT/home"
ADAPTER="$ROOT/bin/fm-procevent-answer-drop.sh"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
FAKEBIN=$(fm_fakebin "$HOME_DIR")
fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi
fm_test_track_procevent_home "$HOME_DIR" "$HOME_DIR/claims"
INBOX="$HOME_DIR/state/answer-drop"

in_home() {  # <command...>
  (cd "$HOME_DIR" && PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_PROCEVENT_CLAIM_ROOT="$HOME_DIR/claims" FM_ANSWER_DROP_POLL_SECONDS=1 "$@")
}
hold() { in_home "$ROOT/bin/fm-captain-hold.sh" hold "$@" >/dev/null; }
summary() { in_home "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary; }
sha() { printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}'; }
decision() { summary | jq -c --arg id "$1" '.decisions_open[] | select(.id == $id)'; }
drop() {  # <name> <hold-id> <fingerprint> <answer-json> [note]; DROP_SOURCE overrides aios-ui
  jq -cn --arg h "$2" --arg fp "$3" --argjson a "$4" --arg note "${5-}" --arg src "${DROP_SOURCE:-aios-ui}" \
    '{hold_id:$h,question_fingerprint:$fp,answer:$a,answered_at:"2026-10-01T00:00:00Z",source:$src}
     + (if $note == "" then {} else {note:$note} end)' > "$INBOX/$1"
}
seen() { in_home "$ADAPTER" summary | jq -r --arg f "$1" '.answers_seen[] | select(.file == $f) | "\(.status) \(.reason // "")"'; }
# Drive one round exactly as the runner would: capture the poll, then autohandle.
round() {  # <sequence>
  local result="$TMP_ROOT/result.$1"
  in_home "$ADAPTER" poll > "$result"
  in_home "$ADAPTER" autohandle answer-drop "$1" "$result" >/dev/null 2>&1 || true
}
body_of() { (cd "$HOME_DIR" && tasks-axi show "$1") | sed -n 's/^  body: //p'; }

# --- structured options -------------------------------------------------------
hold q-db --title "Pick a database" --reason "Postgres or SQLite?" --repo demo \
  --option pg=Postgres --option lite=SQLite
hold q-name --title "Name the service" --reason "What should we call it?"
rc=0; hold q-dup --title x --reason y --option a=A --option a=B 2>/dev/null || rc=$?
expect_code 1 "$rc" "duplicate option keys are refused"
rc=0; hold q-res --title x --reason y --option reconcile=Recheck 2>/dev/null || rc=$?
expect_code 1 "$rc" "the reserved reconcile key is refused"
pass "hold records repeatable options and refuses duplicate or reserved keys"

# --- summary fields -------------------------------------------------------------
fm_write_meta "$HOME_DIR/state/w1.meta" kind=ship model=opus-test project=/x/projects/widget
printf 'working [at=1790000000]: started\n' > "$HOME_DIR/state/w1.status"
doc=$(summary)
assert_equals "$(printf '%s' "$doc" | jq -r '.generated_at == .generated and (.generated_at | test("Z$"))')" true "generated_at"
assert_equals "$(printf '%s' "$doc" | jq -r .answers_inbox)" "$(cd "$INBOX" && pwd -P)" "answers_inbox is the absolute drop folder"
assert_equals "$(printf '%s' "$doc" | jq -c '.answers_seen')" "[]" "answers_seen starts empty"
assert_equals "$(printf '%s' "$doc" | jq -c '.fleet[0] | {kind,task_id,project,model,since}')" \
  '{"kind":"crewmate","task_id":"w1","project":"widget","model":"opus-test","since":"2026-09-21T14:13:20Z"}' "fleet entry"
assert_contains "working parked done blocked paused failed unknown" "$(printf '%s' "$doc" | jq -r '.fleet[0].state')" "fleet state enum"
FP_DB=$(sha "Postgres or SQLite?")
FP_NAME=$(sha "What should we call it?")
assert_equals "$(decision q-db | jq -c '{project,options,question_fingerprint}')" \
  "{\"project\":\"demo\",\"options\":[{\"key\":\"pg\",\"label\":\"Postgres\"},{\"key\":\"lite\",\"label\":\"SQLite\"}],\"question_fingerprint\":\"$FP_DB\"}" \
  "structured decision fields"
assert_equals "$(decision q-name | jq -c '{options,question_fingerprint}')" \
  "{\"options\":[],\"question_fingerprint\":\"$FP_NAME\"}" "free-text hold has no options"
assert_equals "$(decision q-db | jq -r .question_fingerprint)" "$FP_DB" "fingerprint is stable across reads"
LONG_Q="$(printf 'Should the importer keep retrying failed rows %.0s' 1 2 3 4 5)until the nightly window closes?"
hold q-long --title "Importer retries" --reason "$LONG_Q"
assert_equals "$(decision q-long | jq -r '.question')" "$LONG_Q" "question carries the full untruncated hold text"
assert_equals "$(decision q-long | jq -r '.question_fingerprint')" "$(sha "$LONG_Q")" "question_fingerprint hashes question"
assert_equals "$(decision q-long | jq -r '.reason | length < ($q | length)' --arg q "$LONG_Q")" true "reason stays clipped"
rm -f "$HOME_DIR/state/w1.meta" "$HOME_DIR/state/w1.status"
pass "home summary publishes generated_at, fleet, options, fingerprints, and the drop folder"

# --- adapter accept and reject ---------------------------------------------------
drop q-db-1.json q-db "$FP_DB" '{"option":"pg"}' "ship it"
drop q-name-2.json q-name "$FP_DB" '{"text":"Nova"}'
printf 'not json' > "$INBOX/q-name-3.json"
drop q-name-4.json q-name "$FP_NAME" '{"option":"pg"}'
drop q-gone-5.json q-gone "$FP_NAME" '{"text":"x"}'
printf '{}' > "$INBOX/.q-name-6.json.tmp"
round 1
assert_equals "$(seen q-db-1.json)" "resolved " "option answer resolves"
assert_contains "$(body_of q-db)" "Captain answered this call through aios-ui." "intake records the aios-ui source"
assert_contains "$(body_of q-db)" "Answer: pg; note: ship it" "answer and note are recorded"
assert_contains "$(body_of q-db)" "Answer as shown to the captain: Postgres" "option label is recorded"
assert_equals "$(seen q-name-2.json)" "rejected question-changed" "fingerprint mismatch is rejected"
assert_equals "$(seen q-name-3.json)" "rejected malformed" "invalid JSON is rejected"
assert_equals "$(seen q-name-4.json)" "rejected unknown-option" "an option the hold lacks is rejected"
assert_equals "$(seen q-gone-5.json)" "rejected not-open" "an unknown hold is rejected"
assert_present "$INBOX/handled/q-db-1.json" "expected q-db-1.json"
assert_present "$INBOX/rejected/q-name-2.json" "expected q-name-2.json"
assert_present "$INBOX/.q-name-6.json.tmp" "expected .q-name-6.json.tmp"
assert_equals "$(seen .q-name-6.json.tmp)" "" "temp files are never read"
pass "adapter resolves valid answers and rejects mismatched, malformed, and unknown ones"

drop q-db-7.json q-db "$FP_DB" '{"option":"lite"}'
round 2
assert_equals "$(seen q-db-7.json)" "rejected already-answered" "a later answer is rejected"
pass "the first answer wins across channels"

# --- reworded question ------------------------------------------------------------
hold q-name --reason "What should the public name be?"
drop q-name-8.json q-name "$FP_NAME" '{"text":"Nova"}'
round 3
assert_equals "$(seen q-name-8.json)" "rejected question-changed" "a reworded hold rejects the old fingerprint"
drop q-name-9.json q-name "$(sha "What should the public name be?")" '{"text":"Nova"}'
round 4
assert_equals "$(seen q-name-9.json)" "resolved " "the current fingerprint resolves"
pass "question_fingerprint follows the hold's current wording"

# --- release mode for a held work item ---------------------------------------------
(cd "$HOME_DIR" && tasks-axi add w-gate "Gated work" --kind ship --repo demo >/dev/null)
hold w-gate --reason "Merge now?" --option yes=Merge
drop w-gate-10.json w-gate "$(sha "Merge now?")" '{"option":"yes"}'
round 5
assert_equals "$(seen w-gate-10.json)" "resolved " "held work item answer resolves"
assert_contains "$(body_of w-gate)" "Resolution mode: released" "a held work item is released, not completed"
assert_equals "$(cd "$HOME_DIR" && tasks-axi show w-gate | sed -n 's/^  state: //p')" queued "released work stays open"
pass "close mode comes from the hold, not the file"

# --- source allow-list -------------------------------------------------------------
hold q-deck --title "Deck" --reason "Deck?" --option a=A
hold q-deck-text --title "Deck text" --reason "Deck words?"
DROP_SOURCE=fm-deck drop q-deck-20.json q-deck "$(sha "Deck?")" '{"option":"a"}'
DROP_SOURCE=fm-deck drop q-deck-text-21.json q-deck-text "$(sha "Deck words?")" '{"text":"later today"}'
DROP_SOURCE=someone-else drop q-deck-22.json q-deck "$(sha "Deck?")" '{"option":"a"}'
round 20
assert_equals "$(seen q-deck-20.json)" "resolved " "an fm-deck option answer resolves"
assert_contains "$(body_of q-deck)" "Captain answered this call through fm-deck." "intake records the fm-deck source"
assert_equals "$(seen q-deck-text-21.json)" "resolved " "an fm-deck text answer resolves"
assert_contains "$(body_of q-deck-text)" "Captain answered this call through fm-deck." "a text answer keeps its fm-deck source"
assert_equals "$(seen q-deck-22.json)" "rejected malformed" "a source outside the allow-list is rejected"
hold q-deck-replay --title "Deck replay" --reason "Deck replay?" --option a=A
DROP_SOURCE=fm-deck drop q-deck-replay-23.json q-deck-replay "$(sha "Deck replay?")" '{"option":"a"}'
round 21
mv "$INBOX/handled/q-deck-replay-23.json" "$INBOX/q-deck-replay-23.json"
grep -v '"file":"q-deck-replay-23.json","hold_id":"q-deck-replay","status":"resolved"' \
  "$HOME_DIR/state/answer-drop.seen.jsonl" > "$TMP_ROOT/seen" && cp "$TMP_ROOT/seen" "$HOME_DIR/state/answer-drop.seen.jsonl"
round 22
assert_equals "$(seen q-deck-replay-23.json)" "resolved " "a picked-up fm-deck answer replays"
assert_contains "$(body_of q-deck-replay)" "Captain answered this call through fm-deck." "replay keeps the recorded source"
pass "the adapter accepts aios-ui and fm-deck sources, passes the source to the intake, and rejects any other"

# --- replay and restart idempotence -------------------------------------------------
hold q-replay --title "Replay" --reason "Replay?" --option a=A
drop q-replay-11.json q-replay "$(sha "Replay?")" '{"option":"a"}'
round 6
assert_equals "$(seen q-replay-11.json)" "resolved " "first delivery resolves"
# A crash after the intake closed the hold but before the outcome was recorded.
mv "$INBOX/handled/q-replay-11.json" "$INBOX/q-replay-11.json"
grep -v '"file":"q-replay-11.json","hold_id":"q-replay","status":"resolved"' \
  "$HOME_DIR/state/answer-drop.seen.jsonl" > "$TMP_ROOT/seen" && cp "$TMP_ROOT/seen" "$HOME_DIR/state/answer-drop.seen.jsonl"
assert_equals "$(seen q-replay-11.json)" "picked_up " "crash leaves the pickup record"
round 7
assert_equals "$(seen q-replay-11.json)" "resolved " "replay of a picked-up answer is idempotent"
assert_equals "$(body_of q-replay | grep -o 'Resolution recorded by fm-captain-hold' | wc -l | tr -d ' ')" 1 "replay records no second answer"
# A crash after the outcome was recorded but before the file moved; the
# archived copy already present is kept beside it rather than overwritten.
cp "$INBOX/handled/q-replay-11.json" "$INBOX/q-replay-11.json"
round 8
assert_present "$INBOX/handled/q-replay-11.json" "expected q-replay-11.json"
assert_present "$INBOX/handled/q-replay-11.json."* "expected q-replay-11.json."
pass "replay after a crash is idempotent and never deletes evidence"

# --- runner integration --------------------------------------------------------------
hold q-run --title "Runner" --reason "Run?"
drop q-run-12.json q-run "$(sha "Run?")" '{"text":"yes"}'
assert_contains "$(in_home "$ADAPTER" arm --if-pending)" "armed: answer-drop" "first waiting answer arms the source"
assert_contains "$(in_home "$ADAPTER" arm)" "already-armed" "arm is idempotent"
in_home "$ROOT/bin/fm-procevent.sh" start answer-drop > "$TMP_ROOT/start.out" 2>&1 &
for _ in $(seq 1 30); do [ -e "$INBOX/handled/q-run-12.json" ] && break; sleep 1; done
assert_equals "$(seen q-run-12.json)" "resolved " "runner round resolves"
assert_grep 'check: procevent answer-drop answer-drop' "$HOME_DIR/state/.wake-queue"
for _ in $(seq 1 10); do [ -e "$HOME_DIR/state/procevent-inbox/answer-drop.1.handled" ] && break; sleep 1; done
assert_present "$HOME_DIR/state/procevent-inbox/answer-drop.1.handled" "expected answer-drop.1.handled"
assert_contains "$(in_home "$ADAPTER" read "$HOME_DIR/state/procevent-inbox/answer-drop.1.result")" "q-run-12.json	resolved" "read reports outcomes"
in_home "$ADAPTER" retire >/dev/null
wait
pass "runner captures, wakes, applies, and acknowledges a dropped answer"
