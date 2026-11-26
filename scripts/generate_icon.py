#!/usr/bin/env python3
"""Generates the MT Files app icon (original design): dark tile, two file panes, AI sparkle."""
import math, os
from PIL import Image, ImageDraw, ImageFilter

S = 2048
OUT = os.path.join(os.path.dirname(__file__), "..", "MTFiles", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")

img = Image.new("RGB", (S, S))
px = img.load()
top, bot = (15, 23, 42), (8, 47, 52)
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
    for x in range(S):
        px[x, y] = c
img = img.convert("RGBA")

glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse([S * 0.15, S * 0.25, S * 0.85, S * 0.95], fill=(34, 195, 166, 90))
glow = glow.filter(ImageFilter.GaussianBlur(160))
img = Image.alpha_composite(img, glow)

d = ImageDraw.Draw(img)
r = int(S * 0.05)
# two panes
lp = [S * 0.16, S * 0.30, S * 0.48, S * 0.82]
rp = [S * 0.52, S * 0.30, S * 0.84, S * 0.82]
d.rounded_rectangle(lp, r, fill=(34, 195, 166, 255))
d.rounded_rectangle(rp, r, fill=(30, 41, 59, 255), outline=(34, 195, 166, 255), width=int(S * 0.012))

def rows(box, fg, folder):
    x0, y0, x1, y1 = box
    y = y0 + S * 0.07
    for i in range(4):
        ix = x0 + S * 0.04
        if folder:
            d.rounded_rectangle([ix, y, ix + S * 0.07, y + S * 0.05], int(S * 0.01), fill=fg)
        else:
            d.rounded_rectangle([ix, y, ix + S * 0.05, y + S * 0.06], int(S * 0.008), fill=fg)
        d.rounded_rectangle([ix + S * 0.10, y + S * 0.015, x1 - S * 0.05 - (i % 2) * S * 0.06, y + S * 0.04], int(S * 0.012), fill=fg)
        y += S * 0.115

rows(lp, (8, 47, 52, 255), True)
rows(rp, (148, 163, 184, 255), False)

# arrow between panes
cx, cy = S * 0.50, S * 0.56
d.ellipse([cx - S * 0.06, cy - S * 0.06, cx + S * 0.06, cy + S * 0.06], fill=(255, 255, 255, 255))
d.polygon([(cx - S * 0.03, cy - S * 0.02), (cx + S * 0.005, cy - S * 0.02), (cx + S * 0.005, cy - S * 0.04),
           (cx + S * 0.04, cy), (cx + S * 0.005, cy + S * 0.04), (cx + S * 0.005, cy + S * 0.02), (cx - S * 0.03, cy + S * 0.02)],
          fill=(8, 47, 52, 255))

def sparkle(x, y, rr, col):
    pts = []
    for i in range(8):
        ang = math.pi / 4 * i - math.pi / 2
        k = rr if i % 2 == 0 else rr * 0.28
        pts.append((x + k * math.cos(ang), y + k * math.sin(ang)))
    d.polygon(pts, fill=col)

sparkle(S * 0.78, S * 0.17, S * 0.10, (255, 255, 255, 255))
sparkle(S * 0.64, S * 0.12, S * 0.04, (167, 243, 208, 255))

img = img.convert("RGB").resize((1024, 1024), Image.LANCZOS)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
img.save(OUT, "PNG")
print("wrote", OUT)
