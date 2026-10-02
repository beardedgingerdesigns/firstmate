// Shared fixtures for the fm-deck plugin test suites under `claude plugin test`.
//
// Each test mocks the world beneath the plugin: the environment naming the Firstmate
// home, an in-memory file system holding state/home-summary.json and the other files
// the deck reads, the host commands it runs, the prompts it submits, and a journal of
// every call it makes on `$`.
import type { On } from "claude-code";
import { mock, type MockClock } from "claude-code/testing";

export const HOME = "/fm/home";
export const STATE = `${HOME}/state`;
export const SUMMARY = `${STATE}/home-summary.json`;
export const INBOX = `${STATE}/answer-drop`;
export const SESSION = "this-session-0001";
export const NOW = Date.parse("2026-10-02T20:10:00Z");

export const FP = (n: number) => String(n).repeat(64).slice(0, 64);

/** A summary as bin/fm-fleet-snapshot.sh publishes it, with the fields the deck reads. */
export function summaryDoc(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    generated_at: "2026-10-02T20:06:29Z",
    answers_inbox: INBOX,
    answers_seen: [],
    decisions_open: [
      {
        id: "tq-inside", project: "tonequest", summary: "The Inside field",
        question: 'Add a "The Inside" field to issues and fill October\'s from Liz\'s doc? Recommended: yes. If nothing: October ships without The Inside.',
        options: [{ key: "add", label: "Add the field and fill October - recommended" }, { key: "skip", label: "Skip it for October" }],
        question_fingerprint: FP(1), hold_bucket: "live", hold_age_days: 2,
      },
      {
        id: "cd-host-a", project: "cd-a", summary: "Host", question: "Which host should the CD staging site use?",
        options: [{ key: "do", label: "DigitalOcean" }, { key: "fly", label: "Fly" }],
        question_fingerprint: FP(2), hold_bucket: "live", hold_age_days: 1,
      },
      {
        id: "cd-host-b", project: "cd-b", summary: "Host", question: "Which host should the CD staging site use?",
        options: [{ key: "do", label: "DigitalOcean" }, { key: "fly", label: "Fly" }],
        question_fingerprint: FP(3), hold_bucket: "live", hold_age_days: 4,
      },
      {
        id: "isf-load", project: "iowa-state-fair", summary: "DB load", question: "See data/isf/report.md",
        options: [], question_fingerprint: FP(4), hold_bucket: "live", hold_age_days: 11,
      },
      {
        id: "w1", key: "d1", verb: "decide", summary: "Worker status decision", reason: null,
        project: "x", options: [], question: null, question_fingerprint: null, source: "status",
      },
    ],
    // Every structured hold, captain or not; parked captain holds appear only here.
    queued: [
      { id: "parked-dated", hold_bucket: "dated", captain_actionable: false },
      { id: "parked-aged", hold_bucket: "aged", captain_actionable: false },
      { id: "plain-queued", hold_bucket: null, captain_actionable: false },
      { id: "tq-inside", hold_bucket: "live", captain_actionable: true },
    ],
    contributions: { captain: [{ task: "ie-accounts", url: "https://github.com/acme/ie/pull/64", kind: "pr" }] },
    fleet: [{ task_id: "w1", state: "working" }, { task_id: "w2", state: "blocked" }],
    ...overrides,
  };
}

export type Journal = {
  commands: string[];
  toasts: string[];
  statuses: (string | undefined)[];
  opens: { id: string; focus?: true }[];
  writes: { path: string; text: string }[];
  runs: string[][];
  prompts: string[];
  copies: string[];
  fsReads: string[];
};

export type World = {
  clock: MockClock;
  files: Map<string, { text: string; mtimeMs: number }>;
  journal: Journal;
  /** Replace the summary, as a refresh does: new text and a new mtime. */
  publish: (doc: Record<string, unknown>) => void;
  /** What a real /clear does to the deck's view: it reads as its initial until next written. */
  clearView: () => void;
};

export type WorldOptions = {
  functionHooks?: string | undefined;
  summary?: Record<string, unknown> | undefined;
  lockSession?: string;
  beatAgeMs?: number;
  notes?: string[];
  store?: Record<string, unknown>;
};

