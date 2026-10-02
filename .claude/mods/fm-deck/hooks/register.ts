// fm-deck for Claude Code: the Captain's Call decisions pane and the Deck line.
//
// Like firstmate-calm, Claude Code may load this module through its rollout flag or
// `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS`, but every handler requires that variable to equal
// `1`, and the mod draws nothing until the home's state/home-summary.json exists, so a
// worker session in a project or a bare worktree stays a complete no-op.
// docs/fm-deck.md owns the captain-facing contract; ../lib/fm-deck-model.ts owns every
// decision this file applies through `$`.
//
// It only reads firstmate state, with one exception: an option or typed answer is
// published as one drop file in the summary's answers_inbox (hidden temp file, then a
// no-clobber hard link), which firstmate's bin/fm-procevent-answer-drop.sh validates and
// feeds to the keyed intake. Later, explain, not-mine, rewrite, and answer-in-chat go to
// firstmate as framed `$.prompt.submit` prompts, never through the answer intake. It
// never runs a bin/fm-* script, never merges, and never closes a call.
import { atom, read, update } from "claude-code";
import type { EngineInterface, Register, RenderElement, RenderInput } from "claude-code";
import type { DeckAsk, DeckCard, DeckSent, DeckSummary, DeckView } from "../types/index.d.ts";
import {
  STALE_SUMMARY_MS,
  UNDO_MS,
  ageLabel,
  askPrompt,
  bandParts,
  buildCards,
  cardStatus,
  cleanLabel,
  deckHome,
  deckLine,
  dropFileBody,
  dropFileName,
  dropTempName,
  inboxIsUsable,
  laterDates,
  parseSummary,
} from "../lib/fm-deck-model.ts";

const PANE = "calls";
const COMMAND = "calls";
const POLL_MS = 3000;
const STORE_SENT = "sent";
const STORE_ASKS = "asks";
const KEEP_MS = 14 * 24 * 60 * 60 * 1000;

const view = atom({ plugin: "fm-deck", key: "view" } as const, {
  summary: null,
  index: 0,
  mode: "card",
  pending: null,
  sent: [],
  asks: [],
  notes: 0,
  helmOther: null,
  session: "",
} as DeckView);

// Module state that no drawing reads; a hot reload starts it over.
let activation: Promise<boolean> | undefined;
let home = "";
let summaryMtime = -1;
let lastLine: string | undefined;
let openedUnasked = false;
let poller: { cancel(): void } | undefined;
let pending: { timer: { cancel(): void }; publish: () => Promise<void> } | undefined;

function isActivated($: EngineInterface): Promise<boolean> {
  if (activation === undefined) {
    activation = $.env.get("CLAUDE_CODE_ENABLE_FUNCTION_HOOKS").then(
      (value) => value === "1",
      () => false,
    );
  }
  return activation;
}

async function readText($: EngineInterface, path: string): Promise<string | undefined> {
  try {
    return await $.fs.read(path);
  } catch {
    return undefined;
  }
}

async function mtime($: EngineInterface, path: string): Promise<number | undefined> {
  try {
    return (await $.fs.stat(path)).mtimeMs;
  } catch {
    return undefined;
  }
}

async function loadRecords<T extends { at: number }>($: EngineInterface, key: string, now: number): Promise<T[]> {
  try {
    const value = await $.store.get(key);
    return Array.isArray(value) ? (value as T[]).filter((r) => now - r.at < KEEP_MS) : [];
  } catch {
    return [];
  }
}

