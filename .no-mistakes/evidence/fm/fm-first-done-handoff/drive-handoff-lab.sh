#!/usr/bin/env bash
# Drives real headless Claude engine turns via bin/fm-supervision-host.sh in lab
# homes. usage: drive-handoff-lab.sh <away|attended|control>
set -u
EV=/Users/justinlobaito/.no-mistakes/evidence/01M66HEFY91MNF7C57D5CYHC48
. "$EV/lab-env.sh"
POSTURE=$1
REF=HEAD; [ "$POSTURE" = control ] && REF=97459e1618db38abd2d5b0e0e66ebefe9ceb37e2
H=$LAB/$POSTURE; OUT=$EV/$POSTURE; mkdir -p "$OUT"
export HERDR_SESSION=$SESSION NM_HOME=$LAB/nm-$POSTURE
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=${LAB_HEARTBEAT:-999999}
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$OUT/transcript.txt"; }
mklab "$H" "$REF" || { log "mklab failed"; exit 1; }

# no-mistakes passes through to the real CLI, except for the one project whose
# pipeline state is a recorded fixture (a real run is outside this phase).
mkdir -p "$LAB/bin-$POSTURE" "$LAB/harness-$POSTURE"
REAL_NM=$(command -v no-mistakes)
cat > "$LAB/bin-$POSTURE/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$(git rev-parse --show-toplevel 2>/dev/null)" = "$LAB/$POSTURE-p-run" ]; then
  case "\$1:\${2:-}" in
    axi:|axi:status) printf 'run:\n  id: "01RUNFIXTURE"\n  branch: fm/gerrit\n  status: completed\n  head: "%s"\n  pr: ""\n  findings: none\noutcome: passed-with-skips\nautomatic_skips: "publication skipped: no-mistakes.yaml pr.enabled=false"\n' "\$(git rev-parse HEAD)" ;;
    runs:*) : ;;
    *) : ;;
  esac
  exit 0
fi
exec "$REAL_NM" "\$@"
SH
chmod +x "$LAB/bin-$POSTURE/no-mistakes"
ln -sf /bin/bash "$LAB/harness-$POSTURE/claude"

[ "$POSTURE" = attended ] || FM_HOME="$H" "$H/bin/fm-afk-contract.sh" enter --words 'Going out for the evening. Keep the fleet healthy. Merge nothing.' >/dev/null

# The lock holder re-parks whenever the host hands a wake back, as an arm owner does.
printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p0","prompt":"watch the fleet for me"}' > "$OUT/mirror-seed"
PATH="$LAB/bin-$POSTURE:$PATH" FM_HOME="$H" FM_SUPERVISION_HOST_PRIMARY=claude "$LAB/harness-$POSTURE/claude" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  "$FM_HOME/bin/fm-host-mirror.sh" hook claude < "$1/mirror-seed"
  while [ ! -e "$1/stop" ]; do
    "$FM_HOME/bin/fm-supervision-host.sh" park >> "$1/host.out" 2>&1
    printf "park exited %s\n" "$?" >> "$1/host.out"
    sleep 3
  done
' _ "$OUT" 2>> "$OUT/harness.err" &
for _ in $(seq 1 300); do p=$(cat "$H/state/.watch.lock/pid" 2>/dev/null) && kill -0 "$p" 2>/dev/null && break; sleep 0.2; done
log "host parked, watcher pid ${p:-none}"
export PATH="$LAB/bin-$POSTURE:$PATH"
TASKS=

fire() { # <task> <mode> <kind> <status line> [project]
  local t=$1 mode=$2 kind=$3 line=$4 p=${5:-$LAB/$POSTURE-p-$1} pane i
  TASKS="$TASKS $t"
  [ -d "$p" ] || mkproj "$p" "fm/$t"
  (cd "$p" && no-mistakes axi status >/dev/null 2>&1)
  pane=$(newworker "$POSTURE-$t")
  for i in $(seq 1 60); do [ "$("$HELPER" run "$SESSION" agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" = idle ] && break; sleep 1; done
  meta "$H" "$t" "$p" "$(git -C "$p" symbolic-ref --short HEAD)" "$mode" "$kind" "$pane"
  idle "$H" "$t"
  printf '%s [at=%s]: %s\n' "${line%%:*}" "$(date +%s)" "${line#*: }" >> "$H/state/$t.status"
  log "== $t pane=$pane mode=${mode:-none} kind=$kind status: $line"
  log "crew-state: $(FM_HOME="$H" "$H/bin/fm-crew-state.sh" "$t")"
  for i in $(seq 1 420); do jq -e --arg t "$t" 'select(.task==$t)' "$H/state/branch-outcomes.jsonl" >/dev/null 2>&1 && break; sleep 1; done
  log "outcome row after ${i}s"
  dump "$t"
}
dump() { # <task>
  log "inbox $1: $(find "$H/state/$1.inbox" -type f 2>/dev/null | wc -l | tr -d ' ') record(s)"
  find "$H/state/$1.inbox" -type f 2>/dev/null | while read -r f; do tr '\n' ' ' < "$f" | tee -a "$OUT/transcript.txt"; echo | tee -a "$OUT/transcript.txt"; done
  jq -c --arg t "$1" 'select(.task==$t) | {task,verdict,silent,summary}' "$H/state/branch-outcomes.jsonl" 2>/dev/null | tee -a "$OUT/transcript.txt"
}

case "$POSTURE" in
  attended)
    fire isf-attended no-mistakes ship 'done: built the attended ticket and committed it on fm/isf-attended'
    fire direct-attended direct-PR ship 'done: built the direct ticket and committed it on fm/direct-attended' ;;
  away)
    fire isf-ticket no-mistakes ship 'done: built the ISF ticket and committed it on fm/isf-ticket'
    fire direct-ship direct-PR ship 'done: built the direct ticket and committed it on fm/direct-ship'
    fire old-ship '' ship 'done: built the legacy ticket and committed it on fm/old-ship'
    fire ready-ship no-mistakes ship 'done: PR https://github.com/fm-lab-nonexistent/demo/pull/1 checks green'
    fire scout-task '' scout 'done: findings written to the report'
    mkproj "$LAB/$POSTURE-p-run" fm/gerrit
    fire run no-mistakes ship 'done: built the gerrit ticket and committed it on fm/gerrit' "$LAB/$POSTURE-p-run"
    ;;
esac
# Keep the host parked so a later wake (heartbeat or stale row) sees the steered handoff.
log "waiting ${LAB_LINGER:-0}s for later wakes"; sleep "${LAB_LINGER:-0}"
log "== final state"; for t in $TASKS; do dump "$t"; done
log "worker panes:"; for t in $TASKS; do pane=$(sed -n "s/^window=$SESSION://p" "$H/state/$t.meta"); log "[$t] $("$HELPER" run "$SESSION" pane read "$pane" --source recent 2>/dev/null | grep -iE 'inbox|steer|doorbell' | head -2 | cut -c1-160)"; done
touch "$OUT/stop"
pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$H/state/.supervision-host" 2>/dev/null); [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null
sleep 6
p=$(cat "$H/state/.watch.lock/pid" 2>/dev/null); [ -z "$p" ] || kill -TERM "$p" 2>/dev/null
cp "$H/state/.supervision-host.log" "$OUT/host.log" 2>/dev/null; cp "$H/state/branch-outcomes.jsonl" "$OUT/outcomes.jsonl" 2>/dev/null; cp "$H/state/.wake-queue" "$OUT/wake-queue-final" 2>/dev/null
log finished
