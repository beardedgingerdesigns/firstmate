# fm-deck: Captain's Call and the Deck line

fm-deck is a Claude Code mod for a firstmate session.
It adds Captain's Call, a pane for answering pending captain decisions one card at a time, and the Deck line, a status line and band that show what waits on the captain.
This page is for operators who turn it on and need to know what it shows, what each key does, and how an answer reaches firstmate.

## Enabling it

fm-deck lives in `.claude/mods/fm-deck`.
The trusted project auto-loads it through `.claude/skills/fm-deck`, a symlink into `.claude/mods`, the same way [`firstmate-calm`](calm.md#the-firstmate-calm-mod) loads.

Claude Code's function-hooks surface is early access and off by default.
fm-deck does nothing unless `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` equals `1`, even if Claude Code's rollout flag loads the module.
Firstmate never sets that variable; enabling it is each captain's own opt-in, as for Calm.

It also draws nothing until the home's `state/home-summary.json` exists, so a worker session in a project or a fresh copy of this repository stays unchanged.
The home is `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the repository the mod sits in.

## Captain's Call

`/calls` opens the pane with the keyboard.
fm-deck also opens it unasked when live calls first appear in a session; Claude Code seats an unasked pane only beside a fullscreen transcript at least 144 columns wide and otherwise waits.

The pane shows:

- A header with how many calls wait and how many are parked.
  Only holds whose `hold_bucket` is `live` become cards; waiting, deferred and other parked holds are only counted.
- A strip naming every live call, the current one filled.
- One card: the project and how long the call has been open, the question up to its "Recommended:" or "If nothing:" sentence, and the "If nothing:" line (or "No default recorded.").
- Holds whose question text is identical become one card that lists every project it covers; answering it answers each of those holds.
- The card's status: sending, sent, picked up, done, not taken (with firstmate's reason), or asked firstmate.
- A footer with the card position, when the list was generated, and "(may be out of date)" once it is more than ten minutes old.
- A "Ready for you" row for the first pull request that waits only on the captain.

### Keys

| Key | Action |
| --- | --- |
| `1`-`4` | Pick that option. |
| `r` | Pick the option firstmate marked recommended (its label ends in "- recommended"). |
| `u` | Undo a pick within five seconds; nothing is sent. |
| `l` | Later: then `1` tomorrow, `2` next week, `3` next Monday, `b` back. |
| `e` | Ask firstmate to explain the call in chat. |
| `x` | Tell firstmate the call is not the captain's or is already done. |
| `t` | Type a free answer and press Enter. On the mobile app, which has no text field, `t` asks firstmate to take the answer in chat instead. |
| `f` | Ask firstmate to rewrite an unclear card. |
| `m` | Show the full question, or go back to the short form. |
| `s` | Resend an earlier session's request that firstmate has not acted on yet. |
| `n` / `p` | Next or previous card. |
| `o` / `c` | Open the ready pull request, or copy its link. |
| `Esc` | Close the pane. |

A card is marked unclear when it has no options, more than four options, a question over 300 characters, a file path as its only context, or the same question as other holds.
An unclear card with no options shows no number keys.

### How an answer reaches firstmate

An option or typed answer is the only thing fm-deck writes.
Five seconds after the pick (the undo window), it writes one JSON file per hold to a hidden temp name inside the `answers_inbox` folder the summary publishes, hard-links it to `<hold_id>-<epoch-ms>.json` without overwriting anything, and removes the temp name.
The file carries `"source": "fm-deck"`; [`bin/fm-procevent-answer-drop.sh`](../bin/fm-procevent-answer-drop.sh) owns the file contract, validates the answer against the hold as currently worded, feeds firstmate's keyed answer intake, and wakes firstmate.
The first answer wins across chat, AIOS and the pane; a late one comes back as not taken.
fm-deck writes nowhere unless `answers_inbox` is an absolute path ending in `answer-drop`.

Later, explain, not-mine, rewrite, and answer-in-chat never touch the answer intake.
Each goes to firstmate as one prompt beginning "From the decisions pane:", which Claude Code queues until the session is idle, so it never cuts into a running turn.
Firstmate handles it under its own captain-hold rules.

The pane keeps its own record of what it sent and asked, so a `/clear` or restart keeps those statuses.
A request queued in a session that ended before firstmate read it shows "asked firstmate in an earlier session" with `s` to resend.

## Deck line

With a summary present, fm-deck pins one status line, for example:

`⚓ firstmate · 3 calls · 1 PR ready · 4 workers (1 blocked) · watch ok · ctx 41% · 5h 62%`

- Calls count the live cards.
- Workers and the blocked count (blocked or failed) come from the summary's `fleet`.
- `watch ok` means `state/.last-watcher-beat` changed in the last five minutes; otherwise it reads `watch down Nm` while workers exist, or `watch idle` when none do.
- Context and rate-limit percentages are the session's own usage.
- When `state/.lock-session` names another session, the counts give way to `helm: another session (<id>…)`.

The footer's mode list gains a `firstmate` label, so the window names itself.

A band above the prompt appears only when something waits on the captain: calls, a ready pull request, or notes in `state/inbox/`.
Its `d` key opens Captain's Call and `o` opens the pull request; it gives way to any survey.

## What it reads and never does

fm-deck polls every three seconds and reads only `state/home-summary.json`, `state/.lock-session`, `state/.last-watcher-beat`, the names in `state/inbox/`, and the session's usage.
It never runs a `bin/fm-*` script, never merges, never closes or answers a call itself, never speaks as the captain, and never answers a permission check.
Display changes leave what the model reads and what the transcript stores untouched.

## Limits

- Firstmate has no hold field for "irreversible" yet, so the pane cannot hold such calls to chat-only answers; firstmate's own refusal of board answers for irreversible actions still applies.
- The recommended option and the if-nothing line are read from the label suffix and the question text until holds carry them as fields.
- The summary lists at most 20 open decisions.
- The engine verified here is Claude Code 2.1.288; the function-hooks API may change between releases.

## Tests

- `tests/fm-deck-claude-mod.test.sh` checks the plugin's shape and the pure model under Node.
- `tests/fm-deck-claude-mod-plugin.test.sh` runs `claude plugin validate --strict` and the mod's own `claude plugin test` suite under the installed Claude Code.
- `tests/fm-procevent-answer-drop.test.sh` covers the adapter accepting `fm-deck` answers.
