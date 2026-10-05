"""facebench: rasterise CCFaceMotion draw lists exactly the way CCFacePainter does.

Mirrors VoiceAgent/CloseCrab/CCFaceGlyph.swift → CCFacePainter.paint / shape():
  * every prim becomes a Path in 480-space, scaled by side/480;
  * ink → mask alpha via CCFaceMask.alpha (exported alongside each prim);
  * CCFaceMask.replaces(ink): destinationOut with opacity (1 − a)  → dst *= 1 − (1−a)·cov
  * .line: stroke, width max(0.6, 1.5·s), butt caps                → source-over a·cov
  * everything else: fill (even-odd), source-over                   → dst = a·cov + dst·(1 − a·cov)
  * roundRect: corner radius clamped to [0, min(w/2, h/2)], circular corners
  * arc: 33 points along the outer radius, back along the inner one (not addArc)
  * pill: rounded rect (−len/2, −thick/2, len, thick, r = thick/2) rotated by deg
    with CGAffineTransform(rotationAngle:) (y-down) then translated to (cx, cy)
Anti-aliasing is approximated by 4×4 supersampling per primitive.
"""
import json, math
import numpy as np
from PIL import Image, ImageDraw

SS = 4

def rr_poly(x, y, w, h, r, seg=12):
    r = max(0.0, min(r, w / 2, h / 2))
    if r <= 0:
        return [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
    pts = []
    for cx, cy, a0 in ((x + w - r, y + r, -90), (x + w - r, y + h - r, 0), (x + r, y + h - r, 90), (x + r, y + r, 180)):
        for k in range(seg + 1):
            a = math.radians(a0 + 90 * k / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts

def circle_poly(cx, cy, r, seg=64):
    return [(cx + r * math.cos(2 * math.pi * k / seg), cy + r * math.sin(2 * math.pi * k / seg)) for k in range(seg)]

def arc_poly(cx, cy, r1, r2, a_from, a_to, n=32):
    ro, ri = max(r1, r2), min(r1, r2)
    pts = []
    for k in range(n + 1):
        a = math.radians(a_from + (a_to - a_from) * k / n)
        pts.append((cx + ro * math.cos(a), cy + ro * math.sin(a)))
    for k in range(n, -1, -1):
        a = math.radians(a_from + (a_to - a_from) * k / n)
        pts.append((cx + ri * math.cos(a), cy + ri * math.sin(a)))
    return pts

def pill_poly(cx, cy, ln, th, deg):
    base = rr_poly(-ln / 2, -th / 2, ln, th, th / 2)
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [(px * c - py * s + cx, px * s + py * c + cy) for px, py in base]

def line_poly(x0, y0, x1, y1, width):
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy) or 1
    nx, ny = -dy / L * width / 2, dx / L * width / 2
    return [(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)]

def prim_shape(p, s):
    k = p[0]
    if k == "rr":
        return rr_poly(*p[1:6]), p[6:]
    if k == "rect":
        x, y, w, h = p[1:5]
        return [(x, y), (x + w, y), (x + w, y + h), (x, y + h)], p[5:]
    if k == "tri":
        return [(p[1], p[2]), (p[3], p[4]), (p[5], p[6])], p[7:]
    if k == "circle":
        return circle_poly(*p[1:4]), p[4:]
    if k == "arc":
        return arc_poly(*p[1:7]), p[7:]
    if k == "pill":
        return pill_poly(*p[1:6]), p[6:]
    if k == "line":
        return line_poly(*p[1:5], max(0.6, 1.5 * s) / s), p[5:]
    if k == "poly":
        xy = p[1]
        return [(xy[2 * i], xy[2 * i + 1]) for i in range(len(xy) // 2)], p[2:]
    raise ValueError(k)

def coverage(poly, side):
    s = side / 480.0
    pts = [(x * s, y * s) for x, y in poly]
    xs = [q[0] for q in pts]; ys = [q[1] for q in pts]
    x0 = max(0, int(math.floor(min(xs)))); y0 = max(0, int(math.floor(min(ys))))
    x1 = min(side, int(math.ceil(max(xs))) + 1); y1 = min(side, int(math.ceil(max(ys))) + 1)
    if x1 <= x0 or y1 <= y0:
        return None
    w, h = x1 - x0, y1 - y0
    im = Image.new("L", (w * SS, h * SS), 0)
    ImageDraw.Draw(im).polygon([((x - x0) * SS, (y - y0) * SS) for x, y in pts], fill=255)
    a = np.asarray(im, np.float32).reshape(h, SS, w, SS).mean((1, 3)) / 255.0
    return (x0, y0, x1, y1), a

def paint(prims, side=480, silhouette=False):
    """silhouette=True: pure shape — every stroke fully opaque, only the true cuts (tone "cut")
    punch holes. Used for contour comparison against the board's non-black pixels."""
    dst = np.zeros((side, side), np.float32)
    s = side / 480.0
    for p in prims:
        poly, ink = prim_shape(p, s)
        _tone, _level, alpha, replaces = ink
        if silhouette:
            alpha = 0.0 if _tone == "cut" else 1.0
            replaces = _tone == "cut"
        c = coverage(poly, side)
        if c is None:
            continue
        (x0, y0, x1, y1), cov = c
        d = dst[y0:y1, x0:x1]
        if replaces:
            d *= 1 - (1 - alpha) * cov
        else:
            d[:] = alpha * cov + d * (1 - alpha * cov)
    return dst

def load(path):
    return [json.loads(l) for l in open(path)]
