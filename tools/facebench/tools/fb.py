"""facebench shared helpers: run the reference bench, load frames, compose images."""
import json, os, subprocess
import numpy as np
from PIL import Image

ROOT = os.environ.get("FACEBENCH", "/tmp/facebench")
BENCH = os.path.join(ROOT, "build", "bench")
SKINS = ["classic", "kitty", "robo", "bunny", "sprout", "grok"]
STATES = ["idle", "working", "needs", "done", "off", "listening", "offline",
          "surprised", "petting", "bored"]
T0 = 1_000_000          # ms; "fixed seed" for the reference (its RNGs seed from millis)
FPS = 30          # the board renders at ~30 fps (main.cpp: now - lastFrame >= 33)

def rgb565_to_rgb(a):
    r = ((a >> 11) & 0x1F).astype(np.uint16); g = ((a >> 5) & 0x3F).astype(np.uint16); b = (a & 0x1F).astype(np.uint16)
    return np.stack([(r * 255 + 15) // 31, (g * 255 + 31) // 63, (b * 255 + 15) // 31], -1).astype(np.uint8)

def run_ref(skin, state, dur_ms=8000, fps=FPS, t0=T0, tag="ref"):
    d = os.path.join(ROOT, "frames", tag); os.makedirs(d, exist_ok=True)
    raw = os.path.join(d, f"{skin}-{state}.raw"); js = os.path.join(d, f"{skin}-{state}.jsonl")
    subprocess.run([BENCH, str(SKINS.index(skin)), state, str(t0), str(dur_ms), str(fps), raw, js], check=True)
    a = np.fromfile(raw, dtype="<u2").reshape(-1, 480, 480)
    params = [json.loads(l) for l in open(js)]
    return rgb565_to_rgb(a), params

def to_gray(rgb):
    return rgb.astype(np.float32).max(-1) / 255.0

def sheet(frames, cols, scale=0.5, labels=None):
    from PIL import ImageDraw
    ims = [Image.fromarray(f).resize((int(480 * scale), int(480 * scale)), Image.BILINEAR) for f in frames]
    w, h = ims[0].size
    rows = (len(ims) + cols - 1) // cols
    out = Image.new("RGB", (cols * w, rows * h), (40, 40, 40))
    dr = ImageDraw.Draw(out)
    for i, im in enumerate(ims):
        x, y = (i % cols) * w, (i // cols) * h
        out.paste(im, (x, y))
        dr.rectangle([x, y, x + w - 1, y + h - 1], outline=(70, 70, 70))
        if labels: dr.text((x + 4, y + 4), labels[i], fill=(255, 200, 0))
    return out
