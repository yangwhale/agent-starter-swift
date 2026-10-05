"""facebench: contour-level diff — connected components (bbox / area / centroid) per frame."""
import os, sys
import numpy as np
from scipy import ndimage
sys.path.insert(0, os.path.dirname(__file__))
from fb import *
import port_render as PR

def comps(gray, thr=0.5, min_area=6):
    lab, n = ndimage.label(gray > thr, structure=np.ones((3, 3)))   # 8-connected (Bresenham lines)
    out = []
    for k, sl in enumerate(ndimage.find_objects(lab), 1):
        m = lab[sl] == k
        a = int(m.sum())
        if a < min_area:
            continue
        ys, xs = np.nonzero(m)
        out.append(dict(x0=sl[1].start, y0=sl[0].start, x1=sl[1].stop, y1=sl[0].stop, area=a,
                        cx=float(xs.mean() + sl[1].start), cy=float(ys.mean() + sl[0].start)))
    return sorted(out, key=lambda c: (round(c["cy"] / 40), c["cx"]))

def match(rc, pc):
    """greedy nearest-centroid matching; returns pairs + unmatched."""
    pairs, used = [], set()
    for r in sorted(rc, key=lambda c: -c["area"]):
        best = None
        for j, p in enumerate(pc):
            if j in used: continue
            d = (r["cx"] - p["cx"]) ** 2 + (r["cy"] - p["cy"]) ** 2
            if best is None or d < best[0]: best = (d, j)
        if best is not None and best[0] < 60 ** 2:
            used.add(best[1]); pairs.append((r, pc[best[1]]))
        else:
            pairs.append((r, None))
    extra = [p for j, p in enumerate(pc) if j not in used]
    return pairs, extra

def edge_err(r, p):
    return max(abs(r[k] - p[k]) for k in ("x0", "y0", "x1", "y1"))

def fmt(c):
    return f"[{c['x0']:3d},{c['y0']:3d}..{c['x1']:3d},{c['y1']:3d} a{c['area']:5d}]"

if __name__ == "__main__":
    tag, sk, st = sys.argv[1:4]
    idx = [int(x) for x in sys.argv[4].split(",")] if len(sys.argv) > 4 else range(0, 240, 15)
    ref, rp = run_ref(sk, st, dur_ms=8000)
    port = PR.load(f"{ROOT}/frames/port-{tag}/{sk}-{st}.jsonl")
    for i in idx:
        R = to_gray(ref[i]); P = PR.paint(port[i]["prims"], silhouette=True)
        pairs, extra = match(comps(R, 0.02), comps(P))
        print(f"t={i/FPS:5.2f} refblink={rp[i]['blink']:.2f} var={rp[i]['var']} grok={rp[i]['grokCur']} pos={rp[i]['grokPos']:.2f} | "
              f"portblink={port[i]['blink']:.2f} grok={port[i]['grok']} bob={port[i]['bob']:.1f} gx={port[i]['gx']:.1f}")
        for r, p in pairs:
            print("   ", fmt(r), "->", fmt(p) if p else "MISSING", f"err {edge_err(r,p)}" if p else "")
        for p in extra:
            print("    EXTRA in port", fmt(p))
