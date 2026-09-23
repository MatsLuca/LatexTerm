#!/usr/bin/env python3
"""statelog — samples `latexterm list-panes --json` every 100 ms and appends every change as
one JSON line {t: unix-ms, panes: [...]} to <out.jsonl>. Stage directions go into the same
file via `mark.sh NAME` ({t, mark}). The cutter (src/clips/cutlist.ts) turns this into edits:
long `working` stretches are dropped, pane births and turn ends are kept.
Usage: statelog.py <out.jsonl> [--window-id N]   (stop with SIGINT/SIGTERM)"""
import json, signal, subprocess, sys, time

out, win = sys.argv[1], None
if "--window-id" in sys.argv:
    win = sys.argv[sys.argv.index("--window-id") + 1]
running = True
signal.signal(signal.SIGTERM, lambda *_: globals().update(running=False))
signal.signal(signal.SIGINT, lambda *_: globals().update(running=False))
last = None
with open(out, "a") as f:
    while running:
        try:
            d = json.loads(subprocess.run(["latexterm", "list-panes", "--json"], capture_output=True, text=True, timeout=2).stdout)
            panes = [
                {k: p.get(k) for k in ("index", "id", "kind", "state", "title", "focused", "zoomed", "agent")}
                for p in d.get("panes", []) if win is None or p.get("windowID") == win
            ]
        except Exception:
            panes = None
        if panes is not None and panes != last:
            f.write(json.dumps({"t": int(time.time() * 1000), "panes": panes}) + "\n"); f.flush()
            last = panes
        time.sleep(0.1)
