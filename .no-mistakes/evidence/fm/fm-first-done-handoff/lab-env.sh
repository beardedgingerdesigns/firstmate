# Sourced setup for the first-done handoff live lab. Records nothing outside the lab.
EV=/Users/justinlobaito/.no-mistakes/evidence/01M66HEFY91MNF7C57D5CYHC48
SRC=/Users/justinlobaito/.no-mistakes/worktrees/d2386019607f/01M66HEFY91MNF7C57D5CYHC48
LAB=$(cat "$EV/.lab-root" 2>/dev/null)
SESSION=$(cat "$EV/.lab-session" 2>/dev/null)
HELPER=$SRC/bin/fm-herdr-lab.sh
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE PI_CODING_AGENT
for n in $(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_PID|CLAUDE_EFFORT)=' | cut -d= -f1); do unset "$n"; done
FM=$LAB/fm
mklab() { # <home> <git-ref>
  local home=$1 ref=$2
  "$SRC/bin/fm-lab-home.sh" create "$home" >/dev/null || return 1
  git -C "$SRC" archive "$ref" | tar -xf - -C "$home"
  git -C "$home" init -q -b main; git -C "$home" add -A >/dev/null
  git -C "$home" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  : > "$home/config/supervision-host"; printf 'herdr\n' > "$home/config/backend"
}
mkproj() { # <path> <branch>: a real project whose committed build is pushed to its bare origin
  local p=$1 b=$2
  git init -q -b main "$p"; git -C "$p" -c user.name=w -c user.email=w@e.invalid commit -q --allow-empty -m base
  git init -q --bare "$p.origin"; git -C "$p" remote add origin "$p.origin"; git -C "$p" push -q origin main
  git -C "$p" checkout -q -b "$b"; printf 'built\n' > "$p/feature.txt"; git -C "$p" add -A
  git -C "$p" -c user.name=w -c user.email=w@e.invalid commit -q -m 'build the feature'
  git -C "$p" push -q -u origin "$b"
}
newworker() { # <label>: prints the pane of a new real inert Claude worker
  local pane
  pane=$("$HELPER" run "$SESSION" workspace create --cwd "$LAB" --label "$1" --no-focus | jq -r .result.root_pane.pane_id)
  "$HELPER" run "$SESSION" pane run "$pane" "cd $HOME/repos && exec claude --safe-mode --tools '' --model haiku --append-system-prompt 'You are an inert test fixture in a lab. Reply only with the word ack to anything.'" >/dev/null
  printf '%s\n' "$pane"
}
meta() { # <home> <task> <project> <branch> <mode-or-empty> <kind> <pane>
  { echo "window=$SESSION:$7"; echo "endpoint_task_id=$2"; echo "worktree=$3"; echo "project=$3"
    echo harness=claude; echo "kind=$6"; [ -z "$5" ] || echo "mode=$5"; echo "branch=$4"; echo backend=herdr; echo "herdr_session=$SESSION"; } > "$1/state/$2.meta"
}
idle() { # <home> <task>: the idle lifecycle record a spawned Claude worker's hook keeps
  local g; g=$("$1/bin/fm-busy-event.sh" arm "$1/state" "$2"); "$1/bin/fm-busy-event.sh" apply "$1/state" "$2" idle --gen "$g" --source claude-hook --event stop >/dev/null
}
