#!/usr/bin/env bash
# Captain-answer drop-folder adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-answer-drop.sh arm [--if-pending]
#   fm-procevent-answer-drop.sh poll
#   fm-procevent-answer-drop.sh classify <result-file>
#   fm-procevent-answer-drop.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-answer-drop.sh relisten
#   fm-procevent-answer-drop.sh read <result-file>
#   fm-procevent-answer-drop.sh summary
#   fm-procevent-answer-drop.sh source-id
#   fm-procevent-answer-drop.sh retire
#
# A local structured answer channel answers an open captain hold by dropping
# one JSON file into this home's drop folder, state/answer-drop/, which the home
# summary publishes as answers_inbox. A file's `source` names its writer and
# must be aios-ui (claude-os ADR 0012) or fm-deck (the in-session Captain's Call
# pane, docs/fm-deck.md); any other value is rejected malformed.
# This adapter turns each file into one keyed line for bin/fm-captain-hold.sh
# answers --source <the file's source> and records the outcome in answers_seen.
# It never decides what an answer means: the intake owns every close rule.
#
# arm        Create the drop folder and register the persistent `answer-drop`
#            source unless it is already registered. With --if-pending it
#            registers only when an answer file is already waiting, which is how
#            bin/fm-home-summary-refresh.sh arms a home on first use. The
#            watcher's next reconcile starts the listener.
# poll       The blocking child the runner executes; never run it in a
#            conversational turn. It waits until the drop folder holds an
#            eligible file, then prints `answer-drop: <folder>` and one
#            `file: <name>` line per file (at most 50, name order).
# classify   Print `answers` for a result that lists files, else `unknown`.
# autohandle The runner's apply step, after the wake is published. Handles
#            every listed file still in the folder, refreshes the home summary,
#            and acknowledges the result once no file is left in a transient
#            state; otherwise the result stays unacknowledged for retry.
# relisten   Exit 0, so one runner keeps polling after a handled result.
# read       Print `<file>\t<status>\t<reason>\t<hold_id>` per listed file
#            from the seen ledger, for the handler of the wake.
# summary    Print {answers_inbox, answers_seen} JSON for the home summary,
#            creating the drop folder on demand. answers_seen holds the latest
#            {file, hold_id, status, reason, at} per file, newest first, at
#            most 50.
# source-id  Print the canonical source id, `answer-drop`.
# retire     Retire the source registration.
#
# DROP FILE CONTRACT. A writer renames a complete file into the folder root as
# `<hold_id>-<epoch-ms>.json`:
#   {"hold_id", "question_fingerprint", "answer": {"option": "<key>"} | {"text": "<words>"},
#    "note"?, "answered_at", "source": "aios-ui"}
# Only root names made of [A-Za-z0-9._-] ending in .json are read; dotfiles,
# other names, symlinks, and subfolders are ignored, so a writer's temp file is
# never read. A read file ends in handled/ (resolved) or rejected/ and is never
# deleted; a name already present there gets an epoch suffix.
#
# Outcomes (answers_seen status and reason):
#   picked_up            validated and about to be fed; a crash here is replayed
#                        with the exact recorded line, so replay stays idempotent
#   resolved             the intake recorded the answer (or an exact replay)
#   rejected malformed   bad name, oversized, invalid JSON, wrong fields or source
#   rejected question-changed  fingerprint differs from the hold as now worded
#   rejected unknown-option    option key not among the hold's options
#   rejected too-long    answer plus note exceed the intake's 500-character bound
#   rejected already-answered  the hold was already answered another way
#   rejected not-open    no such task, or it is not an open captain hold
#   rejected intake: <reason>  any other refusal the intake printed
# An option answer feeds `<key>` with its label as shown; a text answer feeds
# the words; a note is appended to the answer as `; note: <note>`. The close
# mode is chosen here from the hold, never from the file: a row minted for the
# question (kind captain) completes, while a held work item is released.
#
# question_fingerprint is defined once, beside backlog_answer_fields in
# bin/fm-fleet-snapshot.sh; this adapter compares against that same value read
# through `fm-fleet-snapshot.sh --contribution-input`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

