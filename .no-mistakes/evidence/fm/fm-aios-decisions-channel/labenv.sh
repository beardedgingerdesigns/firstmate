# Source me: runs worktree scripts against the disposable lab home only.
WT=/Users/justinlobaito/.no-mistakes/worktrees/d2386019607f/01M3WQGDGZ4H6BNA0TDBGZ9Q0E
EV=/Users/justinlobaito/.no-mistakes/evidence/01M3WQGDGZ4H6BNA0TDBGZ9Q0E
LAB=$(cat /tmp/fm-answer-drop-lab-path)
fm() {  # <script> <args...>
  (cd "$LAB" && env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$HOME/.nvm/versions/node/v24.14.1/bin:$PATH" TMUX_TMPDIR="$LAB/tmux" \
    FM_HOME="$LAB" FM_ANSWER_DROP_POLL_SECONDS=1 "$WT/bin/$@")
}
writer() { python3 "$EV/aios_ui_writer.py" "$LAB/state/home-summary.json" "$@"; }
dec() { jq -c --arg id "$1" '.decisions_open[] | select(.id == $id)' "$LAB/state/home-summary.json"; }
seen() { jq -c '.answers_seen' "$LAB/state/home-summary.json"; }
