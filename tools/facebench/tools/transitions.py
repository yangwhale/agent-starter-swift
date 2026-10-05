"""facebench: state-change behaviour — the first second after every switch in the tours
(engines re-arm: pool back to V0, blink re-scheduled, grok morphs from what was showing)."""
import os, sys, json
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from fb import *
import port_render as PR
from compare import iou
from geom import comps, match, edge_err

tag = sys.argv[1]
d = f"{ROOT}/frames/gif-{tag}"
tours = [("classic", ["idle", "working", "needs", "done", "off", "listening", "offline", "surprised", "petting", "bored"], 3.0)]
tours += [(sk, ["idle", "working", "needs", "done"], 2.5) for sk in SKINS]
lines = []
for sk, sts, seg in tours:
    raw = f"{d}/{sk}-tour:{int(seg*1000)}:{','.join(sts)}.raw"
    ref = rgb565_to_rgb(np.fromfile(raw, dtype="<u2").reshape(-1, 480, 480))
    rp = [json.loads(l) for l in open(raw.replace(".raw", ".jsonl"))]
    port = PR.load(f"{d}/{sk}-port-{len(sts)}.jsonl")
    for k in range(1, len(sts)):
        i0 = int(round(k * seg * FPS))
        vals, edges = [], []
        for i in range(i0, i0 + int(0.9 * FPS)):
            if rp[i]["blink"] > 0 or port[i]["blink"] > 0: continue
            R = to_gray(ref[i]); P = PR.paint(port[i]["prims"])
            vals.append(iou(R > 0.1, P > 0.1))
            pairs, extra = match(comps(R, 0.02), comps(PR.paint(port[i]["prims"], silhouette=True)))
            edges += [edge_err(r, q) for r, q in pairs if q is not None] + [99] * (len(extra) + sum(q is None for _, q in pairs))
        lines.append(f"{sk:8s} {sts[k-1]:>9s} → {sts[k]:9s} first 0.9 s: IoU min {min(vals):.3f} mean {np.mean(vals):.3f}  "
                     f"edge p50 {np.median(edges):.0f} max {max(edges)}  (n={len(vals)})")
print("\n".join(lines))
open(f"{ROOT}/out/{tag}/transitions.txt", "w").write("\n".join(lines) + "\n")
