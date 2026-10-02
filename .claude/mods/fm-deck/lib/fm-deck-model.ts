// fm-deck's model, kept free of the engine so Node and `claude plugin test` both run it.
//
// It reads the parts of state/home-summary.json the Captain's Call pane and the Deck
// line draw, turns live captain holds into cards (grouping identical questions and
// linting unclear ones), and builds the exact drop-file name and body, the framed
// prompts, and the status-line text. docs/fm-deck.md owns the captain-facing contract;
// bin/fm-procevent-answer-drop.sh owns the drop-file contract this module writes to,
// and bin/fm-fleet-snapshot.sh the summary fields it reads.

/** The source name the answer-drop adapter accepts from this pane. */
export const DECK_SOURCE = "fm-deck";
/** Undo window before a picked answer is published. */
export const UNDO_MS = 5000;
/** Summary older than this is flagged as possibly out of date. */
export const STALE_SUMMARY_MS = 10 * 60 * 1000;
/** Monitoring counts as healthy while the watcher beat is younger than this (fm-supervision-lib's default grace). */
export const WATCH_GRACE_MS = 300 * 1000;
/** A question longer than this lints as unclear. */
export const LONG_QUESTION_CHARS = 300;
/** At most this many options get number keys. */
export const MAX_OPTIONS = 4;

import type {
  AskKind,
  DeckAsk,
  DeckCard,
  DeckDecision,
  DeckOption,
  DeckPr,
  DeckSeen,
  DeckSent,
  DeckSummary,
} from "../types/index.d.ts";

const HOLD_ID = /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/;
const FINGERPRINT = /^[0-9a-f]{64}$/;
const RECOMMENDED_SUFFIX = /\s*[-–—(]\s*recommended\)?\s*$/i;
const PATH = /(?:~|\.{0,2})\/[\w.@-]+(?:\/[\w.@-]+)+|\b[\w.-]+\/[\w.-]+\.\w{1,5}\b/g;

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

/** The parent of a path; a bare name resolves to itself. */
function parentDirectory(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  const cut = trimmed.lastIndexOf("/");
  return cut > 0 ? trimmed.slice(0, cut) : trimmed;
}

/**
 * The Firstmate home the mod reads, resolved as firstmate-calm resolves it: FM_HOME,
 * then FM_ROOT_OVERRIDE, then the code root three levels above the plugin folder.
 */
export function deckHome(env: { FM_HOME?: string; FM_ROOT_OVERRIDE?: string }, pluginRoot: string): string {
  return env.FM_HOME || env.FM_ROOT_OVERRIDE || parentDirectory(parentDirectory(parentDirectory(pluginRoot)));
}

