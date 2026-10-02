#!/usr/bin/env bash
# fm-release.sh - per-project site records and the "send to production" call.
#
# Usage:
#   fm-release.sh record <project> [--staging-url <url>] [--production-url <url>] \
#     [--staging-sha <commit>] [--waiting <n>] [--deploy staging|production --result ok|failed]
#   fm-release.sh card <project>
#
# `record` merges the given fields into data/sites/<project>.json, the small
# per-project record firstmate updates after each deploy. Fields:
#   project         the slug the file is named for
#   staging_url     the project's one fixed staging link
#   production_url  the live site
#   staging_sha     the commit staging runs, 7-40 lowercase hex characters
#   waiting         changes merged to the work branch and not yet in production
#   last_deploy     {env:"staging"|"production", result:"ok"|"failed", at:<UTC>}
#   card            the task id of the newest release call (written by `card`)
#   card_sha        the staging commit that call pins (written by `card`)
#   updated         UTC time of the last write
# Omitted flags keep their stored value. --deploy and --result go together and
# stamp last_deploy.at with the current time. The write is atomic (temporary
# file renamed over the record). bin/fm-fleet-snapshot.sh publishes every record
# as the home summary's sites[] list.
#
# `card` raises one captain call, "Send <project> to production? <n> changes
# waiting, staging <url> at <short-sha>", with the answer options send and
# not-yet, through bin/fm-captain-hold.sh hold. It reads <n>, the staging link,
# and staging_sha from the record, refuses when nothing is waiting or no
# staging link or commit is recorded, and pins staging_sha as `card_sha`.
# While the project's previous call is still open it re-holds that same task,
# so the wording follows the current count and commit and a stale answer is
# refused by its question fingerprint; when the commit differs from the one the
# call pinned before, the wording adds "staging moved from <old-short-sha>".
# An open call whose hold is at least FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS old
# (default 14) has aged off the Decisions page, so it is closed through
# bin/fm-captain-hold.sh reconcile supersede, recorded as superseded and never as
# the captain's answer, and replaced. A replacement, or any call raised after
# the previous one closed, is a new release-<project>-<epoch> task stored as
# `card`. The call then appears in decisions_open like any other hold and its
# answer returns through the ordinary keyed-answer intake. This script never
# deploys: after a `send` answer firstmate moves the production branch to
# exactly the record's card_sha, the commit the answered call showed, and never
# to a newer staging commit; it then starts that project's production job and
# records the outcome here with --deploy production.
#
# FM_RELEASE_NOW (UTC YYYY-MM-DDTHH:MM:SSZ) pins the clock for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SITES="$DATA/sites"
NOW=${FM_RELEASE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

fail() { echo "fm-release: $*" >&2; exit 1; }
usage() { sed -n '3,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
epoch_of() { date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null; }

command -v jq >/dev/null 2>&1 || fail "jq is required"

check_project() {
  case "$1" in ''|*[!a-z0-9._-]*|.*) fail "project must be a lowercase slug: $1" ;; esac
}
# Links go into a one-line hold reason, which forbids parentheses.
check_url() {
  case "$1" in
    http://*|https://*) : ;;
    *) fail "link must start with http:// or https://: $1" ;;
  esac
  case "$1" in *[[:space:]\(\)]*) fail "link must not contain spaces or parentheses: $1" ;; esac
}

read_record() {  # <project> - prints the stored record or {}
  local file="$SITES/$1.json"
  if [ -f "$file" ]; then
    jq -ce 'select(type == "object")' "$file" 2>/dev/null || fail "unreadable site record: $file"
  else
    printf '{}\n'
  fi
}

