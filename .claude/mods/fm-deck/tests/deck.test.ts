// fm-deck under `claude plugin test`: activation, the Deck line and band, and the
// Captain's Call pane's cards, answers, undo, framed prompts, and read-back status.
import { describe, expect, test } from "claude-code/testing";
import {
  FP,
  HOME,
  INBOX,
  NOW,
  PANE,
  SUMMARY,
  abovePrompt,
  isStock,
  sessionMode,
  sessionStart,
  summaryDoc,
  textOf,
  world,
} from "./support.ts";

describe("activation", () => {
  for (const functionHooks of [undefined, "true"]) {
    test(`is fully inert when the function-hooks opt-in is ${functionHooks ?? "absent"}`, async ($, on) => {
      const { journal } = world(on, { functionHooks });
      await $.session.start(sessionStart);
      expect(isStock(await $.ui.render(abovePrompt()))).toBe(true);
      expect(isStock(await $.ui.render(sessionMode()))).toBe(true);
      expect(journal.commands).toHaveLength(0);
      expect(journal.statuses).toHaveLength(0);
      expect(journal.fsReads).toHaveLength(0);
    });
  }

  test("draws nothing in a home with no summary", async ($, on) => {
    const { journal } = world(on, { summary: undefined });
    await $.session.start(sessionStart);
    expect(journal.commands).toEqual(["calls"]);
    expect(journal.statuses).toHaveLength(0);
    expect(journal.opens).toHaveLength(0);
    expect(isStock(await $.ui.render(abovePrompt()))).toBe(true);
    expect(isStock(await $.ui.render(sessionMode()))).toBe(true);
  });
});

describe("Deck line", () => {
  test("pins counts, monitoring, context, and quota, and labels the window", async ($, on) => {
    const { journal } = world(on);
    await $.session.start(sessionStart);
    expect(journal.statuses.at(-1)).toBe(
      "⚓ firstmate · 3 calls · 1 PR ready · 2 workers (1 blocked) · watch ok · ctx 41% · 5h 62%",
    );
    expect(JSON.stringify(await $.ui.render(sessionMode(["auto"])))).toContain("modes=auto,firstmate");
  });

  test("says when another session holds the helm, and when monitoring is down", async ($, on) => {
    const { journal } = world(on, { lockSession: "da567243-584f", beatAgeMs: 12 * 60_000 });
    await $.session.start(sessionStart);
    expect(journal.statuses.at(-1)).toBe("⚓ firstmate · helm: another session (da5672…) · ctx 41% · 5h 62%");
  });

  test("flags stale monitoring while workers run", async ($, on) => {
    const { journal } = world(on, { beatAgeMs: 12 * 60_000 });
    await $.session.start(sessionStart);
    expect(journal.statuses.at(-1)).toContain("watch down 12m");
  });

  test("the band shows only when something waits, and yields to a survey", async ($, on) => {
    world(on, { notes: ["n1.note", "n2.note"] });
    await $.session.start(sessionStart);
    const band = textOf(await $.ui.render(abovePrompt()));
    expect(band).toContain("3 calls wait on you · PR #64 ready · 2 notes from AIOS");
    expect(band).toContain("Calls");
    expect(isStock(await $.ui.render(abovePrompt(true)))).toBe(true);
  });

  test("the band passes when nothing waits", async ($, on) => {
    world(on, { summary: summaryDoc({ decisions_open: [], contributions: {} }) });
    await $.session.start(sessionStart);
    expect(isStock(await $.ui.render(abovePrompt()))).toBe(true);
  });

  test("opens the pane unasked once when live calls exist, and /calls opens it focused", async ($, on) => {
    const { journal, clock } = world(on);
    await $.session.start(sessionStart);
    await clock.advance(9000);
    expect(journal.opens).toEqual([{ id: "calls" }]);
    await $.command.run({ command: "calls", args: "", origin: { kind: "composer" }, presentation: { isFullscreen: false, columns: 80 } });
    expect(journal.opens.at(-1)).toEqual({ id: "calls", focus: true });
  });
});

