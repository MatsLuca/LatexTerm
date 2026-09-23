#!/usr/bin/env python3
"""sketch — draws a hand-made looking figure with rig/input: polylines get jitter and a slight
wobble, circles are drawn as one loose stroke. Shapes are given in window points; DY maps
them to screen (window top). Usage: sketch.py FIGURE [--dy 34]"""
import math, random, subprocess, sys, os
R = os.path.dirname(os.path.abspath(__file__))
DY = float(sys.argv[sys.argv.index("--dy") + 1]) if "--dy" in sys.argv else 34
random.seed(7)

def stroke(pts, ms=None):
    out = []
    for i in range(len(pts) - 1):
        (x1, y1), (x2, y2) = pts[i], pts[i + 1]
        n = max(2, int(math.hypot(x2 - x1, y2 - y1) / 14))
        for k in range(n):
            t = k / n
            out.append((x1 + (x2 - x1) * t + random.uniform(-1.3, 1.3), y1 + (y2 - y1) * t + random.uniform(-1.3, 1.3)))
    out.append(pts[-1])
    length = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:]))
    ms = ms or max(260, length * 2.6)
    subprocess.run([R + "/input", "drag", str(int(ms))] + [f"{x:.1f},{y + DY:.1f}" for x, y in out])

def circle(cx, cy, r):
    pts = [(cx + r * math.cos(a) * random.uniform(0.95, 1.05), cy + r * math.sin(a) * random.uniform(0.95, 1.05))
           for a in [(-math.pi / 2 + i * 2 * math.pi / 22) for i in range(24)]]
    stroke(pts, 520)

def arrow(x1, y1, x2, y2):
    stroke([(x1, y1), (x2, y2)])
    a = math.atan2(y2 - y1, x2 - x1)
    for s in (+1, -1):
        stroke([(x2, y2), (x2 - 14 * math.cos(a + s * 0.5), y2 - 14 * math.sin(a + s * 0.5))], 140)

def box(x, y, w, h):
    stroke([(x, y), (x + w, y + 2), (x + w - 1, y + h), (x + 1, y + h - 1), (x, y)], 900)

def letter(ch, x, y, s=22):
    L = {"C": [[(x + s * .8, y + s * .15), (x + s * .3, y), (x, y + s * .5), (x + s * .3, y + s), (x + s * .8, y + s * .85)]],
         "G": [[(x + s * .8, y + s * .15), (x + s * .3, y), (x, y + s * .5), (x + s * .3, y + s), (x + s * .8, y + s * .8), (x + s * .8, y + s * .55), (x + s * .5, y + s * .55)]],
         "r": [[(x, y + s * .35), (x, y + s)], [(x, y + s * .55), (x + s * .3, y + s * .35), (x + s * .6, y + s * .38)]],
         "y": [[(x, y + s * .35), (x + s * .3, y + s * .8)], [(x + s * .6, y + s * .35), (x + s * .15, y + s * 1.25)]],
         "-": [[(x, y), (x + s * .5, y)]]}
    for p in L[ch]: stroke(p, 260)

fig = sys.argv[1]
if fig == "loop":
    Y = 360
    arrow(820, Y, 905, Y); letter("r", 830, Y - 40)
    circle(930, Y, 24)
    arrow(955, Y, 1010, Y)
    box(1012, Y - 38, 96, 76); letter("C", 1048, Y - 12)
    arrow(1108, Y, 1180, Y)
    box(1182, Y - 38, 96, 76); letter("G", 1218, Y - 12)
    arrow(1278, Y, 1430, Y); letter("y", 1400, Y - 44)
    stroke([(1360, Y), (1362, Y + 150), (930, Y + 152)])
    arrow(930, Y + 152, 930, Y + 26); letter("-", 900, Y + 40, 26)
