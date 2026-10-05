"""facebench: grok morph spring — board's per-frame s_pos vs the port's spring(), aligned at the switch.
The board integrates inside the switch frame, so frame k after the switch is compared with spring(k/fps)."""
import json, os, subprocess, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from fb import *

for fps in (30, 20):
    d = os.path.join(ROOT, "frames", "spring"); os.makedirs(d, exist_ok=True)
    js = os.path.join(d, f"ref{fps}.jsonl")
    subprocess.run([BENCH, "5", "done", "3000000", "60000", str(fps), "-", js], check=True)
    P = [json.loads(l) for l in open(js)]
    g = [p["grokCur"] for p in P]; pos = [p["grokPos"] for p in P]
    curves = [pos[i:i + 16] for i in range(1, len(g) - 16) if g[i] != g[i - 1]]
    board = np.mean(curves, 0)
    port = subprocess.run(["docker", "run", "--rm", "-v", f"{ROOT}/swift/work:/w", "-w", "/w", "swift:6.2-noble",
                           "./export", "spring", str(fps)], check=True, capture_output=True, text=True).stdout.split()
    port = np.array([float(x) for x in port])
    print(f"fps {fps}  (n={len(curves)} switches)")
    print("  board:", " ".join(f"{v:.3f}" for v in board))
    print("  port :", " ".join(f"{v:.3f}" for v in port))
    print(f"  max |diff| {np.abs(board - port).max():.4f}   board peak {board.max():.4f}  port peak {port.max():.4f}")