/** Parse the summary fields the deck uses; undefined when the text is not a summary. */
export function parseSummary(raw: string | undefined): DeckSummary | undefined {
  if (raw === undefined) return undefined;
  let doc: Record<string, unknown>;
  try {
    doc = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (doc === null || typeof doc !== "object" || !Array.isArray(doc.decisions_open)) return undefined;
  const decisions: DeckDecision[] = [];
  for (const row of doc.decisions_open as Record<string, unknown>[]) {
    if (row === null || typeof row !== "object" || !HOLD_ID.test(text(row.id))) continue;
    const options = Array.isArray(row.options)
      ? (row.options as Record<string, unknown>[])
          .filter((o) => o !== null && typeof o === "object" && text(o.key) !== "")
          .map((o) => ({ key: text(o.key), label: text(o.label) || text(o.key) }))
      : [];
    decisions.push({
      id: text(row.id),
      project: text(row.project),
      summary: text(row.summary),
      question: text(row.question) || text(row.reason),
      fingerprint: text(row.question_fingerprint),
      options,
      bucket: text(row.hold_bucket) || "live",
      ageDays: typeof row.hold_age_days === "number" ? row.hold_age_days : 0,
    });
  }
  const seen = Array.isArray(doc.answers_seen)
    ? (doc.answers_seen as Record<string, unknown>[])
        .filter((s) => s !== null && typeof s === "object" && text(s.file) !== "")
        .map((s) => ({ file: text(s.file), holdId: text(s.hold_id), status: text(s.status), reason: text(s.reason) }))
    : [];
  const contributions = (doc.contributions ?? {}) as Record<string, unknown>;
  const prs = Array.isArray(contributions.captain)
    ? (contributions.captain as Record<string, unknown>[])
        .filter((p) => p !== null && typeof p === "object" && /^https:\/\//.test(text(p.url)))
        .map((p) => ({ task: text(p.task), url: text(p.url), label: prLabel(text(p.url)) }))
    : [];
  const fleet = Array.isArray(doc.fleet) ? (doc.fleet as Record<string, unknown>[]) : [];
  return {
    generatedAt: text(doc.generated_at),
    inbox: text(doc.answers_inbox),
    decisions,
    seen,
    prs,
    workers: fleet.length,
    blockedWorkers: fleet.filter((w) => w !== null && ["blocked", "failed"].includes(text(w.state))).length,
  };
}

/** `PR #64` for a pull-request URL, else the URL's last segment. */
export function prLabel(url: string): string {
  const pull = /\/pull\/(\d+)/.exec(url);
  return pull ? `PR #${pull[1]}` : url.replace(/\/+$/, "").split("/").pop() ?? url;
}

/** An option label without its "- recommended" marker. */
export function cleanLabel(label: string): string {
  return label.replace(RECOMMENDED_SUFFIX, "").trim() || label;
}

/** The question before its "Recommended:" and "If nothing:" sentences, and the if-nothing line. */
export function splitQuestion(question: string): { short: string; ifNothing: string | undefined } {
  const nothing = /\bIf nothing:\s*([^]*?)(?=\s*\bRecommended:|$)/i.exec(question);
  const cut = question.search(/\s*\b(Recommended|If nothing):/i);
  const short = (cut >= 0 ? question.slice(0, cut) : question).trim();
  return { short: short || question.trim(), ifNothing: nothing?.[1]?.trim() || undefined };
}

/** Why a card is unclear: the AIOS lessons, checked on the question as firstmate wrote it. */
export function lintCard(question: string, options: readonly DeckOption[], duplicateProjects: number): string[] {
  const reasons: string[] = [];
  if (options.length === 0) reasons.push("no options");
  if (options.length > MAX_OPTIONS) reasons.push(`more than ${MAX_OPTIONS} options`);
  if (question.length > LONG_QUESTION_CHARS) reasons.push("question too long");
  const words = question.replace(PATH, " ").split(/\s+/).filter((w) => /[A-Za-z]{2,}/.test(w));
  if (new RegExp(PATH.source).test(question) && words.length < 6) reasons.push("a file path is the only context");
  if (duplicateProjects > 1) reasons.push(`same question on ${duplicateProjects} items`);
  return reasons;
}

/** Live holds as cards, identical question text grouped into one card; parked ones counted. */
export function buildCards(decisions: readonly DeckDecision[]): { cards: DeckCard[]; parked: number } {
  const live = decisions.filter((d) => d.bucket === "live" && FINGERPRINT.test(d.fingerprint));
  const groups = new Map<string, DeckDecision[]>();
  for (const d of live) {
    const key = d.question.trim();
    groups.set(key, [...(groups.get(key) ?? []), d]);
  }
  const cards: DeckCard[] = [];
  for (const group of groups.values()) {
    const first = group[0]!;
    const { short, ifNothing } = splitQuestion(first.question);
    const recommended = first.options.find((o) => RECOMMENDED_SUFFIX.test(o.label))?.key;
    const projects = [...new Set(group.map((d) => d.project || d.id))];
    // A grouped card answers every hold with one key, so it needs the same option keys on each.
    const sameKeys = group.every((d) => d.options.map((o) => o.key).join("\n") === first.options.map((o) => o.key).join("\n"));
    cards.push({
      key: group.map((d) => d.id).join("+"),
      holds: group.map((d) => ({ id: d.id, fingerprint: d.fingerprint, project: d.project })),
      projects,
      question: first.question,
      short,
      ifNothing,
      options: sameKeys ? first.options : [],
      recommended: sameKeys ? recommended : undefined,
      ageDays: Math.max(...group.map((d) => d.ageDays)),
      unclear: lintCard(first.question, sameKeys ? first.options : [], group.length),
    });
  }
  return { cards, parked: decisions.length - live.length };
}

/** The published drop-file name the adapter reads: `<hold_id>-<epoch-ms>.json`. */
export function dropFileName(holdId: string, epochMs: number): string {
  if (!HOLD_ID.test(holdId)) throw new Error(`not a hold id: ${holdId}`);
  return `${holdId}-${Math.trunc(epochMs)}.json`;
}

/** A hidden temp name in the drop folder, never read by the adapter. */
export function dropTempName(holdId: string, nonce: string): string {
  if (!HOLD_ID.test(holdId)) throw new Error(`not a hold id: ${holdId}`);
  return `.${holdId}.${DECK_SOURCE}.${nonce.replace(/[^A-Za-z0-9]/g, "")}.tmp`;
}

/** The drop-file body: one option key or typed words, stamped with the fm-deck source. */
export function dropFileBody(
  hold: { id: string; fingerprint: string },
  answer: { option: string } | { text: string },
  epochMs: number,
): string {
  return `${JSON.stringify({
    hold_id: hold.id,
    question_fingerprint: hold.fingerprint,
    answer,
    answered_at: new Date(epochMs).toISOString().replace(/\.\d{3}Z$/, "Z"),
    source: DECK_SOURCE,
  })}\n`;
}

/** Whether the published inbox is a folder the deck may write into. */
export function inboxIsUsable(inbox: string): boolean {
  return inbox.startsWith("/") && /\/answer-drop$/.test(inbox) && !inbox.split("/").includes("..");
}

/** A card's answer status from the pane's own records and firstmate's answers_seen. */
export function cardStatus(
  card: DeckCard,
  sent: readonly DeckSent[],
  asks: readonly DeckAsk[],
  seen: readonly DeckSeen[],
  session: string,
): { text: string; answered: boolean; resend: DeckAsk | undefined } {
  const current = (r: { hold: string; fingerprint: string }) =>
    card.holds.some((h) => h.id === r.hold && h.fingerprint === r.fingerprint);
  const mine = sent.filter(current).sort((a, b) => b.at - a.at)[0];
  if (mine !== undefined) {
    const row = seen.find((s) => s.file === mine.file);
    if (row === undefined) return { text: `sent: ${mine.label}`, answered: true, resend: undefined };
    if (row.status === "picked_up") return { text: `picked up: ${mine.label}`, answered: true, resend: undefined };
    if (row.status === "resolved") return { text: `done: ${mine.label}`, answered: true, resend: undefined };
    if (row.status === "rejected") return { text: `not taken (${row.reason || "rejected"}); answer again`, answered: false, resend: undefined };
  }
  const ask = asks.filter(current).sort((a, b) => b.at - a.at)[0];
  if (ask !== undefined) {
    if (ask.session !== session) return { text: `asked firstmate in an earlier session (${ask.kind})`, answered: false, resend: ask };
    return { text: `asked firstmate (${ask.kind})`, answered: false, resend: undefined };
  }
  return { text: "", answered: false, resend: undefined };
}

/** The three Later choices, as local dates. */
export function laterDates(nowMs: number): { key: string; label: string; date: string }[] {
  const day = (offset: number) => {
    const d = new Date(nowMs);
    d.setDate(d.getDate() + offset);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  };
  const weekday = new Date(nowMs).getDay();
  const toMonday = ((8 - weekday) % 7) || 7;
  return [
    { key: "1", label: "Tomorrow", date: day(1) },
    { key: "2", label: "Next week", date: day(7) },
    { key: "3", label: "Next Monday", date: day(toMonday) },
  ];
}

function cardNames(card: DeckCard): string {
  return card.holds.map((h) => h.id).join(", ");
}

/** The framed prompt for an action that must never go through the answer intake. */
export function askPrompt(kind: AskKind, card: DeckCard, detail = ""): string {
  const ids = cardNames(card);
  const quoted = JSON.stringify(card.short.length > 140 ? `${card.short.slice(0, 139)}…` : card.short);
  switch (kind) {
    case "later":
      return `From the decisions pane: the captain defers ${ids} (${quoted}) until ${detail}. Hold it until that date; this is not an answer, so do not close or release it.`;
    case "explain":
      return `From the decisions pane: the captain asks you to explain ${ids} (${quoted}) in chat, in plain words: what it decides, the options, your recommendation, and what happens if nothing is chosen. This is not an answer.`;
    case "not-mine":
      return `From the decisions pane: the captain says ${ids} (${quoted}) is not a decision for the captain or is already done. Reconcile it under captain-hold-lifecycle; this is not an answer to record.`;
    case "rewrite":
      return `From the decisions pane: ${ids} reads as unclear (${detail}). Rewrite the hold as one plain question with up to ${MAX_OPTIONS} options, one marked recommended, and what happens if nothing is chosen. This is not an answer.`;
    case "chat":
      return `From the decisions pane: the captain wants to answer ${ids} (${quoted}) in chat. Ask the captain the question there; this is not an answer yet.`;
  }
}

/** Age in plain words. */
export function ageLabel(days: number): string {
  if (days <= 0) return "open today";
  return days === 1 ? "open 1 day" : `open ${days} days`;
}

/** `5h 62%`-style labels for the session's rate-limit windows. */
export function rateLimitLabel(kind: string): string {
  return kind === "five_hour" ? "5h" : kind === "seven_day" ? "7d" : kind === "spend_limit" ? "spend" : kind;
}

export type DeckLineInput = {
  summary: DeckSummary | undefined;
  calls: number;
  helmOther: string | undefined;
  watchAgeMs: number | undefined;
  contextPercent: number | undefined;
  rateLimits: readonly { kind: string; percentUsed: number }[];
};

/** The pinned status line; undefined when this is not a firstmate home (no summary). */
export function deckLine(input: DeckLineInput): string | undefined {
  if (input.summary === undefined) return undefined;
  const parts = ["⚓ firstmate"];
  if (input.helmOther !== undefined) {
    parts.push(`helm: another session (${input.helmOther.slice(0, 6)}…)`);
  } else {
    const s = input.summary;
    parts.push(input.calls === 1 ? "1 call" : `${input.calls} calls`);
    if (s.prs.length > 0) parts.push(`${s.prs.length} PR${s.prs.length === 1 ? "" : "s"} ready`);
    parts.push(`${s.workers} worker${s.workers === 1 ? "" : "s"}${s.blockedWorkers > 0 ? ` (${s.blockedWorkers} blocked)` : ""}`);
    parts.push(watchLabel(input.watchAgeMs, s.workers));
  }
  if (input.contextPercent !== undefined) parts.push(`ctx ${Math.round(input.contextPercent)}%`);
  for (const limit of input.rateLimits) parts.push(`${rateLimitLabel(limit.kind)} ${Math.round(limit.percentUsed)}%`);
  return parts.join(" · ");
}

function watchLabel(ageMs: number | undefined, workers: number): string {
  if (ageMs !== undefined && ageMs < WATCH_GRACE_MS) return "watch ok";
  if (workers === 0) return "watch idle";
  return ageMs === undefined ? "watch down" : `watch down ${Math.round(ageMs / 60000)}m`;
}

/** The band's parts above the prompt; empty when nothing waits on the captain. */
export function bandParts(calls: number, prs: readonly DeckPr[], notes: number): string[] {
  const parts: string[] = [];
  if (calls > 0) parts.push(`${calls} call${calls === 1 ? "" : "s"} wait${calls === 1 ? "s" : ""} on you`);
  if (prs.length > 0) parts.push(prs.length === 1 ? `${prs[0]!.label} ready` : `${prs.length} PRs ready`);
  if (notes > 0) parts.push(`${notes} note${notes === 1 ? "" : "s"} from AIOS`);
  return parts;
}
