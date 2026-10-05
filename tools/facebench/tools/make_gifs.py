"""facebench: the two side-by-side GIFs for review (board | port).

  python3 make_gifs.py <tag>
out/<tag>/classic-tour.gif  : classic, every face state back to back
out/<tag>/skins-tour.gif    : six skins, idle → working → needs → done
The port side is the face mask (white = opaque); in the app that mask shows the
room's identity-colour metal (colour/material are deliberately not ported).
"""
import os, subprocess, sys, glob
import numpy as np
from PIL import Image, ImageDraw, ImageFont
sys.path.insert(0, os.path.dirname(__file__))
from fb import *
import port_render as PR

FONT = next(iter(glob.glob("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc")
                 + glob.glob("/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc")), None)
ZH = {"idle": "空闲", "working": "在查东西", "needs": "等你回话", "done": "刚干完", "off": "睡着",
      "listening": "在听你说", "offline": "迷糊找人", "surprised": "被拿起来*", "petting": "在说话（借被摸）",
      "bored": "没人理*"}

def font(sz):
    return ImageFont.truetype(FONT, sz) if FONT else ImageFont.load_default()

def port_tour(skin, states, seg_s, dur_s, tag):
    d = os.path.join(ROOT, "frames", "gif-" + tag); os.makedirs(d, exist_ok=True)
    of = f"{d}/{skin}-port-{len(states)}.jsonl"
    jobs = f"{d}/jobs-{skin}.txt"
    open(jobs, "w").write(f"{skin} tour:{seg_s}:{','.join(states)} {T0/1000:.3f} {dur_s} {FPS} 1 {of}\n")
    subprocess.run([os.path.join(ROOT, "swift", "jobs.sh"), os.path.join(ROOT, "swift", "work"), jobs], check=True)
    return PR.load(of)

def frames_pair(skin, states, seg_s, dur_s, tag, step=2):
    ref, _ = run_ref(skin, f"tour:{int(seg_s*1000)}:{','.join(states)}", dur_ms=int(dur_s * 1000), tag="gif-" + tag)
    port = port_tour(skin, states, seg_s, dur_s, tag)
    out = []
    for i in range(0, min(len(ref), len(port)), step):
        R = ref[i]
        P = (PR.paint(port[i]["prims"]) * 255).astype(np.uint8)
        out.append((R, np.stack([P] * 3, -1), states[min(int(i / FPS / seg_s), len(states) - 1)]))
    return out

def crop(a, y0=40, y1=410):
    return a[y0:y1]

def classic_tour(tag):
    sts = ["idle", "working", "needs", "done", "off", "listening", "offline", "surprised", "petting", "bored"]
    fr = frames_pair("classic", sts, 3.0, 30.0, tag)
    sc = 0.6; W = int(480 * sc); H = int(370 * sc)
    ims = []
    for R, P, st in fr:
        im = Image.new("RGB", (2 * W + 12, H + 64), (24, 24, 28))
        im.paste(Image.fromarray(crop(R)).resize((W, H), Image.BILINEAR), (0, 34))
        im.paste(Image.fromarray(crop(P)).resize((W, H), Image.BILINEAR), (W + 12, 34))
        d = ImageDraw.Draw(im)
        d.text((8, 6), "原版 AgentTouch（face.cpp 真代码）", fill=(255, 190, 90), font=font(15))
        d.text((W + 20, 6), "移植 CCFaceMotion（遮罩）", fill=(120, 210, 255), font=font(15))
        d.text((8, H + 38), f"classic · {st} · {ZH[st]}", fill=(230, 230, 230), font=font(16))
        ims.append(im)
    fn = f"{ROOT}/out/{tag}/classic-tour.gif"
    ims[0].save(fn, save_all=True, append_images=ims[1:], duration=int(1000 / FPS * 2), loop=0, optimize=True)
    return fn

def skins_tour(tag):
    sts = ["idle", "working", "needs", "done"]
    per = {sk: frames_pair(sk, sts, 2.5, 10.0, tag) for sk in SKINS}
    sc = 0.36; W = int(480 * sc); H = int(420 * sc)
    n = min(len(v) for v in per.values())
    ims = []
    for i in range(n):
        im = Image.new("RGB", (3 * (2 * W + 6) + 2 * 16, 2 * (H + 26) + 40), (24, 24, 28))
        d = ImageDraw.Draw(im)
        st = per["classic"][i][2]
        d.text((8, 8), f"左＝原版  右＝移植    {st} · {ZH[st]}", fill=(230, 230, 230), font=font(16))
        for k, sk in enumerate(SKINS):
            R, P, _ = per[sk][i]
            x = (k % 3) * (2 * W + 6 + 16); y = 40 + (k // 3) * (H + 26)
            im.paste(Image.fromarray(R[20:440]).resize((W, H), Image.BILINEAR), (x, y + 20))
            im.paste(Image.fromarray(P[20:440]).resize((W, H), Image.BILINEAR), (x + W + 6, y + 20))
            d.text((x + 2, y + 2), sk, fill=(255, 190, 90), font=font(14))
        ims.append(im)
    fn = f"{ROOT}/out/{tag}/skins-tour.gif"
    ims[0].save(fn, save_all=True, append_images=ims[1:], duration=int(1000 / FPS * 2), loop=0, optimize=True)
    return fn

if __name__ == "__main__":
    tag = sys.argv[1]
    os.makedirs(f"{ROOT}/out/{tag}", exist_ok=True)
    print(classic_tour(tag)); print(skins_tour(tag))