SOURCE_ID='answer-drop'
INBOX="$STATE/answer-drop"
SEEN="$STATE/answer-drop.seen.jsonl"
LOCK="$STATE/.answer-drop.lock"
ROUND_MAX=50
SEEN_SHOWN=50
SEEN_KEEP=500
MAX_FILE_BYTES=65536
MAX_ANSWER_CHARS=500
POLL_SECONDS=${FM_ANSWER_DROP_POLL_SECONDS:-5}
case "$POLL_SECONDS" in ''|*[!0-9]*|0) POLL_SECONDS=5 ;; esac
HOLDS=
LOCK_HELD=0

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

cleanup() {
  [ -z "$HOLDS" ] || rm -f -- "$HOLDS"
  [ "$LOCK_HELD" -eq 0 ] || fm_lock_release "$LOCK" || true
}
trap cleanup EXIT

ensure_inbox() {
  (umask 077; mkdir -p "$INBOX") && [ -d "$INBOX" ] && [ ! -L "$INBOX" ]
}

pending_files() {
  local f name
  [ -d "$INBOX" ] || return 0
  for f in "$INBOX"/*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    name=${f##*/}
    [[ "$name" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*\.json$ ]] || continue
    printf '%s\n' "$name"
  done | LC_ALL=C sort | head -n "$ROUND_MAX"
}