write_record() {  # <project> <json>
  local tmp
  mkdir -p "$SITES" || fail "cannot create $SITES"
  tmp=$(mktemp "$SITES/.$1.XXXXXX") || fail "cannot write $SITES"
  if ! { printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$SITES/$1.json"; }; then
    rm -f "$tmp"
    fail "cannot write $SITES/$1.json"
  fi
}

command_record() {
  local project=${1:-} staging='' production='' sha='' waiting='' env='' result='' rec
  [ -n "$project" ] || { usage >&2; exit 2; }
  shift
  check_project "$project"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --staging-url) shift; staging=${1:-}; check_url "$staging" ;;
      --production-url) shift; production=${1:-}; check_url "$production" ;;
      --staging-sha) shift; sha=${1:-}
        case "$sha" in *[!0-9a-f]*) fail "--staging-sha must be a lowercase hex commit: $sha" ;; esac
        [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 40 ] || fail "--staging-sha must be 7-40 hex characters: $sha" ;;
      --waiting) shift; waiting=${1:-}
        case "$waiting" in ''|*[!0-9]*) fail "--waiting must be a whole number: $waiting" ;; esac ;;
      --deploy) shift; env=${1:-}
        case "$env" in staging|production) : ;; *) fail "--deploy must be staging or production: $env" ;; esac ;;
      --result) shift; result=${1:-}
        case "$result" in ok|failed) : ;; *) fail "--result must be ok or failed: $result" ;; esac ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  { [ -n "$env" ] && [ -n "$result" ]; } || { [ -z "$env" ] && [ -z "$result" ]; } \
    || fail "--deploy and --result go together"
  rec=$(read_record "$project") || exit 1
  rec=$(printf '%s' "$rec" | jq -c --arg p "$project" --arg s "$staging" --arg pr "$production" \
    --arg sha "$sha" --arg w "$waiting" --arg e "$env" --arg r "$result" --arg now "$NOW" '
    . + {project:$p, updated:$now}
    + (if $s == "" then {} else {staging_url:$s} end)
    + (if $pr == "" then {} else {production_url:$pr} end)
    + (if $sha == "" then {} else {staging_sha:$sha} end)
    + (if $w == "" then {} else {waiting:($w | tonumber)} end)
    + (if $e == "" then {} else {last_deploy:{env:$e, result:$r, at:$now}} end)') \
    || fail "cannot update the record for $project"
  write_record "$project" "$rec"
  printf '%s\n' "$rec"
}

command_card() {
  local project=${1:-} rec waiting staging sha card card_sha identity age_days held_days aged='' reason moved='' epoch evidence
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  check_project "$project"
  age_days=${FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS:-14}
  case "$age_days" in ''|*[!0-9]*) fail "FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS must be a whole number: $age_days" ;; esac
  rec=$(read_record "$project") || exit 1
  waiting=$(printf '%s' "$rec" | jq -r '.waiting // 0')
  staging=$(printf '%s' "$rec" | jq -r '.staging_url // ""')
  sha=$(printf '%s' "$rec" | jq -r '.staging_sha // ""')
  [ "$waiting" -gt 0 ] || fail "$project has no changes waiting for production"
  [ -n "$staging" ] || fail "$project has no staging link recorded"
  [ -n "$sha" ] || fail "$project has no staging commit recorded"
  epoch=$(epoch_of "$NOW") || fail "cannot read the clock"
  card=$(printf '%s' "$rec" | jq -r '.card // ""')
  card_sha=$(printf '%s' "$rec" | jq -r '.card_sha // ""')
  if [ -n "$card" ] && identity=$("$SCRIPT_DIR/fm-captain-hold.sh" open "$card" --identity 2>/dev/null); then
    held_days=$(epoch_of "${identity%%#*}") || fail "cannot read when $card was raised"
    held_days=$(( (epoch - held_days) / 86400 ))
    if [ "$held_days" -ge "$age_days" ]; then
      aged=$card
    elif [ -n "$card_sha" ] && [ "$card_sha" != "$sha" ]; then
      moved=", staging moved from ${card_sha:0:7}"
    fi
  else
    card=''
  fi
  [ -n "$card" ] && [ -z "$aged" ] || card="release-$project-$epoch"
  if [ "$waiting" -eq 1 ]; then
    reason="Send $project to production? 1 change waiting, staging $staging at ${sha:0:7}$moved"
  else
    reason="Send $project to production? $waiting changes waiting, staging $staging at ${sha:0:7}$moved"
  fi
  FM_CAPTAIN_HOLD_NOW=$NOW "$SCRIPT_DIR/fm-captain-hold.sh" hold "$card" --title "Send $project to production" \
    --repo "$project" --reason "$reason" --option send=Send --option not-yet="Not yet" >/dev/null \
    || fail "could not raise the release call for $project"
  write_record "$project" "$(printf '%s' "$rec" | jq -c --arg c "$card" --arg sha "$sha" --arg now "$NOW" \
    '. + {card:$c, card_sha:$sha, updated:$now}')"
  if [ -n "$aged" ]; then
    evidence=$(mktemp "${TMPDIR:-/tmp}/fm-release-evidence.XXXXXX") || fail "cannot stage the superseded record"
    printf 'Aged off the Decisions page after %s days unanswered; firstmate raised the release call again as %s.\n' \
      "$held_days" "$card" > "$evidence"
    FM_CAPTAIN_HOLD_NOW=$NOW "$SCRIPT_DIR/fm-captain-hold.sh" reconcile supersede "$aged" --by "$card" --evidence-file "$evidence" >/dev/null \
      || { rm -f "$evidence"; fail "raised $card but could not close the aged call $aged"; }
    rm -f "$evidence"
  fi
  printf '%s\n' "$card"
}

case "${1:-}" in
  record) shift; command_record "$@" ;;
  card) shift; command_card "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
