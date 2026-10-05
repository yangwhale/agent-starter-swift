"""facebench: zoomed side-by-side crop (board | port | diff) for one frame."""
import os, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(__file__))
from fb import *
import port_render as PR
from compare import overlay

tag, sk, st, i = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
x0, y0, x1, y1 = [int(v) for v in sys.argv[5].split(",")] if len(sys.argv) > 5 else (0, 0, 480, 480)
z = int(sys.argv[6]) if len(sys.argv) > 6 else 2
ref, rp = run_ref(sk, st, dur_ms=(i + 1) * 50)
port = PR.load(f"{ROOT}/frames/port-{tag}/{sk}-{st}.jsonl")
R = to_gray(ref[i]); P = PR.paint(port[i]["prims"])
tiles = [np.stack([R * 255] * 3, -1).astype(np.uint8), np.stack([P * 255] * 3, -1).astype(np.uint8), overlay(R, P)]
crops = [Image.fromarray(t[y0:y1, x0:x1]).resize(((x1 - x0) * z, (y1 - y0) * z), Image.NEAREST) for t in tiles]
w, h = crops[0].size
out = Image.new("RGB", (w * 3 + 8, h), (90, 90, 0))
for k, c in enumerate(crops): out.paste(c, (k * (w + 4), 0))
os.makedirs(f"{ROOT}/out/{tag}/zoom", exist_ok=True)
fn = f"{ROOT}/out/{tag}/zoom/{sk}-{st}-{i}.png"; out.save(fn); print(fn)
