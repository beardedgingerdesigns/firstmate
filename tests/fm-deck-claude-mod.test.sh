#!/usr/bin/env bash
# Portable checks for the Claude Code fm-deck mod (.claude/mods/fm-deck) that need no
# Claude Code binary, so CI enforces them wherever Node runs:
#   - the plugin's declared shape: one hooks module and its state contract, reached from
#     the project's .claude/skills auto-load path through the tracked symlink, with no
#     command, skill, agent, or classic hook that could load while
#     CLAUDE_CODE_ENABLE_FUNCTION_HOOKS is off;
#   - the pure deck model: card grouping and lint, the question split, the drop-file
#     name and body the answer-drop adapter reads, the framed prompts, and the Deck line;
# The adapter accepting source fm-deck is covered by tests/fm-procevent-answer-drop.test.sh.
# The engine-bound behavior runs under tests/fm-deck-claude-mod-plugin.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MOD="$ROOT/.claude/mods/fm-deck"
TMP_ROOT=$(fm_test_tmproot fm-deck-claude-mod)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the fm-deck mod checks"; exit 0; }

run_node() {  # <script-file>
  node --input-type=module <"$1"
}

test_plugin_shape() {
  local link resolved autoload out
  link="$ROOT/.agents/skills/fm-deck"
  [ -L "$link" ] || fail "the fm-deck mod is not linked into .agents/skills, so Claude Code's project skills-dir scan cannot adopt it"
  resolved=$(cd "$link" && pwd -P) || fail "the .agents/skills/fm-deck link does not resolve"
  [ "$resolved" = "$(cd "$MOD" && pwd -P)" ] || fail "the .agents/skills/fm-deck link resolves to $resolved, not the mod"
  autoload="$ROOT/.claude/skills/fm-deck"
  [ -f "$autoload/.claude-plugin/plugin.json" ] || fail "the project's .claude/skills path does not reach the mod's manifest"
  [ ! -e "$MOD/SKILL.md" ] || fail "the mod carries a SKILL.md and would load as a skill on every harness"
  cat >"$TMP_ROOT/shape.mjs" <<JS
import { readFileSync, readdirSync } from "node:fs";
const mod = ${MOD@Q};
const manifest = JSON.parse(readFileSync(\`\${mod}/.claude-plugin/plugin.json\`, "utf8"));
if (manifest.name !== "fm-deck") throw new Error(\`manifest name \${manifest.name}\`);
for (const key of ["commands", "agents", "skills", "hooks", "mcpServers", "lspServers", "outputStyles"]) {
  if (key in manifest) throw new Error(\`manifest declares \${key}, which would load while the flag is off\`);
}
if (manifest.types !== "./types/index.d.ts") throw new Error("manifest does not name the state contract");
const hooks = JSON.parse(readFileSync(\`\${mod}/hooks/hooks.json\`, "utf8"));
if (JSON.stringify(Object.keys(hooks).sort()) !== JSON.stringify(["description", "modules"])) throw new Error("hooks.json declares more than its module");
if (JSON.stringify(hooks.modules) !== JSON.stringify(["./register.ts"])) throw new Error("hooks.json names a different module");
const entries = readdirSync(mod).filter((name) => name !== ".claude-plugin").sort();
if (JSON.stringify(entries) !== JSON.stringify(["hooks", "lib", "tests", "types"])) throw new Error(\`the mod folder holds \${entries.join(", ")}\`);
console.log("shape-ok");
JS
  out=$(run_node "$TMP_ROOT/shape.mjs" 2>&1) || fail "plugin shape: $out"
  assert_contains "$out" "shape-ok" "plugin shape check did not complete"
  pass "the fm-deck mod is one hooks module and its state contract, linked into the project's auto-load path, with nothing that loads past its opt-in"
}

test_model() {
  local out
  cat >"$TMP_ROOT/model.mjs" <<JS
import { pathToFileURL } from "node:url";
const m = await import(pathToFileURL(${MOD@Q} + "/lib/fm-deck-model.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const fp = (n) => String(n).repeat(64);
const decision = (id, question, options, extra = {}) => ({ id, project: id.split("-")[0], summary: id, question, fingerprint: fp(1), options, bucket: "live", ageDays: 1, ...extra });
const opts = [{ key: "a", label: "Alpha - recommended" }, { key: "b", label: "Beta" }];

// Grouping, live-only cards, recommendation, and the question split.
const cards = m.buildCards([
  decision("x-one", "Ship it? Recommended: yes. If nothing: it waits a week.", opts),
  decision("y-two", "Same question?", opts),
  decision("z-three", "Same question?", opts),
  decision("p-park", "Parked?", opts, { bucket: "dated" }),
  decision("q-bad", "Bad fingerprint?", opts, { fingerprint: "nope" }),
  decision("w-status", "", [], { fingerprint: "", bucket: "" }),
]);
check(cards.length === 2, \`\${cards.length} cards\`);
check(cards[0].short === "Ship it?" && cards[0].ifNothing === "it waits a week.", \`split: \${JSON.stringify(cards[0])}\`);
check(cards[0].recommended === "a" && m.cleanLabel("Alpha - recommended") === "Alpha", "recommended option not found");
check(JSON.stringify(cards[1].holds.map((h) => h.id)) === '["y-two","z-three"]', "identical questions not grouped");
check(cards[1].unclear.includes("same question on 2 items"), "grouped card not linted");
const mixed = m.buildCards([decision("y-two", "Q?", opts), decision("z-three", "Q?", [{ key: "c", label: "C" }])])[0];
check(mixed.options.length === 0 && mixed.unclear.includes("no options"), "a group with different option keys still offers keys");

// Lint: the AIOS lessons.
check(m.lintCard("Which?", [], 1).join() === "no options", "no options");
check(m.lintCard("x".repeat(301), opts, 1).includes("question too long"), "long question");
check(m.lintCard("See data/isf/report.md", opts, 1).includes("a file path is the only context"), "path-only question");
check(m.lintCard("Should the importer read data/isf/report.md before the nightly window closes?", opts, 1).length === 0, "a path with real context is fine");

// Drop file: exactly the adapter's contract.
check(m.dropFileName("tq-inside", 1790971987815.4) === "tq-inside-1790971987815.json", "drop name");
check(/^\.tq-inside\.fm-deck\.[A-Za-z0-9]+\.tmp$/.test(m.dropTempName("tq-inside", "ab-12")), "temp name is hidden and never a drop name");
let refused = false;
try { m.dropFileName("../evil", 1); } catch { refused = true; }
check(refused, "a hold id that escapes the folder is refused");
const body = JSON.parse(m.dropFileBody({ id: "tq-inside", fingerprint: fp(1) }, { option: "a" }, Date.parse("2026-10-02T20:10:00.123Z")));
check(JSON.stringify(body) === JSON.stringify({ hold_id: "tq-inside", question_fingerprint: fp(1), answer: { option: "a" }, answered_at: "2026-10-02T20:10:00Z", source: "fm-deck" }), \`body \${JSON.stringify(body)}\`);
check(m.inboxIsUsable("/h/state/answer-drop") && !m.inboxIsUsable("state/answer-drop") && !m.inboxIsUsable("/h/data") && !m.inboxIsUsable("/h/../answer-drop"), "inbox guard");

// Prompts never read as answers.
for (const kind of ["later", "explain", "not-mine", "rewrite", "chat"]) {
  const text = m.askPrompt(kind, cards[0], "2026-10-03");
  check(text.startsWith("From the decisions pane:") && /not an answer/.test(text) && text.includes("x-one"), \`\${kind} prompt: \${text}\`);
}

// Later dates (local): Friday 2026-10-02.
const later = m.laterDates(new Date(2026, 9, 2, 12).getTime());
check(JSON.stringify(later.map((d) => d.date)) === '["2026-10-03","2026-10-09","2026-10-05"]', \`later \${JSON.stringify(later)}\`);

// Status from the pane's records and answers_seen.
const sent = [{ hold: "x-one", fingerprint: fp(1), file: "x-one-1.json", label: "Alpha", at: 1 }];
const status = (seen) => m.cardStatus(cards[0], sent, [], seen, "s").text;
check(status([]) === "sent: Alpha", "sent");
check(status([{ file: "x-one-1.json", holdId: "x-one", status: "picked_up", reason: "" }]) === "picked up: Alpha", "picked up");
check(status([{ file: "x-one-1.json", holdId: "x-one", status: "resolved", reason: "" }]) === "done: Alpha", "done");
check(m.cardStatus(cards[0], sent, [], [{ file: "x-one-1.json", holdId: "x-one", status: "rejected", reason: "question-changed" }], "s").answered === false, "a rejected answer can be answered again");
check(m.cardStatus(cards[0], [{ ...sent[0], fingerprint: fp(2) }], [], [], "s").text === "", "a reworded hold forgets the old answer");

// Deck line and band.
const summary = { generatedAt: "", inbox: "", decisions: [], seen: [], prs: [{ task: "t", url: "https://github.com/a/b/pull/64", label: "PR #64" }], workers: 4, blockedWorkers: 1 };
const line = m.deckLine({ summary, calls: 3, helmOther: undefined, watchAgeMs: 1000, contextPercent: 41.2, rateLimits: [{ kind: "five_hour", percentUsed: 62 }] });
check(line === "⚓ firstmate · 3 calls · 1 PR ready · 4 workers (1 blocked) · watch ok · ctx 41% · 5h 62%", \`line \${line}\`);
check(m.deckLine({ summary: undefined, calls: 0, helmOther: undefined, watchAgeMs: undefined, contextPercent: undefined, rateLimits: [] }) === undefined, "no summary, no line");
check(m.deckLine({ summary: { ...summary, workers: 0 }, calls: 0, helmOther: undefined, watchAgeMs: undefined, contextPercent: undefined, rateLimits: [] }).includes("watch idle"), "idle watch");
check(m.bandParts(0, [], 0).length === 0, "empty band");
check(m.bandParts(1, summary.prs, 2).join(" · ") === "1 call waits on you · PR #64 ready · 2 notes from AIOS", "band text");

// The summary reader takes the real field names bin/fm-fleet-snapshot.sh publishes.
const parsed = m.parseSummary(JSON.stringify({
  generated_at: "2026-10-02T20:06:29Z", answers_inbox: "/h/state/answer-drop",
  decisions_open: [
    { id: "a-b", project: "p", question: "Q?", question_fingerprint: fp(1), options: [{ key: "k", label: "L" }], hold_bucket: "live", hold_age_days: 3 },
    { id: "w1", key: "d1", verb: "decide", summary: "worker status decision", reason: null, options: [], question: null, question_fingerprint: null, source: "status" },
  ],
  queued: [
    { id: "a-b", hold_bucket: "live" }, { id: "c-d", hold_bucket: "dated" }, { id: "e-f", hold_bucket: "aged" },
    { id: "g-h", hold_bucket: "blocked" }, { id: "i-j", hold_bucket: null },
  ],
  answers_seen: [{ file: "a-b-1.json", hold_id: "a-b", status: "resolved", reason: null }],
  contributions: { captain: [{ task: "a-b", url: "https://github.com/a/b/pull/7" }] },
  fleet: [{ state: "failed" }, { state: "working" }],
}));
check(parsed.decisions[0].fingerprint === fp(1) && parsed.decisions[0].ageDays === 3, "decision fields");
check(parsed.parked === 3, \`parked counted \${parsed.parked} from queued\`);
check(m.buildCards(parsed.decisions).length === 1, "a worker status decision became a card");
check(parsed.seen[0].status === "resolved" && parsed.prs[0].label === "PR #7" && parsed.blockedWorkers === 1, "summary fields");
check(m.parseSummary("not json") === undefined && m.parseSummary("{}") === undefined, "non-summary text");
console.log("model-ok");
JS
  out=$(run_node "$TMP_ROOT/model.mjs" 2>&1) || fail "deck model: $out"
  assert_contains "$out" "model-ok" "deck model check did not complete"
  pass "the deck model groups, parks, and lints cards, writes the adapter's exact drop file, frames non-answers as prompts, and builds the Deck line"
}

test_plugin_shape
test_model
