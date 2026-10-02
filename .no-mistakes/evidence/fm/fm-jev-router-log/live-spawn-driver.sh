#!/usr/bin/env bash
# Live driver: real resolver (live Typesafe) + real fm-spawn.sh on a Herdr fm-lab-* session.
set -u
ROOT=$1 E=$2
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name jevlog)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
KEYVAL=$(grep '^TYPESAFE_API_KEY=' "$HOME/repos/firstmate/.env" | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
cleanup() {
  for id in lab-jev-a1 lab-jev-b2; do
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" HERDR_SESSION="$SESSION" "$ROOT/bin/fm-teardown.sh" "$id" --force >/dev/null 2>&1 || true
  done
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION"; echo "lab teardown exit=$?"
  rm -rf "$LAB"; echo "lab home removed: $([ -e "$LAB" ] && echo no || echo yes)"
}
trap cleanup EXIT
"$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" >/dev/null || { echo "provision failed"; exit 1; }
echo "session=$SESSION lab=$LAB"
cp "$HOME/repos/firstmate/config/crew-dispatch.json" "$LAB/config/"
mkdir -p "$LAB/shim"
printf '{"generatedAt":"2026-10-02T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":79,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.5}}]}}]}\n' > "$LAB/shim/quota.json"
printf '#!/bin/sh\ncat "%s"\n' "$LAB/shim/quota.json" > "$LAB/shim/quota-axi"; chmod +x "$LAB/shim/quota-axi"
P="$LAB/projects/demo"; mkdir -p "$P"; git -C "$P" init -q; echo demo > "$P/README.md"; git -C "$P" add README.md
git -C "$P" -c user.name=lab -c user.email=lab@example.invalid commit -qm init; git clone -q --bare "$P" "$P.origin.git"; git -C "$P" remote add origin "file://$P.origin.git"
brief() { mkdir -p "$LAB/data/$1"; printf '# Task\n## Captain%ss intent\nFix the off-by-one in the demo pager so the last page is kept. One file, unit test exists.\n\n## Firstmate spec\nWell-specified implementation with clear acceptance criteria and a bounded file set.\n' "'" > "$LAB/data/$1/brief.md"; }
X() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TYPESAFE_API_KEY FM_HOME="$LAB" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 "$@"; }
LOG="$LAB/state/dispatch-resolve.log"

echo; echo "## A. spawn with no decision log present"
brief lab-jev-a1
X "$ROOT/bin/fm-spawn.sh" lab-jev-a1 "$P" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr 2>&1 | tail -1; echo "spawn exit=${PIPESTATUS[0]}"
echo "decision log exists after spawn: $([ -e "$LOG" ] && echo yes || echo no)"

echo; echo "## B. live resolve, then spawn the resolved profile"
brief lab-jev-b2
X TYPESAFE_API_KEY="$KEYVAL" PATH="$LAB/shim:$PATH" "$ROOT/bin/fm-dispatch-resolve.sh" "$LAB/data/lab-jev-b2/brief.md" --project demo; echo "resolve exit=$?"
X "$ROOT/bin/fm-spawn.sh" lab-jev-b2 "$P" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr 2>&1 | tail -1; echo "spawn exit=${PIPESTATUS[0]}"
echo; echo "## state/dispatch-resolve.log"; cat "$LOG"
echo "key occurrences: $(grep -c -F "$KEYVAL" "$LOG")  brief-text occurrences: $(grep -ciE 'off-by-one|pager so' "$LOG")"
