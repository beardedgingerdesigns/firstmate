#!/usr/bin/env bash
# The Claude Code fm-deck mod (.claude/mods/fm-deck) under the real installed Claude
# Code: `claude plugin validate --strict` on the physical folder and on the
# `.claude/skills/fm-deck` path the project auto-loads it from, then its own
# `claude plugin test` suite (tests/*.test.ts inside the mod), which runs the hooks
# module in the engine's own host against a mocked clock, environment, store, file
# system, host commands, and drawing surface. No model turn is submitted and no
# credential is spent, so the guard runs by default wherever `claude` is installed;
# the portable checks that need no Claude Code binary live in
# tests/fm-deck-claude-mod.test.sh.
#
# The early-access function-hooks surface is default-off; the flag is set on this
# test's own processes only and never written into any settings file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_DECK_PLUGIN_TEST claude

MOD="$ROOT/.claude/mods/fm-deck"
AUTOLOAD_PATH="$ROOT/.claude/skills/fm-deck"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
TMP_ROOT=$(fm_test_tmproot fm-deck-claude-mod-plugin)

expect_in_report() {
  local report=$1 needle=$2 what=$3
  case "$report" in
    *"$needle"*) : ;;
    *)
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION: $what (missing '$needle')"
      ;;
  esac
}

test_validate_strict() {
  local path report
  for path in "$MOD" "$AUTOLOAD_PATH"; do
    if ! report=$(CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin validate --strict "$path" 2>&1); then
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION refused the fm-deck mod at $path under strict validation"
    fi
    # The scan is the engine's own reading of the module: the events it hooks, the
    # environment it reads, and the state it keeps. Anything more or less is a drift.
    expect_in_report "$report" "command.run{command=calls}" "the scan of $path does not serve /calls"
    expect_in_report "$report" "ui.render{component=Pane, requestId=calls}" "the scan of $path does not draw the Captain's Call pane"
    expect_in_report "$report" "ui.render{component=AbovePrompt}" "the scan of $path does not draw the band"
    expect_in_report "$report" "ui.render{component=SessionMode}" "the scan of $path does not label the footer"
    expect_in_report "$report" "env reads: CLAUDE_CODE_ENABLE_FUNCTION_HOOKS, FM_HOME, FM_ROOT_OVERRIDE" "the scan of $path reads a different environment"
    expect_in_report "$report" "env writes: nothing" "the scan of $path writes the environment"
    expect_in_report "$report" "state writes: fm-deck.view" "the scan of $path keeps different state"
    # The deck never speaks as the captain, answers a tool check, fetches, or rewrites rows.
    case "$report" in
      *"http.fetch"*|*"env.set"*|*"tool.call"*|*"tool.check"*|*"session.append"*|*"prompt.fill"*)
        printf '%s\n' "$report" >&2
        fail "Claude Code $CLAUDE_VERSION scanned a capability the fm-deck mod must not use at $path"
        ;;
    esac
  done
  pass "Claude Code $CLAUDE_VERSION validates the fm-deck mod strictly at its folder and its auto-load path, hooking exactly /calls, the pane, the band, and the footer label"
}

test_plugin_suites() {
  local report
  if ! report=$(cd "$TMP_ROOT" && CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION failed the fm-deck mod's plugin test suite"
  fi
  printf '%s\n' "$report" | grep -Eq '^ *[1-9][0-9]* pass$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION ran no fm-deck mod plugin test"
  }
  printf '%s\n' "$report" | grep -Eq '^ *0 fail$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION reported fm-deck mod plugin test failures"
  }
  pass "Claude Code $CLAUDE_VERSION runs the fm-deck mod's plugin test suite clean: opt-in gate, Deck line and band, cards, drop-file publish, undo, framed prompts, and read-back status"
}

test_validate_strict
test_plugin_suites
