// fm-deck's type contract: the summary fields it draws, its own records, and the one
// `$.state` value both the Captain's Call pane and the Deck band draw from.

export type DeckOption = { key: string; label: string };

export type DeckDecision = {
  id: string;
  project: string;
  summary: string;
  question: string;
  fingerprint: string;
  options: DeckOption[];
  bucket: string;
  ageDays: number;
};

export type DeckSeen = { file: string; holdId: string; status: string; reason: string };

export type DeckPr = { task: string; url: string; label: string };

export type DeckSummary = {
  generatedAt: string;
  inbox: string;
  decisions: DeckDecision[];
  /** Captain holds parked out of the live list (blocked, dated, aged), from the summary's queued[]. */
  parked: number;
  seen: DeckSeen[];
  prs: DeckPr[];
  workers: number;
  blockedWorkers: number;
};

/** One card: one live question, covering every hold whose question text is identical. */
export type DeckCard = {
  key: string;
  holds: { id: string; fingerprint: string; project: string }[];
  projects: string[];
  question: string;
  short: string;
  ifNothing: string | undefined;
  options: DeckOption[];
  recommended: string | undefined;
  ageDays: number;
  unclear: string[];
};

/** A sent answer the pane remembers across /clear and restarts ($.store). */
export type DeckSent = { hold: string; fingerprint: string; file: string; label: string; at: number };

export type AskKind = "later" | "explain" | "not-mine" | "rewrite" | "chat";

/** A framed prompt the pane sent firstmate about a card ($.store). */
export type DeckAsk = { hold: string; fingerprint: string; kind: AskKind; text: string; session: string; at: number };

/** Everything the pane and band draw. */
export type DeckView = {
  summary: DeckSummary | null;
  index: number;
  mode: "card" | "full" | "later" | "type";
  pending: { card: string; label: string } | null;
  sent: DeckSent[];
  asks: DeckAsk[];
  notes: number;
  helmOther: string | null;
  session: string;
};

declare module "claude-code" {
  interface PluginState {
    "fm-deck": { view: DeckView };
  }
}
