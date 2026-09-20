#!/usr/bin/env bash
# Live Kimi startup-submit guard (live-harness-optin family).
#
# Kimi's startup delivery rests on two things only a real pane can prove: that
# the shared composer classifier can read Kimi's composer through the status
# footer it draws below the box, and that the brief pointer actually starts a
# turn rather than sitting in the composer unsubmitted. Kimi 2.0.1 regressed
# both at once - the footer made every cursorless composer read read `unknown`,
# and an Enter sent with no gap after the literal pointer was swallowed - which
# left every spawn wedged with its pointer typed but never sent. A stub cannot
# prove either signal, because a stub only replays the assumption written into
# it.
#
# Run explicitly with FM_KIMI_STARTUP_SUBMIT_LIVE=1 after a Kimi or Herdr
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Kimi startup submit" entry. It fails naming the harness and version rather
# than degrading quietly.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_KIMI_STARTUP_SUBMIT_LIVE herdr jq kimi

[ -x "$LAB_HELPER" ] || fail "FM_KIMI_STARTUP_SUBMIT_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name kimi-startup-submit-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-kimi-startup-submit-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
KIMI_BIN=$(PATH="$ORIGINAL_PATH" command -v kimi) \
  || fail "FM_KIMI_STARTUP_SUBMIT_LIVE=1 but no kimi executable is on PATH"
VERSION=$(PATH="$ORIGINAL_PATH" kimi --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# A fresh repository so the pane is a realistic task worktree.
WORKDIR="$TMP_ROOT/wt"
mkdir -p "$WORKDIR"
( cd "$WORKDIR" && git init -q . && git -c user.email=t@e -c user.name=t commit -q --allow-empty -m init ) \
  || fail "could not initialise the scratch worktree"
BRIEF="$WORKDIR/brief.md"
TOKEN="FMKIMIPONG$$_$RANDOM"
printf 'Reply with exactly %s and nothing else.\n' "$TOKEN" > "$BRIEF"

WS_JSON=$(lab workspace create --cwd "$WORKDIR" --label fm-kimilive --no-focus) \
  || fail "could not create the isolated Kimi workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"

lab pane run "$PANE" "$(printf '%q' "$KIMI_BIN") --auto" >/dev/null \
  || fail "could not launch Kimi ($VERSION) in the isolated Herdr pane"

# 1. The composer must become READABLE. `unknown` in every state is exactly the
#    2.0.1 regression: it silently disables the Enter retry budget and delivery
#    confirmation alike, so an unreadable composer is a failure, not a wait.
# A fresh folder gates Kimi behind its trust dialog. Clearing it is lab setup,
# not the behavior under test: bin/fm-spawn.sh owns the real dialog contract,
# so this guard only nudges an obviously-present dialog out of the way rather
# than keeping a second copy of that contract.
state=''
i=0
while [ "$i" -lt 60 ]; do
  state=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$state" = empty ] && break
  if fm_backend_herdr_visible_capture "$TARGET" 2>/dev/null | grep -Fq 'Trust this folder?'; then
    fm_backend_herdr_send_key "$TARGET" Enter || true
  fi
  i=$((i + 1))
  sleep 0.5
done
[ "$state" = empty ] \
  || fail "Kimi ($VERSION) on $HERDR_VER: an idle startup composer must read empty, got '$state' (the status footer below the box is not being read as furniture)"

# 2. The typed-but-unsubmitted pointer must be PROVABLE as pending. This is the
#    state the spawn watchdog keys on; without it the watchdog cannot tell a
#    wedged pane from one that is merely still starting up.
POINTER="Read the brief at $BRIEF and follow it exactly."
fm_backend_herdr_send_literal "$TARGET" "$POINTER" \
  || fail "Kimi ($VERSION) on $HERDR_VER: could not type the brief pointer into the pane"
state=''
i=0
while [ "$i" -lt 20 ]; do
  state=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$state" = pending ] && break
  i=$((i + 1))
  sleep 0.5
done
[ "$state" = pending ] \
  || fail "Kimi ($VERSION) on $HERDR_VER: a typed, unsubmitted brief pointer must read pending, got '$state'"

# 3. The submit must actually START A TURN. A cleared composer alone is not
#    proof, so the requested reply is what closes this guard.
fm_backend_herdr_send_key "$TARGET" Enter \
  || fail "Kimi ($VERSION) on $HERDR_VER: could not send the submit keystroke"
CHECKED=1

landed=0
i=0
while [ "$i" -lt 90 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  if printf '%s\n' "$screen" | grep -Fq "$TOKEN"; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Kimi ($VERSION) on $HERDR_VER: the submitted brief pointer never started a turn that reached the brief"
pass "live Kimi startup submit: Kimi ($VERSION) on $HERDR_VER reads empty idle, proves a pending unsubmitted pointer, and starts the brief in isolated session $SESSION"

[ "$CHECKED" -gt 0 ] || fail "FM_KIMI_STARTUP_SUBMIT_LIVE=1 checked no harness"
