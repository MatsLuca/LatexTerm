#!/usr/bin/env python3
"""cut — turns a take's state log into an edit decision list for Remotion.

Scenes are what lies between `mark in:NAME` and `mark out`. Inside a scene every stretch in
which an agent pane is `working` is squeezed: we keep its first KEEP_HEAD seconds (the prompt
lands, the spinner starts), KEEP_TAIL seconds before it ends (the answer arrives) and a window
around every moment a pane is born or changes kind (Claude opening a tile is the story).
Everything else in the working stretch is dropped, so Claude seems to answer instantly.

Usage: cut.py TAKE [--head 0.7] [--tail 2.6]   (TAKE = recordings/takes/NAME, no extension)
Writes TAKE.cuts.json: {fps, scenes: [{name, segments: [[from_s, to_s], ...]}]}"""
import json, sys

take = sys.argv[1]
def arg(name, default):
    return float(sys.argv[sys.argv.index(name) + 1]) if name in sys.argv else default
KEEP_HEAD, KEEP_TAIL = arg("--head", 0.7), arg("--tail", 2.6)
EVENT_BEFORE, EVENT_AFTER = 0.4, 2.2

meta = json.load(open(take + ".mov.json"))
t0, fps = meta["t0"], meta["fps"]
events = [json.loads(l) for l in open(take + ".jsonl")]
for e in events:
    e["s"] = (e["t"] - t0) / 1000

# working stretches (any agent pane working) and pane births/kind changes
working, births, cur, seen = [], [], None, {}
for e in (e for e in events if "panes" in e):
    busy = any(p.get("state") == "working" for p in e["panes"])
    if busy and cur is None: cur = e["s"]
    if not busy and cur is not None: working.append((cur, e["s"])); cur = None
    for p in e["panes"]:
        if seen.get(p["id"]) != p["kind"]:
            if p["id"] in seen or len(seen) > 0: births.append(e["s"])
            seen[p["id"]] = p["kind"]
if cur is not None: working.append((cur, events[-1]["s"]))

def keep_ranges(a, b):
    """Parts of [a, b] to keep, given the working stretches."""
    drops = []
    for ws, we in working:
        lo, hi = max(a, ws + KEEP_HEAD), min(b, we - KEEP_TAIL)
        if hi - lo > 0.5: drops.append([lo, hi])
    # never drop around a birth
    for bt in births:
        nd = []
        for lo, hi in drops:
            if bt + EVENT_AFTER <= lo or bt - EVENT_BEFORE >= hi: nd.append([lo, hi]); continue
            if bt - EVENT_BEFORE - lo > 0.5: nd.append([lo, bt - EVENT_BEFORE])
            if hi - (bt + EVENT_AFTER) > 0.5: nd.append([bt + EVENT_AFTER, hi])
        drops = nd
    out, pos = [], a
    for lo, hi in sorted(drops):
        if lo > pos: out.append([round(pos, 3), round(lo, 3)])
        pos = max(pos, hi)
    if b > pos: out.append([round(pos, 3), round(b, 3)])
    return out

scenes, open_ = [], None
for e in (e for e in events if "mark" in e):
    m = e["mark"]
    if m.startswith("in:"): open_ = (m[3:], e["s"])
    elif m == "out" and open_:
        scenes.append({"name": open_[0], "segments": keep_ranges(open_[1], e["s"])}); open_ = None

json.dump({"fps": fps, "scenes": scenes}, open(take + ".cuts.json", "w"), indent=1)
for sc in scenes:
    dur = sum(b - a for a, b in sc["segments"])
    print(f"{sc['name']:>10}: {len(sc['segments'])} segments, {dur:5.1f}s  {sc['segments']}")
