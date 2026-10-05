"""facebench: reference (AgentTouch face.cpp via bench) vs port (CCFaceMotion → CCFacePainter mirror).

python3 compare.py <round-tag> [skins...]
Writes out/<tag>/summary.txt, per-combo key-frame sheets with diff overlays, and metrics.json.
"""
import json, os, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw
sys.path.insert(0, os.path.dirname(__file__))
from fb import *
import port_render as PR
from geom import comps, match, edge_err

SWIFT_W = os.path.join(ROOT, "swift", "work")
SEED = 1
DUR = 8.0
# first switch of the pill-skin pool can't come before cadence lo (needs: ≥3 s)
POOL_LO = {"idle": 8, "working": 2.2, "needs": 3, "done": 1.2, "bored": 6}
GROK_LO = {"off": 6, "idle": 8, "working": 2.2, "needs": 1.6, "done": 1.2, "listening": 2.5,
           "bored": 6, "surprised": 0.9, "petting": 1.5, "offline": 5}

def export_all(combos, tag):
    d = os.path.join(ROOT, "frames", "port-" + tag); os.makedirs(d, exist_ok=True)
    jobs = os.path.join(ROOT, "frames", f"jobs-{tag}.txt")
    with open(jobs, "w") as f:
        for sk, st in combos:
            f.write(f"{sk} {st} {T0/1000:.3f} {DUR} {FPS} {SEED} {d}/{sk}-{st}.jsonl\n")
    subprocess.run([os.path.join(ROOT, "swift", "jobs.sh"), SWIFT_W, jobs], check=True)
    return d

def iou(a, b):
    u = (a | b).sum()
    return 1.0 if u == 0 else (a & b).sum() / u

def overlay(ref, port):
    """white = both, red = only the board, cyan = only the port."""
    A, B = ref > 0.1, port > 0.1
    o = np.zeros(ref.shape + (3,), np.uint8)
    o[A & B] = (230, 230, 230); o[A & ~B] = (255, 60, 60); o[~A & B] = (60, 220, 255)
    return o

def main():
    tag = sys.argv[1]
    skins = sys.argv[2:] or SKINS
    combos = [(sk, st) for sk in skins for st in STATES]
    pdir = export_all(combos, tag)
    odir = os.path.join(ROOT, "out", tag); os.makedirs(odir, exist_ok=True)
    metrics = {}
    lines = []
    for sk, st in combos:
        ref, rp = run_ref(sk, st, dur_ms=int(DUR * 1000))
        port = PR.load(f"{pdir}/{sk}-{st}.jsonl")
        n = min(len(ref), len(port))
        ious, det, edges, missing = [], [], [], 0
        lo = GROK_LO.get(st, 99) if sk == "grok" else POOL_LO.get(st, 99)
        for i in range(n):
            R = to_gray(ref[i]); P = PR.paint(port[i]["prims"])
            v = iou(R > 0.1, P > 0.1); ious.append(v)
            t = i / FPS
            if rp[i]["blink"] == 0 and port[i]["blink"] == 0 and t < lo:
                det.append(v)
                if i % 3 == 0:     # contour check on every 3rd deterministic frame (it is slow)
                    pairs, extra = match(comps(R, 0.02), comps(PR.paint(port[i]["prims"], silhouette=True)))
                    missing += sum(1 for _, q in pairs if q is None) + len(extra)
                    edges += [edge_err(r, q) for r, q in pairs if q is not None]
        m = {"mean": float(np.mean(ious)), "min": float(np.min(ious)), "argmin": int(np.argmin(ious)),
             "det_mean": float(np.mean(det)) if det else None, "det_min": float(np.min(det)) if det else None,
             "det_n": len(det), "edge_max": int(max(edges)) if edges else None,
             "edge_p95": float(np.percentile(edges, 95)) if edges else None, "unmatched": missing}
        metrics[f"{sk}-{st}"] = m
        lines.append(f"{sk:8s} {st:10s} mean {m['mean']:.3f} min {m['min']:.3f}@{m['argmin']/FPS:.2f}s  "
                     f"deterministic(n={m['det_n']}) mean {m['det_mean'] if m['det_mean'] is None else round(m['det_mean'],3)} "
                     f"min {m['det_min'] if m['det_min'] is None else round(m['det_min'],3)}  "
                     f"contour edge max {m['edge_max']}px p95 {m['edge_p95']} unmatched {m['unmatched']}")
        # key frames: 0, .5, 1, 2, 4, 6 s and the worst frame
        keys = [int(round(s * FPS)) for s in (0, 0.5, 1, 2, 4, 6)] + [m["argmin"]]
        tiles = []
        for i in keys:
            i = min(i, n - 1)
            R = to_gray(ref[i]); P = PR.paint(port[i]["prims"])
            tiles += [(R * 255).astype(np.uint8), (P * 255).astype(np.uint8), overlay(R, P)]
        tiles = [np.stack([t] * 3, -1) if t.ndim == 2 else t for t in tiles]
        labels = []
        for i in keys:
            labels += [f"board t={i/FPS:.2f}", "port", "diff red=board cyan=port"]
        sheet(tiles, 6, 0.35, labels).save(f"{odir}/{sk}-{st}.png")
    open(f"{odir}/summary.txt", "w").write("\n".join(lines) + "\n")
    json.dump(metrics, open(f"{odir}/metrics.json", "w"), indent=1)
    print("\n".join(lines))

if __name__ == "__main__":
    main()