export function world(on: On, options: WorldOptions = {}): World {
  const functionHooks = "functionHooks" in options ? options.functionHooks : "1";
  mock.env(on, {
    FM_HOME: HOME,
    ...(functionHooks === undefined ? {} : { CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: functionHooks }),
  });
  mock.store(on, options.store ?? {});
  const clock = mock.clock(on, { now: NOW });
  const files = new Map<string, { text: string; mtimeMs: number }>();
  const summary = "summary" in options ? options.summary : summaryDoc();
  if (summary !== undefined) files.set(SUMMARY, { text: JSON.stringify(summary), mtimeMs: NOW - 1000 });
  files.set(`${STATE}/.lock-session`, { text: `${options.lockSession ?? SESSION}\n`, mtimeMs: NOW - 5000 });
  files.set(`${STATE}/.last-watcher-beat`, { text: "", mtimeMs: NOW - (options.beatAgeMs ?? 20_000) });
  for (const note of options.notes ?? []) files.set(`${STATE}/inbox/${note}`, { text: "note", mtimeMs: NOW });
  const journal: Journal = { commands: [], toasts: [], statuses: [], opens: [], writes: [], runs: [], prompts: [], copies: [], fsReads: [] };
  let bump = 0;
  let viewCleared = false;

  on("fs.read", async (_$, e) => {
    journal.fsReads.push(e.path);
    const file = files.get(e.path);
    return file ? { value: file.text } : { deny: `ENOENT: ${e.path}` };
  });
  on("fs.stat", async (_$, e) => {
    const file = files.get(e.path);
    return file ? { value: { kind: "file" as const, size: file.text.length, mtimeMs: file.mtimeMs, isLink: false } } : { deny: `ENOENT: ${e.path}` };
  });
  on("fs.list", async (_$, e) => {
    const prefix = `${e.path}/`;
    const names = [...files.keys()].filter((p) => p.startsWith(prefix) && !p.slice(prefix.length).includes("/"));
    if (names.length === 0) return { deny: `ENOENT: ${e.path}` };
    return { value: names.map((p) => ({ name: p.slice(prefix.length), kind: "file" as const, size: 4, mtimeMs: NOW, isLink: false })) };
  });
  on("fs.write", async (_$, e) => {
    journal.writes.push({ path: e.path, text: e.text });
    files.set(e.path, { text: e.text, mtimeMs: clock.now() });
    return { value: undefined };
  });
  // The host commands the deck runs, performed on the in-memory files.
  on("process.run", async (_$, e) => {
    const argv = [...e.argv];
    journal.runs.push(argv);
    const ok = { exitCode: 0, stdout: "", stderr: "", isStdoutTruncated: false, isStderrTruncated: false };
    if (argv[0] === "/bin/ln") {
      const from = files.get(argv[1]!);
      if (from === undefined || files.has(argv[2]!)) return { value: { ...ok, exitCode: 1, stderr: "ln: File exists" } };
      files.set(argv[2]!, from);
      return { value: ok };
    }
    if (argv[0] === "/bin/rm") {
      files.delete(argv[2]!);
      return { value: ok };
    }
    return { value: ok };
  });
  on("prompt.submit", async (_$, e) => {
    journal.prompts.push(e.text);
    return { text: e.text };
  });
  on("command.register", async (_$, e) => {
    journal.commands.push(e.name);
    return { value: { command: e.name } };
  });
  on("ui.toast", async (_$, e) => {
    journal.toasts.push(e.text);
    return { value: undefined };
  });
  on("ui.status", async (_$, e) => {
    journal.statuses.push(e.text);
    return { value: undefined };
  });
  on("ui.open", async (_$, e) => {
    journal.opens.push({ id: e.id, ...(e.focus ? { focus: e.focus } : {}) });
    return { value: { isPlaced: true as const } };
  });
  on("ui.copy", async (_$, e) => {
    journal.copies.push(e.text);
    return { value: { isCopied: true as const } };
  });
  on("session.id", async () => ({ value: SESSION }));
  on("session.usage", async () => ({
    value: { startedAt: NOW - 60_000, context: { window: 200_000, percent: 41 }, rateLimits: [{ kind: "five_hour", percentUsed: 62 }] },
  }));
  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  on("session.end", async (_$, e) => ({ sessionId: e.sessionId }));
  on("state.get", async (_$, e, next) => {
    const held = await next(e);
    if (!viewCleared || e.plugin !== "fm-deck" || e.key !== "view" || !("value" in held)) return held;
    return { value: { value: undefined, version: held.value.version } };
  });
  on("state.set", async (_$, e, next) => {
    if (e.plugin === "fm-deck" && e.key === "view") viewCleared = false;
    return next(e);
  });
  // The engine's own drawing; the footer's mode labels are echoed so a rewrite is visible.
  on("ui.render", async (_$, e) => ({
    type: "Text",
    props: {},
    children: [STOCK_TEXT, e.component === "SessionMode" ? `modes=${(e.props as { modes: string[] }).modes.join(",")}` : ""],
  }));

  return {
    clock,
    files,
    journal,
    publish: (doc) => {
      bump += 1;
      files.set(SUMMARY, { text: JSON.stringify(doc), mtimeMs: NOW + bump });
    },
    clearView: () => {
      viewCleared = true;
    },
  };
}

/** The engine's own drawing, as the bottom of every `ui.render` chain. */
export const STOCK_TEXT = "STOCK-DRAWING";

export const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };

export const PANE = {
  plugin: "fm-deck",
  surface: "terminal" as const,
  component: "Pane" as const,
  requestId: "calls",
  props: {
    title: "Captain's Call",
    isFocused: true,
    bodyColumns: 70,
    placement: "dock" as const,
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
};

export function abovePrompt(hasSurvey = false) {
  return {
    surface: "terminal" as const,
    component: "AbovePrompt" as const,
    requestId: "above-prompt",
    viewport: { columns: 100, rows: 30 },
    props: { hasSurvey, isWorking: false, maxRows: 10, bodyColumns: 100, scroll: { offset: 0, bodyRows: 10 }, view: {} },
  };
}

export function sessionMode(modes: string[] = []) {
  return {
    surface: "terminal" as const,
    component: "SessionMode" as const,
    requestId: "session-mode",
    viewport: { columns: 100, rows: 30 },
    props: { modes },
  };
}

/** Every Text and Button label in a drawing, joined, for plain substring checks. */
export function textOf(tree: unknown): string {
  const out: string[] = [];
  const walk = (node: unknown) => {
    if (typeof node === "string") out.push(node);
    else if (Array.isArray(node)) node.forEach(walk);
    else if (node !== null && typeof node === "object") {
      const element = node as { props?: Record<string, unknown>; children?: unknown };
      if (typeof element.props?.label === "string") out.push(element.props.label);
      walk(element.props?.children);
      walk(element.children);
    }
  };
  walk(tree);
  return out.join(" | ");
}

export function isStock(tree: unknown): boolean {
  return JSON.stringify(tree).includes(STOCK_TEXT);
}