/** One poll: re-read what changed, redraw readers, and refresh the status line. */
async function poll($: EngineInterface): Promise<void> {
  const state = `${home}/state`;
  let current = await read($, view);
  // A /clear puts the view back at its initial with no session.start: restore it.
  if (current.session === "") {
    await restore($);
    current = await read($, view);
  }
  let summary: DeckSummary | null = current.summary;
  const changed = await mtime($, `${state}/home-summary.json`);
  if (changed === undefined) {
    summary = null;
    summaryMtime = -1;
  } else if (changed !== summaryMtime) {
    summaryMtime = changed;
    summary = parseSummary(await readText($, `${state}/home-summary.json`)) ?? null;
  }
  let notes = 0;
  try {
    notes = (await $.fs.list(`${state}/inbox`)).filter((f) => f.name.endsWith(".note")).length;
  } catch {
    notes = 0;
  }
  const holder = (await readText($, `${state}/.lock-session`))?.trim() ?? "";
  const helmOther = holder !== "" && current.session !== "" && holder !== current.session ? holder : null;
  if (
    JSON.stringify(summary) !== JSON.stringify(current.summary) ||
    notes !== current.notes ||
    helmOther !== current.helmOther
  ) {
    await update($, view, (v): DeckView => ({ ...v, summary, notes, helmOther }));
  }
  const calls = summary === null ? 0 : buildCards(summary.decisions).length;
  const now = await $.clock.now();
  const beat = await mtime($, `${state}/.last-watcher-beat`);
  let usage: Awaited<ReturnType<EngineInterface["session"]["usage"]>> | undefined;
  try {
    usage = await $.session.usage();
  } catch {
    usage = undefined;
  }
  const line = deckLine({
    summary: summary ?? undefined,
    calls,
    helmOther: helmOther ?? undefined,
    watchAgeMs: beat === undefined ? undefined : Math.max(0, now - beat),
    contextPercent: usage?.context.percent,
    rateLimits: usage?.rateLimits ?? [],
  });
  if (line !== lastLine) {
    lastLine = line;
    $.ui.status(line);
  }
  // Open the pane unasked once per session when live calls appear; the engine seats an
  // unasked pane only where it can dock beside the transcript and otherwise waits.
  if (calls > 0 && !openedUnasked) {
    openedUnasked = true;
    void $.ui.open({ id: PANE, title: "Captain's Call" });
  }
}

/** Send any pending pick, then reload the view's session and records and re-read the summary. */
async function restore($: EngineInterface): Promise<void> {
  summaryMtime = -1;
  lastLine = undefined;
  await flush($);
  const now = await $.clock.now();
  const session = await $.session.id().catch(() => "");
  const sent = await loadRecords<DeckSent>($, STORE_SENT, now);
  const asks = await loadRecords<DeckAsk>($, STORE_ASKS, now);
  await update($, view, (v): DeckView => ({ ...v, session, sent, asks, pending: null, mode: "card" }));
}

async function start($: EngineInterface): Promise<void> {
  home = deckHome(
    { FM_HOME: await $.env.get("FM_HOME"), FM_ROOT_OVERRIDE: await $.env.get("FM_ROOT_OVERRIDE") },
    $.plugin.root,
  );
  openedUnasked = false;
  await restore($);
  await poll($);
  poller?.cancel();
  poller = $.clock.every(POLL_MS, () => {
    void poll($);
  });
}

function openPane($: EngineInterface): Promise<unknown> {
  return $.ui.open({ id: PANE, title: "Captain's Call", focus: true, closeOnEscape: true, holdToasts: true, rows: 18 });
}

async function cardsNow($: EngineInterface): Promise<{ v: DeckView; cards: DeckCard[]; parked: number; card: DeckCard | undefined }> {
  const v = await read($, view);
  const cards = v.summary === null ? [] : buildCards(v.summary.decisions);
  const parked = v.summary?.parked ?? 0;
  const index = cards.length === 0 ? 0 : Math.min(v.index, cards.length - 1);
  return { v, cards, parked, card: cards[index] };
}

