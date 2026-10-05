"""facebench: statistical timing comparison (the RNGs differ, so compare distributions).

Board: the real petBlinkTick / varTick / grok engine via bench (params only).
Port:  CCFaceMotion.blink / variant / grokExpression via the Swift exporter's "stats" mode.
"""
import json, os, subprocess, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from fb import *

N_RUNS = int(os.environ.get("N_RUNS", 40))
DUR = float(os.environ.get("DUR", 120))
SFPS = 50

def onsets(b):
    on = b > 0
    return [i for i in range(len(b)) if on[i] and (i == 0 or not on[i - 1])]

def dwell(seq):
    ch = [i for i in range(1, len(seq)) if seq[i] != seq[i - 1]]
    return ch, [seq[i] for i in [0] + ch]

def ref_runs(skin, st):
    out = []
    d = os.path.join(ROOT, "frames", "stats"); os.makedirs(d, exist_ok=True)
    for k in range(N_RUNS):
        t0 = 2_000_000 + k * 7_919_123
        js = os.path.join(d, f"ref-{skin}-{st}-{k}.jsonl")
        subprocess.run([BENCH, str(SKINS.index(skin)), st, str(t0), str(int(DUR * 1000)), str(SFPS), "-", js], check=True)
        P = [json.loads(l) for l in open(js)]
        out.append(dict(blink=np.array([p["blink"] for p in P]), var=[p["var"] for p in P],
                        grok=[p["grokCur"] for p in P]))
    return out

def port_runs(skin, st):
    d = os.path.join(ROOT, "frames", "stats"); os.makedirs(d, exist_ok=True)
    jobs = os.path.join(d, f"jobs-{skin}-{st}.txt")
    with open(jobs, "w") as f:
        for k in range(N_RUNS):
            f.write(f"{skin} {st} {3000 + k * 977.123:.3f} {DUR} {SFPS} {1000 + k} {d}/port-{skin}-{st}-{k}.txt stats\n")
    subprocess.run([os.path.join(ROOT, "swift", "jobs.sh"), os.path.join(ROOT, "swift", "work"), jobs], check=True)
    out = []
    for k in range(N_RUNS):
        rows = [l.split() for l in open(f"{d}/port-{skin}-{st}-{k}.txt")]
        out.append(dict(blink=np.array([float(r[0]) for r in rows]), var=[int(r[1]) for r in rows],
                        grok=[int(r[2]) for r in rows]))
    return out

def summarize(runs, pill):
    first, gaps, durs, vd, vrep, vuse, gd, guse, grep = [], [], [], [], 0, {}, [], {}, 0
    for r in runs:
        o = onsets(r["blink"])
        if o: first.append(o[0] / SFPS)
        gaps += list(np.diff(o) / SFPS)
        for i in o:
            j = i
            while j < len(r["blink"]) and r["blink"][j] > 0: j += 1
            durs.append((j - i) / SFPS)
        ch, vals = dwell(r["var"])
        vd += list(np.diff([0] + ch) / SFPS)[1:]
        vrep += sum(1 for a, b in zip(vals, vals[1:]) if a == b)
        for v in vals: vuse[v] = vuse.get(v, 0) + 1
        ch, vals = dwell(r["grok"])
        gd += list(np.diff([0] + ch) / SFPS)[1:]
        grep += sum(1 for a, b in zip(vals, vals[1:]) if a == b)
        for v in vals: guse[v] = guse.get(v, 0) + 1
    f = lambda xs: "n=0" if not xs else f"n={len(xs)} mean {np.mean(xs):.2f} min {np.min(xs):.2f} max {np.max(xs):.2f}"
    return {"first blink": f(first), "blink gap": f(gaps), "blink dur": f(durs),
            "variant dwell": f(vd), "variant repeats": vrep, "variant use": dict(sorted(vuse.items())),
            "grok dwell": f(gd), "grok repeats": grep, "grok use": dict(sorted(guse.items()))}

if __name__ == "__main__":
    tag = sys.argv[1]
    sts = sys.argv[2:] or STATES
    lines = []
    for skin in ("classic", "grok"):
        for st in sts:
            R = summarize(ref_runs(skin, st), skin != "grok"); P = summarize(port_runs(skin, st), skin != "grok")
            lines.append(f"== {skin} / {st}")
            for k in R:
                if skin == "grok" and k.startswith("variant"): continue
                if skin != "grok" and k.startswith("grok"): continue
                lines.append(f"  {k:16s} board: {R[k]}\n  {'':16s} port : {P[k]}")
            print("\n".join(lines[-1 - 2 * 6:]), flush=True)
    os.makedirs(f"{ROOT}/out/{tag}", exist_ok=True)
    open(f"{ROOT}/out/{tag}/stats.txt", "w").write("\n".join(lines) + "\n")
