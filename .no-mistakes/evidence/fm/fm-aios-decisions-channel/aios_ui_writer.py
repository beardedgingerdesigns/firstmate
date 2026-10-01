#!/usr/bin/env python3
"""Minimal stand-in for the aios-ui answer writer (claude-os ADR 0012 §3).

Reads ONLY state/home-summary.json, finds the decision, and drops one answer
file into answers_inbox atomically (temp file + rename). Never runs FirstMate
scripts and never writes any other FirstMate file.

usage: aios_ui_writer.py <summary.json> <hold_id> (--option KEY | --text WORDS)
                         [--note NOTE] [--fingerprint FP] [--raw BYTES]
"""
import argparse, json, os, tempfile, time

p = argparse.ArgumentParser()
p.add_argument("summary"); p.add_argument("hold_id")
p.add_argument("--option"); p.add_argument("--text"); p.add_argument("--note")
p.add_argument("--fingerprint", help="override (simulates a stale screen)")
p.add_argument("--raw", help="write these raw bytes instead (malformed file)")
a = p.parse_args()

s = json.load(open(a.summary))
inbox = s["answers_inbox"]
assert os.path.isabs(inbox), inbox
dec = next((d for d in s["decisions_open"] if d["id"] == a.hold_id), None)
fp = a.fingerprint or (dec or {}).get("question_fingerprint") or "0" * 64
name = f"{a.hold_id}-{int(time.time() * 1000)}.json"
if a.raw is not None:
    body = a.raw
else:
    doc = {"hold_id": a.hold_id, "question_fingerprint": fp,
           "answer": {"option": a.option} if a.option else {"text": a.text},
           "answered_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "source": "aios-ui"}
    if a.note:
        doc["note"] = a.note
    body = json.dumps(doc)
fd, tmp = tempfile.mkstemp(dir=inbox, prefix=".", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    f.write(body)
os.rename(tmp, os.path.join(inbox, name))
print(name)