describe("Captain's Call cards", () => {
  test("shows live calls one at a time, groups identical questions, counts parked, and lints unclear ones", async ($, on) => {
    world(on);
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    let drawn = textOf(await ui.drawn());
    expect(drawn).toContain("3 waiting · 1 parked");
    expect(drawn).toContain("tonequest · open 2 days");
    expect(drawn).toContain('Add a "The Inside" field to issues and fill October\'s from Liz\'s doc?');
    expect(drawn).not.toContain("Recommended: yes");
    expect(drawn).toContain("If nothing: October ships without The Inside.");
    expect(drawn).toContain("Add the field and fill October  ← recommended");
    expect(drawn).toContain("Use your rec");
    expect(drawn).toContain("1 of 3");
    expect(drawn).toContain("Ready for you: PR #64");
    await ui.press({ key: "next" });
    drawn = textOf(await ui.drawn());
    expect(drawn).toContain("cd-a, cd-b · open 4 days");
    expect(drawn).toContain("No default recorded.");
    await ui.press({ key: "next" });
    drawn = textOf(await ui.drawn());
    expect(drawn).toContain("Unclear: no options; a file path is the only context");
    expect(drawn).toContain("Ask firstmate to rewrite");
    expect(await ui.find({ key: "option-1" })).toBeUndefined();
  });

  test("a pick publishes after five seconds as one fm-deck drop file, through a temp file and a hard link", async ($, on) => {
    const { journal, clock, files } = world(on);
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    await ui.press({ key: "rec" });
    expect(journal.toasts.at(-1)).toBe("Sent: Add the field and fill October. u to undo (5 s)");
    expect(journal.writes).toHaveLength(0);
    await clock.advance(4000);
    expect(journal.writes).toHaveLength(0);
    await clock.advance(1500);
    expect(journal.writes).toHaveLength(1);
    const temp = journal.writes[0]!.path;
    expect(temp.startsWith(`${INBOX}/.tq-inside.fm-deck.`)).toBe(true);
    expect(temp.endsWith(".tmp")).toBe(true);
    const link = journal.runs.find((argv) => argv[0] === "/bin/ln")!;
    expect(link[1]).toBe(temp);
    expect(link[2]).toMatch(new RegExp(`^${INBOX}/tq-inside-\\d+\\.json$`));
    expect(journal.runs.some((argv) => argv[0] === "/bin/rm" && argv[2] === temp)).toBe(true);
    expect(files.has(temp)).toBe(false);
    const body = JSON.parse(files.get(link[2]!)!.text);
    expect(body).toEqual({
      hold_id: "tq-inside",
      question_fingerprint: FP(1),
      answer: { option: "add" },
      answered_at: expect.stringMatching(/^2026-10-02T20:10:0\dZ$/),
      source: "fm-deck",
    });
    expect(journal.prompts).toHaveLength(0);
    expect(textOf(await ui.drawn())).toContain("sent: Add the field and fill October");
  });

  test("undo within five seconds sends nothing", async ($, on) => {
    const { journal, clock } = world(on);
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    await ui.press({ key: "option-2" });
    expect(textOf(await ui.drawn())).toContain("Sending: Skip it for October (u to undo)");
    await ui.press({ key: "undo" });
    await clock.advance(10_000);
    expect(journal.writes).toHaveLength(0);
    expect(journal.runs).toHaveLength(0);
    expect(journal.toasts.at(-1)).toBe("Undone: nothing was sent");
  });

  test("a grouped card answers every hold it covers", async ($, on) => {
    const { journal, clock, files } = world(on);
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    await ui.press({ key: "next" });
    await ui.press({ key: "option-2" });
    await clock.advance(5000);
    const published = journal.runs.filter((argv) => argv[0] === "/bin/ln").map((argv) => argv[2]!);
    expect(published).toHaveLength(2);
    const bodies = published.map((p) => JSON.parse(files.get(p)!.text));
    expect(bodies.map((b) => [b.hold_id, b.question_fingerprint, b.answer.option])).toEqual([
      ["cd-host-a", FP(2), "fly"],
      ["cd-host-b", FP(3), "fly"],
    ]);
  });

  test("a typed answer publishes the words", async ($, on) => {
    const { journal, clock, files } = world(on);
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    await ui.press({ key: "type" });
    await ui.input({ key: "answer", text: "Only the cover story" });
    await clock.advance(5000);
    const link = journal.runs.find((argv) => argv[0] === "/bin/ln")!;
    expect(JSON.parse(files.get(link[2]!)!.text).answer).toEqual({ text: "Only the cover story" });
  });

  test("on mobile, t asks firstmate to take the answer in chat", async ($, on) => {
    const { journal } = world(on);
    await $.session.start(sessionStart);
    const ui = await $.ui.mount({ ...PANE, surface: "mobile" as const });
    await ui.press({ key: "type" });
    expect(journal.prompts).toHaveLength(1);
    expect(journal.prompts[0]).toContain("wants to answer tq-inside");
    expect(journal.writes).toHaveLength(0);
  });

  test("later, explain, not-mine, and rewrite go to firstmate as framed prompts, never as answers", async ($, on) => {
    const { journal, files } = world(on);
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    await ui.press({ key: "later" });
    expect(textOf(await ui.drawn())).toContain("Tomorrow (2026-10-03)");
    await ui.press({ key: "later-1" });
    expect(journal.prompts[0]).toContain("defers tq-inside");
    expect(journal.prompts[0]).toContain("until 2026-10-03");
    expect(journal.prompts[0]).toContain("this is not an answer");
    await ui.press({ key: "explain" });
    expect(journal.prompts[1]).toContain("explain tq-inside");
    await ui.press({ key: "not-mine" });
    expect(journal.prompts[2]).toContain("tq-inside");
    expect(journal.prompts[2]).toContain("not a decision for the captain");
    await ui.press({ key: "next" });
    await ui.press({ key: "next" });
    await ui.press({ key: "rewrite" });
    expect(journal.prompts[3]).toContain("isf-load reads as unclear (no options; a file path is the only context)");
    expect(journal.writes).toHaveLength(0);
    expect([...files.keys()].some((p) => p.startsWith(INBOX))).toBe(false);
  });

  test("status follows answers_seen and survives a restart through the store", async ($, on) => {
    const { clock, publish, journal } = world(on);
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    await ui.press({ key: "option-1" });
    await clock.advance(5000);
    const file = journal.runs.find((argv) => argv[0] === "/bin/ln")![2]!.split("/").pop()!;
    publish(summaryDoc({ answers_seen: [{ file, hold_id: "tq-inside", status: "picked_up", reason: null, at: "x" }] }));
    await clock.advance(3000);
    expect(textOf(await ui.drawn())).toContain("picked up: Add the field and fill October");
    publish(summaryDoc({ answers_seen: [{ file, hold_id: "tq-inside", status: "resolved", reason: null, at: "x" }] }));
    await clock.advance(3000);
    expect(textOf(await ui.drawn())).toContain("done: Add the field and fill October");
    expect(await ui.find({ key: "option-1" })).toBeUndefined();
    // A restart (or /clear) reloads the pane's own records from the store.
    await $.session.start(sessionStart);
    expect(textOf(await ui.drawn())).toContain("done: Add the field and fill October");
    publish(summaryDoc({ answers_seen: [{ file, hold_id: "tq-inside", status: "rejected", reason: "question-changed", at: "x" }] }));
    await clock.advance(3000);
    expect(textOf(await ui.drawn())).toContain("not taken (question-changed); answer again");
    expect(await ui.find({ key: "option-1" })).toBeDefined();
  });

  test("an ask from an earlier session offers resend", async ($, on) => {
    const { journal } = world(on, {
      store: { asks: [{ hold: "tq-inside", fingerprint: FP(1), kind: "explain", text: "From the decisions pane: explain", session: "old", at: NOW - 1000 }] },
    });
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    expect(textOf(await ui.drawn())).toContain("asked firstmate in an earlier session (explain)");
    await ui.press({ key: "resend" });
    expect(journal.prompts).toEqual(["From the decisions pane: explain"]);
  });

  test("Ready for you opens and copies the PR link", async ($, on) => {
    const { journal } = world(on);
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    await ui.press({ key: "open-pr" });
    expect(journal.runs.at(-1)).toEqual(["open", "https://github.com/acme/ie/pull/64"]);
    await ui.press({ key: "copy-pr" });
    expect(journal.copies).toEqual(["https://github.com/acme/ie/pull/64"]);
  });

  test("flags a summary older than ten minutes", async ($, on) => {
    world(on, { summary: summaryDoc({ generated_at: "2026-10-02T19:50:00Z" }) });
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    expect(textOf(await ui.drawn())).toContain("list from 19:50 (may be out of date)");
  });

  test("never writes outside the published answer folder", async ($, on) => {
    const { journal, clock } = world(on, { summary: summaryDoc({ answers_inbox: `${HOME}/data` }) });
    await $.session.start(sessionStart);
    const ui = await $.ui.mount(PANE);
    await ui.press({ key: "option-1" });
    await clock.advance(5000);
    expect(journal.writes).toHaveLength(0);
    expect(journal.toasts.at(-1)).toBe("Not sent: firstmate publishes no answer folder");
    expect(SUMMARY.startsWith(HOME)).toBe(true);
  });
});
