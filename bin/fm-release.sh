#!/usr/bin/env bash
# fm-release.sh - per-project site records and the "send to production" call.
#
# Usage:
#   fm-release.sh record <project> [--staging-url <url>] [--production-url <url>] \
#     [--waiting <n>] [--deploy staging|production --result ok|failed]
#   fm-release.sh card <project>
#
# `record` merges the given fields into data/sites/<project>.json, the small
# per-project record firstmate updates after each deploy. Fields:
#   project         the slug the file is named for
#   staging_url     the project's one fixed staging link
#   production_url  the live site
#   waiting         changes merged to the work branch and not yet in production
#   last_deploy     {env:"staging"|"production", result:"ok"|"failed", at:<UTC>}
#   card            the task id of the newest release call (written by `card`)
#   updated         UTC time of the last write
# Omitted flags keep their stored value. --deploy and --result go together and
# stamp last_deploy.at with the current time. The write is atomic (temporary
# file renamed over the record). bin/fm-fleet-snapshot.sh publishes every record
# as the home summary's sites[] list.
#
# `card` raises one captain call, "Send <project> to production? <n> changes
# waiting, staging <url>", with the answer options send and not-yet, through
# bin/fm-captain-hold.sh hold. It reads <n> and the staging link from the
# record and refuses when nothing is waiting or no staging link is recorded.
# While the project's previous call is still open it re-holds that same task,
# so the wording follows the current count and a stale answer is refused by its
# question fingerprint; otherwise it mints release-<project>-<epoch> and stores
# it as `card`. The call then appears in decisions_open like any other hold and
# its answer returns through the ordinary keyed-answer intake. This script never
# deploys: after a `send` answer firstmate moves the production branch to the
# exact staging version, starts that project's production job, and records the
# outcome here with --deploy production.
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
  local project=${1:-} staging='' production='' waiting='' env='' result='' rec
  [ -n "$project" ] || { usage >&2; exit 2; }
  shift
  check_project "$project"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --staging-url) shift; staging=${1:-}; check_url "$staging" ;;
      --production-url) shift; production=${1:-}; check_url "$production" ;;
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
    --arg w "$waiting" --arg e "$env" --arg r "$result" --arg now "$NOW" '
    . + {project:$p, updated:$now}
    + (if $s == "" then {} else {staging_url:$s} end)
    + (if $pr == "" then {} else {production_url:$pr} end)
    + (if $w == "" then {} else {waiting:($w | tonumber)} end)
    + (if $e == "" then {} else {last_deploy:{env:$e, result:$r, at:$now}} end)') \
    || fail "cannot update the record for $project"
  write_record "$project" "$rec"
  printf '%s\n' "$rec"
}

command_card() {
  local project=${1:-} rec waiting staging card reason epoch
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  check_project "$project"
  rec=$(read_record "$project") || exit 1
  waiting=$(printf '%s' "$rec" | jq -r '.waiting // 0')
  staging=$(printf '%s' "$rec" | jq -r '.staging_url // ""')
  [ "$waiting" -gt 0 ] || fail "$project has no changes waiting for production"
  [ -n "$staging" ] || fail "$project has no staging link recorded"
  card=$(printf '%s' "$rec" | jq -r '.card // ""')
  if [ -z "$card" ] || ! "$SCRIPT_DIR/fm-captain-hold.sh" open "$card" >/dev/null 2>&1; then
    epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW" +%s 2>/dev/null || date -u -d "$NOW" +%s) \
      || fail "cannot read the clock"
    card="release-$project-$epoch"
  fi
  if [ "$waiting" -eq 1 ]; then
    reason="Send $project to production? 1 change waiting, staging $staging"
  else
    reason="Send $project to production? $waiting changes waiting, staging $staging"
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" hold "$card" --title "Send $project to production" \
    --repo "$project" --reason "$reason" --option send=Send --option not-yet="Not yet" >/dev/null \
    || fail "could not raise the release call for $project"
  write_record "$project" "$(printf '%s' "$rec" | jq -c --arg c "$card" --arg now "$NOW" '. + {card:$c, updated:$now}')"
  printf '%s\n' "$card"
}

case "${1:-}" in
  record) shift; command_record "$@" ;;
  card) shift; command_card "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