/** Publish one answer file per hold of the card: temp file, no-clobber hard link, unlink. */
async function publish($: EngineInterface, inbox: string, card: DeckCard, answer: { option: string } | { text: string }, label: string): Promise<void> {
  if (!inboxIsUsable(inbox)) {
    $.ui.toast("Not sent: firstmate publishes no answer folder");
    return;
  }
  const records: DeckSent[] = [];
  for (const hold of card.holds) {
    const now = await $.clock.now();
    const file = dropFileName(hold.id, now);
    const temp = `${inbox}/${dropTempName(hold.id, `${now}${Math.random().toString(36).slice(2)}`)}`;
    try {
      await $.fs.write(temp, dropFileBody(hold, answer, now));
      const linked = await $.process.run(["/bin/ln", temp, `${inbox}/${file}`]);
      if (linked.exitCode !== 0) throw new Error(linked.stderr.trim() || `ln exited ${linked.exitCode}`);
      records.push({ hold: hold.id, fingerprint: hold.fingerprint, file, label, at: now });
    } catch (error) {
      $.ui.toast(`Not sent for ${hold.id}: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      await $.process.run(["/bin/rm", "-f", temp]).catch(() => undefined);
    }
  }
  if (records.length === 0) return;
  const next = await update($, view, (s): DeckView => ({ ...s, sent: [...s.sent, ...records] }));
  await $.store.set(STORE_SENT, next.sent);
}

/** Pick an answer: publish after the undo window, unless `u` comes first. */
async function pick($: EngineInterface, card: DeckCard, answer: { option: string } | { text: string }, label: string): Promise<void> {
  await flush($);
  const inbox = (await read($, view)).summary?.inbox ?? "";
  const publishNow = () => publish($, inbox, card, answer, label);
  const timer = $.clock.after(UNDO_MS, () => {
    void flush($);
  });
  pending = { timer, publish: publishNow };
  await update($, view, (v): DeckView => ({ ...v, mode: "card", pending: { card: card.key, label } }));
  $.ui.toast(`Sent: ${label}. u to undo (5 s)`, { timeoutMs: UNDO_MS });
}

/** Publish the pending pick now, if there is one. */
async function flush($: EngineInterface): Promise<void> {
  const due = pending;
  if (due === undefined) return;
  pending = undefined;
  due.timer.cancel();
  await update($, view, (v): DeckView => ({ ...v, pending: null }));
  await due.publish();
}

async function undo($: EngineInterface): Promise<void> {
  if (pending === undefined) return;
  pending.timer.cancel();
  pending = undefined;
  await update($, view, (v): DeckView => ({ ...v, pending: null }));
  $.ui.toast("Undone: nothing was sent");
}

/** Ask firstmate in a framed prompt; never an answer. */
async function ask($: EngineInterface, card: DeckCard, kind: DeckAsk["kind"], text: string): Promise<void> {
  const v = await read($, view);
  await $.prompt.submit({ text });
  const at = await $.clock.now();
  const records = card.holds.map((h) => ({ hold: h.id, fingerprint: h.fingerprint, kind, text, session: v.session, at }));
  const next = await update($, view, (s): DeckView => ({ ...s, mode: "card", asks: [...s.asks, ...records] }));
  await $.store.set(STORE_ASKS, next.asks);
  $.ui.toast("Asked firstmate; it answers when idle");
}

async function openUrl($: EngineInterface, url: string): Promise<void> {
  const opened = await $.process.run(["open", url]).catch(() => ({ exitCode: 1 }));
  if (opened.exitCode !== 0) await $.process.run(["xdg-open", url]).catch(() => undefined);
}

function move($: EngineInterface, step: number, count: number): Promise<unknown> {
  return update($, view, (v): DeckView => ({ ...v, mode: "card", index: count === 0 ? 0 : (Math.min(v.index, count - 1) + step + count) % count }));
}

function setMode($: EngineInterface, mode: DeckView["mode"]): Promise<unknown> {
  return update($, view, (v): DeckView => ({ ...v, mode }));
}

function clock(iso: string): string {
  return /T(\d\d:\d\d)/.exec(iso)?.[1] ?? "?";
}

async function drawPane($: EngineInterface, e: RenderInput & { component: "Pane" }): Promise<RenderElement> {
  const ui = $.ui.resolve(e);
  const { Box, Text, Button } = ui;
  // Mobile draws no Input (its table completes one as a fragment): typing falls back to
  // answering in chat there.
  const Input = e.surface !== "mobile" && "Input" in ui ? ui.Input : undefined;
  const width = Math.max(20, e.props.bodyColumns);
  const { v, cards, parked, card } = await cardsNow($);
  const rows: RenderElement[] = [];
  rows.push(Text({ bold: true, wrap: "truncate", children: `${cards.length} waiting \u00b7 ${parked} parked` }));
  if (v.summary === null) {
    rows.push(Text({ dimColor: true, children: "No firstmate summary in this home yet." }));
    return Box({ flexDirection: "column", children: rows });
  }
  if (cards.length > 0) {
    const strip = cards.map((c) => `${c === card ? "\u25cf" : "\u25cb"} ${c.projects.join("+")}`).join("  ");
    rows.push(Text({ dimColor: true, wrap: "truncate", children: strip }));
  }
  rows.push(Text({ dimColor: true, children: "\u2500".repeat(Math.min(width, 60)) }));
  if (card === undefined) {
    rows.push(Text({ children: "Nothing waits on you." }));
  } else {
    const status = cardStatus(card, v.sent, v.asks, v.summary.seen, v.session);
    const pendingHere = v.pending?.card === card.key;
    rows.push(Text({ dimColor: true, wrap: "truncate", children: `${card.projects.join(", ")} \u00b7 ${ageLabel(card.ageDays)}` }));
    if (card.unclear.length > 0) rows.push(Text({ color: "yellow", children: `Unclear: ${card.unclear.join("; ")}` }));
    rows.push(Text({ children: v.mode === "full" ? card.question : card.short }));
    rows.push(Text({ dimColor: true, children: card.ifNothing ? `If nothing: ${card.ifNothing}` : "No default recorded." }));
    if (pendingHere) rows.push(Text({ color: "cyan", children: `Sending: ${v.pending!.label} (u to undo)` }));
    else if (status.text !== "") rows.push(Text({ color: "cyan", children: status.text }));

    if (v.mode === "later") {
      rows.push(
        Box({
          flexDirection: "row", flexWrap: "wrap", columnGap: 1,
          children: [
            ...laterDates(await $.clock.now()).map((d) =>
              Button({ key: `later-${d.key}`, hotkey: d.key, label: `${d.label} (${d.date})`, onPress: () => void ask($, card, "later", askPrompt("later", card, d.date)) }),
            ),
            Button({ key: "back", hotkey: "b", label: "Back", onPress: () => void setMode($, "card") }),
          ],
        }),
      );
    } else if (v.mode === "type" && Input !== undefined) {
      rows.push(
        Input({
          key: "answer", label: "Answer", submitLabel: "send", autoFocus: true,
          onSubmit: (value) => {
            const words = value.trim();
            if (words !== "") void pick($, card, { text: words }, words);
          },
        }),
      );
      rows.push(Button({ key: "back", hotkey: "b", label: "Back", onPress: () => void setMode($, "card") }));
    } else {
      const answerable = !status.answered && !pendingHere;
      if (answerable && card.options.length > 0 && card.options.length <= 4) {
        rows.push(
          Box({
            flexDirection: "column",
            children: card.options.map((o, i) =>
              Button({
                key: `option-${i + 1}`, hotkey: String(i + 1),
                label: `${cleanLabel(o.label)}${o.key === card.recommended ? "  \u2190 recommended" : ""}`,
                variant: o.key === card.recommended ? "primary" : undefined,
                onPress: () => void pick($, card, { option: o.key }, cleanLabel(o.label)),
              }),
            ),
          }),
        );
      }
      const actions: RenderElement[] = [];
      const rec = card.options.find((o) => o.key === card.recommended);
      if (answerable && rec !== undefined) actions.push(Button({ key: "rec", hotkey: "r", label: "Use your rec", onPress: () => void pick($, card, { option: rec.key }, cleanLabel(rec.label)) }));
      if (pendingHere) actions.push(Button({ key: "undo", hotkey: "u", label: "Undo", onPress: () => void undo($) }));
      actions.push(Button({ key: "later", hotkey: "l", label: "Later\u2026", onPress: () => void setMode($, "later") }));
      actions.push(Button({ key: "explain", hotkey: "e", label: "Explain", onPress: () => void ask($, card, "explain", askPrompt("explain", card)) }));
      actions.push(Button({ key: "not-mine", hotkey: "x", label: "Not mine", onPress: () => void ask($, card, "not-mine", askPrompt("not-mine", card)) }));
      if (answerable) {
        actions.push(
          Input === undefined
            ? Button({ key: "type", hotkey: "t", label: "Answer in chat", onPress: () => void ask($, card, "chat", askPrompt("chat", card)) })
            : Button({ key: "type", hotkey: "t", label: "Type\u2026", onPress: () => void setMode($, "type") }),
        );
      }
      if (card.unclear.length > 0) actions.push(Button({ key: "rewrite", hotkey: "f", label: "Ask firstmate to rewrite", onPress: () => void ask($, card, "rewrite", askPrompt("rewrite", card, card.unclear.join("; "))) }));
      if (card.short !== card.question) actions.push(Button({ key: "more", hotkey: "m", label: v.mode === "full" ? "Less" : "Full question", onPress: () => void setMode($, v.mode === "full" ? "card" : "full") }));
      if (status.resend !== undefined) {
        const again = status.resend;
        actions.push(Button({ key: "resend", hotkey: "s", label: "Resend", onPress: () => void ask($, card, again.kind, again.text) }));
      }
      rows.push(Box({ flexDirection: "row", flexWrap: "wrap", columnGap: 1, children: actions }));
    }
  }
  rows.push(Text({ dimColor: true, children: "\u2500".repeat(Math.min(width, 60)) }));
  const footer: RenderElement[] = [];
  if (cards.length > 1) {
    footer.push(Button({ key: "prev", hotkey: "p", label: "\u25c2", plain: true, onPress: () => void move($, -1, cards.length) }));
    footer.push(Text({ children: `${cards.indexOf(card!) + 1} of ${cards.length}` }));
    footer.push(Button({ key: "next", hotkey: "n", label: "\u25b8", plain: true, onPress: () => void move($, 1, cards.length) }));
  }
  const age = (await $.clock.now()) - Date.parse(v.summary.generatedAt);
  footer.push(Text({ dimColor: true, children: `list from ${clock(v.summary.generatedAt)}${age > STALE_SUMMARY_MS ? " (may be out of date)" : ""}` }));
  rows.push(Box({ flexDirection: "row", flexWrap: "wrap", columnGap: 1, children: footer }));
  const pr = v.summary.prs[0];
  if (pr !== undefined) {
    rows.push(
      Box({
        flexDirection: "row", flexWrap: "wrap", columnGap: 1,
        children: [
          Text({ children: `Ready for you: ${pr.label}${v.summary.prs.length > 1 ? ` (+${v.summary.prs.length - 1} more)` : ""}` }),
          Button({ key: "open-pr", hotkey: "o", label: "Open", onPress: () => void openUrl($, pr.url) }),
          Button({ key: "copy-pr", hotkey: "c", label: "Copy link", onPress: (press) => void $.ui.copy({ text: pr.url, surface: press.surface }) }),
        ],
      }),
    );
  }
  return Box({ flexDirection: "column", children: rows });
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    await $.command.register({ name: COMMAND, description: "Open Captain's Call: firstmate's pending decisions, one card at a time." });
    await start($);
    return next(e);
  });

  // Exit or /clear inside the undo window sends the pick at once.
  on("session.end", async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    await flush($);
    return next(e);
  });

  on("command.run", { command: COMMAND }, async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    await openPane($);
    return {};
  });

  on("ui.render", { component: "Pane", requestId: PANE }, async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    return drawPane($, e);
  });

  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    const v = await read($, view);
    if (e.props.hasSurvey || v.summary === null) return next(e);
    const calls = buildCards(v.summary.decisions).length;
    const parts = bandParts(calls, v.summary.prs, v.notes);
    if (parts.length === 0) return next(e);
    const { Box, Text, Button } = $.ui.resolve(e);
    const pr = v.summary.prs[0];
    return Box({
      flexDirection: "row", flexWrap: "wrap", columnGap: 1,
      children: [
        Text({ wrap: "truncate", children: parts.join(" \u00b7 ") }),
        ...(calls > 0 ? [Button({ key: "calls", hotkey: "d", label: "Calls", onPress: () => void openPane($) })] : []),
        ...(pr !== undefined ? [Button({ key: "open-pr", hotkey: "o", label: `Open ${pr.label}`, onPress: () => void openUrl($, pr.url) })] : []),
      ],
    });
  });

  on("ui.render", { component: "SessionMode" }, async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    const v = await read($, view);
    if (v.summary === null || e.props.modes.includes("firstmate")) return next(e);
    return next({ ...e, props: { ...e.props, modes: [...e.props.modes, "firstmate"] } });
  });
};
