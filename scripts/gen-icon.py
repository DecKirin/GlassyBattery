# Generates GlassyBattery.icon: an abstract device card from the dropdown (glass capsule +
# battery level + bolt badge) with a progressive blur toward the edges.
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import os, json, math, shutil

OUT = 1024
SS = 2
W = OUT * SS
def p(v): return v * SS          # icon points -> supersampled px

ROOT = "GlassyBattery.icon"; A = f"{ROOT}/Assets"
shutil.rmtree(ROOT, ignore_errors=True); os.makedirs(A)

GREEN = (80, 200, 104); GREEN_HI = (150, 230, 160)
TRACK = (240, 242, 245); RIM = (232, 234, 238); INK = (28, 30, 34)

def rrect(d, box, fill, r=None, **kw):
    x0, y0, x1, y1 = map(p, box)
    d.rounded_rectangle([x0, y0, x1, y1], radius=p(r) if r is not None else (y1 - y0) / 2, fill=fill, **kw)

def gloss(img, box, r=None, strength=90):
    x0, y0, x1, y1 = map(p, box)
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([x0, y0, x1, y1], radius=p(r) if r is not None else (y1 - y0) / 2, fill=255)
    g = Image.new("L", img.size, 0); gd = ImageDraw.Draw(g); h = y1 - y0
    for i in range(int(h * 0.5)):
        gd.line([(x0, y0 + i), (x1, y0 + i)], fill=int(strength * (1 - i / (h * 0.5)) ** 1.8))
    img.paste((255, 255, 255), (0, 0), ImageChops.multiply(m, g))

def bolt(d, cx, cy, s, fill):
    pts = [(0.10, -0.50), (-0.32, 0.08), (-0.02, 0.08), (-0.12, 0.50), (0.32, -0.10), (0.02, -0.10)]
    d.polygon([(p(cx + x * s), p(cy + y * s)) for x, y in pts], fill=fill)

BOLTS = []
def card(img, x0, y0, x1, y1, level, badge=True):
    d = ImageDraw.Draw(img); h = y1 - y0
    rrect(d, (x0 - 12, y0 - 12, x1 + 12, y1 + 12), RIM)
    rrect(d, (x0, y0, x1, y1), TRACK)
    rrect(d, (x0, y0, x0 + max((x1 - x0) * level, h), y1), GREEN, outline=GREEN_HI, width=p(5))
    gloss(img, (x0, y0, x1, y1), None, 80)
    d = ImageDraw.Draw(img)
    # abstract "title / subtitle" bars instead of text
    rrect(d, (x0 + h * 0.42, y0 + h * 0.30, x0 + h * 0.42 + (x1 - x0) * 0.40, y0 + h * 0.30 + h * 0.15), (*INK,))
    rrect(d, (x0 + h * 0.42, y0 + h * 0.57, x0 + h * 0.42 + (x1 - x0) * 0.24, y0 + h * 0.57 + h * 0.10), (40, 110, 55))
    if badge:
        bx0, by0 = x0 + h * 0.10, y0 - h * 0.34
        bx1, by1 = bx0 + h * 0.78, by0 + h * 0.50
        rrect(d, (bx0 - 8, by0 - 8, bx1 + 8, by1 + 8), (248, 251, 249))
        rrect(d, (bx0, by0, bx1, by1), (180, 230, 190))
        gloss(img, (bx0, by0, bx1, by1), None, 120)
        bolt(ImageDraw.Draw(img), (bx0 + bx1) / 2, (by0 + by1) / 2, (by1 - by0) * 0.72, INK)
        BOLTS.append(((bx0 + bx1) / 2, (by0 + by1) / 2, (by1 - by0) * 0.72))
    return (x0 - 12, y0 - 12, x1 + 12, y1 + 12), ((bx0 - 8, by0 - 8, bx1 + 8, by1 + 8) if badge else None)

# ---------- scene ----------
img = Image.new("RGB", (W, W)); bd = ImageDraw.Draw(img)
for y in range(W):
    t = y / W
    bd.line([(0, y), (W, y)], fill=(int(246 - 16 * t), int(247 - 13 * t), int(250 - 10 * t)))

main_card, main_badge = card(img, 137, 440, 887, 680, 0.80)

# ---------- progressive blur ----------
FX, FY = p(512), p(530)
def dist_mask(r0, r1, sx=0.85, sy=1.3):
    step = 8; n = W // step
    small = Image.new("L", (n, n)); sd = small.load()
    for j in range(n):
        for i in range(n):
            t = (math.hypot((i * step - FX) * sx, (j * step - FY) * sy) - r0) / (r1 - r0)
            sd[i, j] = int(255 * min(1, max(0, t)))
    return small.resize((W, W), Image.BILINEAR)

levels = [img.filter(ImageFilter.GaussianBlur(r * SS)) for r in (8, 22, 48)]
out = img
for lvl, (a, b) in zip(levels, [(0.30, 0.44), (0.40, 0.56), (0.52, 0.74)]):
    out = Image.composite(lvl, out, dist_mask(a * W, b * W))
edge = dist_mask(0.60 * W, 0.95 * W).point(lambda v: int(v * 0.5))
out = Image.composite(Image.new("RGB", (W, W), (214, 226, 232)), out, edge)
out.resize((OUT, OUT), Image.LANCZOS).save(f"{A}/scene.png")

# ---------- glass overlays (solid shapes; Icon Composer glass dislikes soft alpha) ----------
def glass_layer(name, boxes=(), circles=()):
    m = Image.new("L", (W, W), 0); d = ImageDraw.Draw(m)
    for b in boxes: rrect(d, b, 255)
    for cx, cy, r in circles: d.ellipse([p(cx - r), p(cy - r), p(cx + r), p(cy + r)], fill=255)
    layer = Image.new("RGBA", (W, W), (255, 255, 255, 0)); layer.putalpha(m)
    layer.resize((OUT, OUT), Image.LANCZOS).save(f"{A}/{name}.png")

bl = Image.new("RGBA", (W, W), (0, 0, 0, 0))
bolt(ImageDraw.Draw(bl), *BOLTS[0], INK + (255,))
bl.resize((OUT, OUT), Image.LANCZOS).save(f"{A}/bolt.png")
glass_layer("glass-badge", boxes=[main_badge])
glass_layer("glass-card", boxes=[main_card])

def lay(n, img, glass=True, **k): return dict(name=n, **{"image-name": img, "glass": glass}, **k)
def grp(name, layer, op, shadow, transl):
    return {"name": name, "layers": [lay(name.lower(), layer, opacity=op)],
            "shadow": {"kind": "neutral", "opacity": shadow},
            "translucency": {"enabled": True, "value": transl}, "specular": True}
icon = {
    "fill": {"solid": "srgb:0.94,0.95,0.96,1.0"},
    "groups": [
        {"name": "Bolt", "layers": [lay("bolt", "bolt.png", glass=False)]},
        grp("Badge", "glass-badge.png", 0.35, 0.35, 0.8),
        grp("Card", "glass-card.png", 0.25, 0.3, 0.85),
        {"name": "Scene", "layers": [lay("scene", "scene.png", glass=False)]},
    ],
    "supported-platforms": {"squares": ["macOS"]},
}
json.dump(icon, open(f"{ROOT}/icon.json", "w"), indent=2)
print("ok")