registered() {
  local f
  f="$(fm_procevent_registry_dir "$STATE")/$SOURCE_ID.source"
  [ -f "$f" ] && [ ! -L "$f" ] && grep -qx "adapter=$SOURCE_ID" "$f"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Append one ledger record; keep the newest SEEN_KEEP lines once it doubles.
seen_append() {  # <file> <hold-id> <status> <reason> [<answer> <label> <mode> <source>]
  local lines tmp
  jq -cn --arg file "$1" --arg hold "$2" --arg status "$3" --arg reason "$4" --arg at "$(now_iso)" \
    --arg answer "${5-}" --arg label "${6-}" --arg mode "${7-}" --arg source "${8-}" \
    --argjson line "$([ "$#" -ge 8 ] && echo true || echo false)" '
    {file:$file,hold_id:(if $hold == "" then null else $hold end),status:$status,
     reason:(if $reason == "" then null else $reason end),at:$at}
    + (if $line then {line:{answer:$answer,label:$label,mode:$mode,source:$source}} else {} end)' >> "$SEEN" || return 1
  lines=$(wc -l < "$SEEN" | tr -d '[:space:]')
  if [ "${lines:-0}" -gt $((SEEN_KEEP * 2)) ]; then
    tmp=$(umask 077; mktemp "$SEEN.XXXXXX") || return 0
    tail -n "$SEEN_KEEP" "$SEEN" > "$tmp" && mv -f -- "$tmp" "$SEEN"
    rm -f -- "$tmp"
  fi
}

seen_latest() {  # <file>
  [ -f "$SEEN" ] || return 0
  jq -c --arg f "$1" 'select(.file == $f)' "$SEEN" 2>/dev/null | tail -n 1
}

archive() {  # <name> <handled|rejected>
  local dir="$INBOX/$2" target
  (umask 077; mkdir -p "$dir") || return 1
  target="$dir/$1"
  [ ! -e "$target" ] && [ ! -L "$target" ] || target="$target.$(date +%s)"
  mv -- "$INBOX/$1" "$target"
}

reject() {  # <name> <hold-id> <reason>
  seen_append "$1" "$2" rejected "$3" && archive "$1" rejected
}

# Feed one recorded line to the intake and settle the file from its verdict.
# Returns 1 only when the intake printed no verdict (a transient failure).
feed() {  # <name> <hold-id> <answer> <label> <mode> <source>
  local name=$1 hold=$2 out verdict
  out=$(printf '%s\t%s\t%s\t%s\n' "$hold" "$3" "$4" "$5" \
    | "$SCRIPT_DIR/fm-captain-hold.sh" answers --source "$6" 2>/dev/null) || true
  verdict=$(printf '%s\n' "$out" | grep -E "^(closed|skipped|refused): " | head -n 1)
  case "$verdict" in
    "closed: $hold") seen_append "$name" "$hold" resolved "" && archive "$name" handled ;;
    *"(already closed)") reject "$name" "$hold" already-answered ;;
    *"(not held for the captain)"|*"(absent)"|*"(no captain-held task with that id)") reject "$name" "$hold" not-open ;;
    skipped:*|refused:*)
      verdict=${verdict#*: }
      verdict=${verdict#"$hold"}
      verdict=${verdict# (}
      reject "$name" "$hold" "intake: ${verdict%)}"
      ;;
    *) return 1 ;;
  esac
}

load_holds() {
  HOLDS=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-answer-drop-holds.XXXXXX") || return 1
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$HOLDS" 2>/dev/null \
    && jq -e '.backlog | type == "object"' "$HOLDS" >/dev/null 2>&1
}

process_file() {  # <name>
  local name=$1 path="$INBOX/$1" last status hold size doc rec fp answer label mode note open source
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  last=$(seen_latest "$name")
  status=$(printf '%s' "$last" | jq -r '.status // empty' 2>/dev/null)
  case "$status" in
    resolved) archive "$name" handled; return ;;
    rejected) archive "$name" rejected; return ;;
    picked_up)
      hold=$(printf '%s' "$last" | jq -r '.hold_id')
      feed "$name" "$hold" "$(printf '%s' "$last" | jq -r '.line.answer')" \
        "$(printf '%s' "$last" | jq -r '.line.label')" "$(printf '%s' "$last" | jq -r '.line.mode')" \
        "$(printf '%s' "$last" | jq -r '.line.source // "aios-ui"')"
      return
      ;;
  esac
  if [[ ! "$name" =~ ^([A-Za-z0-9._-]+)-[0-9]+\.json$ ]]; then
    reject "$name" "" malformed
    return
  fi
  hold=${BASH_REMATCH[1]}
  size=$(wc -c < "$path" | tr -d '[:space:]')
  if [ "${size:-0}" -gt "$MAX_FILE_BYTES" ]; then
    reject "$name" "$hold" malformed
    return
  fi
  doc=$(jq -c --arg hold "$hold" '
    def text: type == "string" and (gsub("\\s"; "") | length) > 0;
    select(type == "object" and .hold_id == $hold and (.source | IN("aios-ui", "fm-deck"))
      and (.question_fingerprint | type) == "string" and (.question_fingerprint | test("^[0-9a-f]{64}$"))
      and (.answered_at | type) == "string"
      and ((.note // "") | type) == "string"
      and (.answer | type) == "object"
      and ((.answer | keys) == ["option"] or (.answer | keys) == ["text"])
      and ((.answer.option // .answer.text) | text))' "$path" 2>/dev/null) || doc=
  if [ -z "$doc" ]; then
    reject "$name" "$hold" malformed
    return
  fi
  rec=$(jq -c --arg id "$hold" '[.backlog.records[]? | select(.structured and .id == $id)] | .[0] // empty' "$HOLDS")
  if [ -z "$rec" ]; then
    reject "$name" "$hold" not-open
    return
  fi
  open=$(printf '%s' "$rec" | jq -r 'if .state != "done" and .hold_kind == "captain" then 1 else 0 end')
  if [ "$open" != 1 ]; then
    if printf '%s' "$rec" | jq -e 'any(.body_lines[]?; test("^Resolution recorded by fm-(captain|decision)-hold\\.$"))' >/dev/null; then
      reject "$name" "$hold" already-answered
    else
      reject "$name" "$hold" not-open
    fi
    return
  fi
  fp=$(printf '%s' "$rec" | jq -r '.question_fingerprint // empty')
  if [ "$fp" != "$(printf '%s' "$doc" | jq -r '.question_fingerprint')" ]; then
    reject "$name" "$hold" question-changed
    return
  fi
  if printf '%s' "$doc" | jq -e '.answer | has("option")' >/dev/null; then
    answer=$(printf '%s' "$doc" | jq -r '.answer.option')
    label=$(jq -rn --argjson r "$rec" --arg k "$answer" '[$r.options[]? | select(.key == $k) | .label] | .[0] // empty')
    if [ -z "$label" ]; then
      reject "$name" "$hold" unknown-option
      return
    fi
  else
    answer=$(printf '%s' "$doc" | jq -r '.answer.text')
    label=
  fi
  note=$(printf '%s' "$doc" | jq -r '.note // ""')
  [ -z "$note" ] || answer="$answer; note: $note"
  answer=$(printf '%s' "$answer" | tr '\t\r\n' '   ')
  if [ "${#answer}" -gt "$MAX_ANSWER_CHARS" ]; then
    reject "$name" "$hold" too-long
    return
  fi
  if [ "$(printf '%s' "$rec" | jq -r '.kind // ""')" = captain ]; then mode=; else mode=release; fi
  source=$(printf '%s' "$doc" | jq -r '.source')
  seen_append "$name" "$hold" picked_up "" "$answer" "$label" "$mode" "$source" || return 1
  feed "$name" "$hold" "$answer" "$label" "$mode" "$source"
}

cmd_arm() {
  local if_pending=0
  case "${1-}" in '') ;; --if-pending) if_pending=1 ;; *) usage ;; esac
  ensure_inbox || die "cannot create the drop folder: $INBOX"
  if registered; then
    printf 'already-armed: %s\n' "$SOURCE_ID"
    return 0
  fi
  if [ "$if_pending" -eq 1 ] && [ -z "$(pending_files)" ]; then
    printf 'not-armed: no answer waiting in %s\n' "$INBOX"
    return 0
  fi
  "$SCRIPT_DIR/fm-procevent.sh" register "$SOURCE_ID" "$SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-answer-drop.sh" poll >/dev/null || exit 1
  printf 'armed: %s\n' "$SOURCE_ID"
}

cmd_poll() {
  local files
  while :; do
    files=$(pending_files)
    if [ -n "$files" ]; then
      printf 'answer-drop: %s\n' "$INBOX"
      printf '%s\n' "$files" | sed 's/^/file: /'
      exit 0
    fi
    sleep "$POLL_SECONDS"
  done
}

result_files() { sed -n 's/^file: //p' "$1"; }

cmd_classify() {
  [ -f "${1-}" ] || die "result file does not exist: ${1-}"
  if [ -n "$(result_files "$1")" ]; then printf 'answers\n'; else printf 'unknown\n'; fi
}

cmd_autohandle() {
  local sid=${1-} seq=${2-} result=${3-} name rc=0
  [ "$sid" = "$SOURCE_ID" ] || die "not the answer-drop source: $sid"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a number: $seq" ;; esac
  [ -f "$result" ] || die "result file does not exist: $result"
  fm_lock_acquire_wait "$LOCK" || die "cannot lock the drop folder"
  LOCK_HELD=1
  load_holds || die "cannot read the backlog's captain holds"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in */*|.*) continue ;; esac
    process_file "$name" || rc=1
  done < <(result_files "$result")
  fm_lock_release "$LOCK" || true
  LOCK_HELD=0
  "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort </dev/null >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ] || return 1
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null
}

cmd_read() {
  local name last
  [ -f "${1-}" ] || die "result file does not exist: ${1-}"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    last=$(seen_latest "$name")
    if [ -z "$last" ]; then
      printf '%s\tsent\t\t\n' "$name"
    else
      printf '%s' "$last" | jq -r '[.file, .status, (.reason // ""), (.hold_id // "")] | @tsv'
    fi
  done < <(result_files "$1")
}

cmd_summary() {
  local abs seen='[]'
  ensure_inbox || die "cannot create the drop folder: $INBOX"
  abs=$(cd "$INBOX" && pwd -P) || die "cannot resolve the drop folder: $INBOX"
  if [ -f "$SEEN" ]; then
    seen=$(jq -cs --argjson n "$SEEN_SHOWN" '
      reduce (reverse[] | select(type == "object" and (.file | type) == "string")) as $r
        ({seen:{},out:[]};
         if .seen[$r.file] then . else .seen[$r.file] = true | .out += [$r | {file,hold_id,status,reason,at}] end)
      | .out[:$n]' "$SEEN" 2>/dev/null) || seen='[]'
  fi
  jq -n --arg inbox "$abs" --argjson seen "$seen" '{answers_inbox:$inbox,answers_seen:$seen}'
}

case "${1-}" in
  arm)        shift; cmd_arm "$@" ;;
  poll)       shift; [ "$#" -eq 0 ] || usage; cmd_poll ;;
  classify)   shift; [ "$#" -eq 1 ] || usage; cmd_classify "$1" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  relisten)   shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  read)       shift; [ "$#" -eq 1 ] || usage; cmd_read "$1" ;;
  summary)    shift; [ "$#" -eq 0 ] || usage; cmd_summary ;;
  source-id)  shift; printf '%s\n' "$SOURCE_ID" ;;
  retire)     shift; "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
