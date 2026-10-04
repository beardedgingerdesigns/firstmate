#!/usr/bin/env bash
# Live drive: relaunch a real Claude worker on a task that already has an armed
# PR merge watch, then let the real watcher run that task's check.
#
# Real pieces: Herdr lab session (bin/fm-herdr-lab.sh), marked lab home
# (bin/fm-lab-home.sh), the machine's own `claude` login, gh reading a real
# public PR, bin/fm-spawn.sh, bin/fm-pr-check.sh, bin/fm-control.sh relaunch,
# bin/fm-watch.sh. Only the task's first record and endpoint are hand-provisioned,
# the same way tests/fm-control-herdr-smoke.test.sh does.
#
# Usage: live-drive.sh <product-root> <label> <trace: on|off>
set -u

GATE_ROOT=/Users/justinlobaito/.no-mistakes/worktrees/d2386019607f/01M43SNZP68TR050EE5X40A4N0
ROOT=$1
LABEL=$2
TRACE=$3
ID="rl-$LABEL"
# cli/cli#1 merged in 2019: a stable public PR (tests/fm-pr-state-live-e2e.test.sh uses it).
PR=https://github.com/cli/cli/pull/1

unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

say() { printf '\n=== %s ===\n' "$*"; }
show_meta() { sed 's/^/    /' "$LAB/state/$ID.meta"; }

SESSION=$("$GATE_ROOT/bin/fm-herdr-lab.sh" name "rl-$LABEL")
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
LAB=$(cd "$LAB" && pwd -P)
PROVISIONED=0
RESULT=fail

cleanup() {
  say "cleanup"
  if [ "$PROVISIONED" = 1 ]; then
    FM_HOME="$LAB" HERDR_SESSION="$SESSION" "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1 | tail -2
    "$GATE_ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" && echo "lab session $SESSION torn down; default-session tripwire unchanged"
  fi
  chmod -R u+w "$LAB" 2>/dev/null
  rm -rf "$LAB" "/tmp/fm-$ID" && echo "lab home removed"
  echo "RESULT[$LABEL]=$RESULT"
}
trap cleanup EXIT

say "product under test"
echo "root=$ROOT label=$LABEL trace=$TRACE"
echo "herdr=$(herdr --version 2>&1 | head -1) claude=$(claude --version 2>&1 | head -1)"

say "lab home + lab Herdr session"
"$GATE_ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
"$GATE_ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" || exit 1
PROVISIONED=1
echo "home=$LAB session=$SESSION"
export FM_HOME="$LAB" HERDR_SESSION="$SESSION"

PROJ="$LAB/projects/demo"
WT="$LAB/wt"
mkdir -p "$PROJ" "$LAB/data/$ID"
git -C "$PROJ" init -q
printf '# demo\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Lab' -c user.email='lab@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b "fm/$ID" "$WT"
cat > "$LAB/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Stand by. Reply with the single word READY and stop.

## Firstmate spec
Do not run commands, do not edit files, do not open a pull request. Reply READY and wait.
EOF

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || exit 1
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || { echo "container_ensure failed"; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "$SEEDED_TAB_ID") || { echo "create_task failed"; exit 1; }
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$LAB/state/$ID.meta"

if [ "$TRACE" = on ]; then
  say "trace context on for this home's session"
  touch "$LAB/config/trace-context"
  printf '%s\n' "$$" > "$LAB/state/.lock"
  # The same call bin/fm-session-start.sh makes.
  ( . "$ROOT/bin/fm-trace-context-lib.sh" && fm_trace_context_session_start "$LAB/config" "$LAB/state/.trace-context-effective" )
  echo ".trace-context-effective: $(cat "$LAB/state/.trace-context-effective")"
fi

wait_agent() {  # <want> <seconds>
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" != "$1" ] || return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

say "launch the first real Claude worker (fm-spawn.sh --relaunch into the agent-free pane)"
"$ROOT/bin/fm-spawn.sh" "$ID" --relaunch 2>&1 | tail -5
wait_agent alive 90 || { echo "worker never came alive"; exit 1; }
echo "agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")"
sleep 35
say "worker pane (first incarnation)"
"$ROOT/bin/fm-peek.sh" "$ID" 2>&1 | tail -15

say "arm the PR merge watch: fm-pr-check.sh $ID $PR"
"$ROOT/bin/fm-pr-check.sh" "$ID" "$PR" 2>&1 | tail -5
say "task record before relaunch"
show_meta

say "fm-control.sh $ID relaunch --note ..."
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note "live relaunch drive: keep standing by" 2>&1 | tail -8
echo "relaunch exit=${PIPESTATUS[0]}"
wait_agent alive 90 || echo "replacement worker not alive"
echo "agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")"
say "task record after relaunch"
show_meta
sleep 20
say "worker pane (replacement)"
"$ROOT/bin/fm-peek.sh" "$ID" 2>&1 | tail -12

say "watcher: run the real bin/fm-watch.sh until it reports on the check"
ls "$LAB/state" | grep -E "^$ID\." | sed 's/^/    /'
WATCH_OUT="$LAB/watch.out"
: > "$WATCH_OUT"
attempt=0
while [ "$attempt" -lt 4 ] && ! grep -q '^check: .*\(merged\|unauthenticated\)' "$WATCH_OUT"; do
  attempt=$((attempt + 1))
  rm -f "$LAB/state/.last-check"
  FM_POLL=2 FM_CHECK_INTERVAL=0 "$ROOT/bin/fm-watch.sh" >> "$WATCH_OUT" 2>&1 &
  wpid=$!
  i=0
  while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 45 ]; do sleep 1; i=$((i + 1)); done
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
done
echo "watcher output ($attempt run(s)):"
sed 's/^/    /' "$WATCH_OUT"
say "state after the watcher"
ls "$LAB/state" | grep -E "^$ID\." | sed 's/^/    /'

if grep -q '^check: rejected unauthenticated state checks' "$WATCH_OUT"; then
  RESULT="merge-watch-REFUSED-as-unauthenticated"
elif grep -q "^check: .*merged" "$WATCH_OUT"; then
  RESULT="merge-watch-ran-and-reported-merged"
else
  RESULT="inconclusive"
fi
