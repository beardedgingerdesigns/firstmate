#!/usr/bin/env bash
# Live driver: real bin/fm-teardown.sh + real chrome-devtools-axi (headless Chrome).
# Reuses the fm-teardown test fixture builders, but deletes the fake chrome-devtools-axi
# so the installed one runs.
set -u
WT=/Users/justinlobaito/.no-mistakes/worktrees/d2386019607f/01M553K4XA5HC576S5GPA46HJK
source <(sed -e '/^test_[a-z0-9_]*$/d' -e "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$WT/tests/lib.sh#" "$WT/tests/fm-teardown.test.sh")
chromes() { ps -axo pid,command | grep -E '[p]uppeteer_dev_chrome_profile' | grep -v -- '--type=' ; }
bridges() { ps -axo pid,command | grep -E '[c]hrome-devtools-axi-bridge' ; }
hr() { printf '\n===== %s =====\n' "$*"; }

hr "S1: worker left a hidden Chrome open in session task-x1; a second unrelated session 'other-sess' is also open"
CHROME_DEVTOOLS_AXI_SESSION=task-x1 chrome-devtools-axi open 'data:text/html,<h1>task-x1</h1>' | head -3
CHROME_DEVTOOLS_AXI_SESSION=other-sess chrome-devtools-axi open 'data:text/html,<h1>other</h1>' | head -3
echo "-- headless Chrome main processes before teardown:"; chromes | cut -c1-160
echo "-- bridges:"; bridges | cut -c1-160

case_dir=$(make_case live-browser-stop); write_meta "$case_dir" no-mistakes ship; land_shippable_commit "$case_dir"
rm -f "$case_dir/fakebin/chrome-devtools-axi"
echo "-- chrome-devtools-axi resolved by teardown: $(PATH="$case_dir/fakebin:$PATH" command -v chrome-devtools-axi)"
rc=0; run_teardown "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
echo "-- teardown exit: $rc"; echo "-- teardown stderr (browser lines):"; grep -i browser "$case_dir/stderr" || echo "(none)"
sleep 2
echo "-- headless Chrome main processes after teardown:"; chromes | cut -c1-160
echo "-- bridges after teardown (task-x1 bridge 1st, other-sess 2nd before):"; bridges | cut -c1-160
echo "-- other-sess still alive? pages:"; CHROME_DEVTOOLS_AXI_SESSION=other-sess chrome-devtools-axi pages 2>&1 | head -4

hr "S2: teardown when task had no browser -> real tool reports no-op, teardown logs nothing"
echo "-- direct real stop output for an idle session:"; CHROME_DEVTOOLS_AXI_SESSION=task-x1 chrome-devtools-axi stop
case_dir=$(make_case live-browser-noop); write_meta "$case_dir" no-mistakes ship; land_shippable_commit "$case_dir"
rm -f "$case_dir/fakebin/chrome-devtools-axi"
rc=0; run_teardown "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
echo "-- teardown exit: $rc"; echo "-- teardown stderr (browser lines):"; grep -i browser "$case_dir/stderr" || echo "(none)"

hr "S3: refused teardown (unpushed work) leaves the task's live browser running"
CHROME_DEVTOOLS_AXI_SESSION=task-x1 chrome-devtools-axi open 'data:text/html,<h1>task-x1-again</h1>' | head -2
before=$(chromes | wc -l | tr -d ' ')
case_dir=$(make_case live-browser-refused); write_meta "$case_dir" no-mistakes ship; wt_commit_file "$case_dir" feature.txt hello "unpushed work"
rm -f "$case_dir/fakebin/chrome-devtools-axi"
rc=0; run_teardown "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
echo "-- teardown exit: $rc (expected 1 = refused)"; grep -i -E 'refus|browser' "$case_dir/stderr" | head -3
sleep 1; after=$(chromes | wc -l | tr -d ' ')
echo "-- Chrome main processes before/after refused teardown: $before/$after"
echo "-- bridges after refusal:"; bridges | wc -l

hr "cleanup: stop both test sessions"
CHROME_DEVTOOLS_AXI_SESSION=task-x1 chrome-devtools-axi stop
CHROME_DEVTOOLS_AXI_SESSION=other-sess chrome-devtools-axi stop
sleep 2; echo "-- leftover Chrome: $(chromes | wc -l | tr -d ' ') bridges: $(bridges | wc -l | tr -d ' ')"
rm -rf "$TMP_ROOT"
