"""facebench: eye-feature timelines, board vs port (left eye: top, bottom, centre x, area)."""
import os, sys
import numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
sys.path.insert(0, os.path.dirname(__file__))
from fb import *
import port_render as PR
from geom import comps

def left_eye(gray):
    cs = [c for c in comps(gray) if c["cx"] < 240 and 150 < c["cy"] < 330 and c["area"] > 150]
    if not cs: return (np.nan,) * 4
    c = max(cs, key=lambda c: c["area"])
    return c["y0"], c["y1"], c["cx"], c["area"]

def series(tag, sk, st, dur_ms=8000):
    ref, rp = run_ref(sk, st, dur_ms=dur_ms)
    port = PR.load(f"{ROOT}/frames/port-{tag}/{sk}-{st}.jsonl")
    n = min(len(ref), len(port))
    R = np.array([left_eye(to_gray(ref[i])) for i in range(n)], float)
    P = np.array([left_eye(PR.paint(port[i]["prims"])) for i in range(n)], float)
    rb = np.array([rp[i]["blink"] for i in range(n)]); pb = np.array([port[i]["blink"] for i in range(n)])
    return R, P, rb, pb, rp, port

def plot(tag, sk, st, out):
    R, P, rb, pb, rp, port = series(tag, sk, st)
    t = np.arange(len(R)) / FPS
    fig, ax = plt.subplots(4, 1, figsize=(10, 8), sharex=True)
    for k, name in enumerate(["top y", "bottom y", "centre x", "area"]):
        ax[k].plot(t, R[:, k], "-", color="#d33", label="board", lw=1.4)
        ax[k].plot(t, P[:, k], "--", color="#09c", label="port", lw=1.2)
        ax[k].set_ylabel(name)
        for arr, c in ((rb, "#d33"), (pb, "#09c")):
            on = arr > 0
            ax[k].fill_between(t, 0, 1, where=on, color=c, alpha=0.08, transform=ax[k].get_xaxis_transform())
    ax[0].legend(loc="upper right"); ax[-1].set_xlabel("s")
    fig.suptitle(f"{sk} / {st}  (shaded = blinking)")
    fig.tight_layout(); fig.savefig(out, dpi=80); plt.close(fig)

if __name__ == "__main__":
    tag = sys.argv[1]; sk = sys.argv[2]; sts = sys.argv[3:] or STATES
    od = f"{ROOT}/out/{tag}/timeline"; os.makedirs(od, exist_ok=True)
    for st in sts:
        plot(tag, sk, st, f"{od}/{sk}-{st}.png")
