"""Generate legacy launcher PNGs (mipmap-mdpi..xxxhdpi) for minSdk 24.

The adaptive icon lives in res/mipmap-anydpi-v26/app_icon.xml with
background (@drawable/app_icon_background) and foreground
(@drawable/app_icon_foreground). API 24/25 devices need rasterized
fallbacks at the same resource name: res/mipmap-*/app_icon.png.

Rendering is a faithful edge-to-edge reproduction of the adaptive icon:
background color fills the canvas, the 108dp foreground viewport is
mapped onto the full canvas, so the legacy icon looks exactly like the
adaptive icon does on API 26+ launchers.

Geometry is kept in sync with app_icon_foreground.xml:
  right card  x[58,80]  y[30,72]  r7   #FFE0D8
  left card   x[28,50]  y[36,78]  r7   gradient (32,40)#FF765F -> (46,74)#A53323
  white dot   center (39,53) r4
"""
import os
from PIL import Image, ImageDraw

RES = os.path.join(os.path.dirname(__file__), os.pardir, "android", "app", "src", "main", "res")

BG = (250, 248, 246, 255)        # FAF8F6 porcelain white
PINK = (255, 224, 216, 255)      # FFE0D8
GRAD_FROM = (255, 118, 95)       # FF765F
GRAD_TO = (165, 51, 35)          # A53323
WHITE = (255, 255, 255, 255)

VIEW = 108.0
RIGHT = (58, 30, 80, 72, 7)
LEFT = (28, 36, 50, 78, 7)
DOT = (39, 53, 4)
AX0 = (32.0, 40.0)
AX1 = (46.0, 74.0)

SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
SS = 4  # supersampling factor


def lerp_color(t):
    return tuple(int(round(a + (b - a) * t)) for a, b in zip(GRAD_FROM, GRAD_TO))


def render(size):
    big = size * SS
    img = Image.new("RGBA", (big, big), BG)
    draw = ImageDraw.Draw(img)
    s = big / VIEW

    # right card, solid pink
    x0, y0, x1, y1, r = RIGHT
    draw.rounded_rectangle([x0 * s, y0 * s, x1 * s, y1 * s], radius=r * s, fill=PINK)

    # left card, linear gradient along (AX0 -> AX1) projected per pixel
    x0, y0, x1, y1, r = LEFT
    ax, ay = AX1[0] - AX0[0], AX1[1] - AX0[1]
    denom = ax * ax + ay * ay
    w, h = int(round((x1 - x0) * s)), int(round((y1 - y0) * s))
    grad = Image.new("RGB", (w, h))
    px = grad.load()
    for iy in range(h):
        py = y0 * s + iy
        for ix in range(w):
            pxc = x0 * s + ix
            t = ((pxc - AX0[0] * s) * ax + (py - AX0[1] * s) * ay) / denom
            t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
            px[ix, iy] = lerp_color(t)
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=int(round(r * s)), fill=255)
    img.paste(grad, (int(round(x0 * s)), int(round(y0 * s))), mask)

    # white dot
    cx, cy, rr = DOT
    draw.ellipse(
        [(cx - rr) * s, (cy - rr) * s, (cx + rr) * s, (cy + rr) * s],
        fill=WHITE,
    )

    return img.resize((size, size), Image.LANCZOS)


def main():
    for density, size in SIZES.items():
        out_dir = os.path.normpath(os.path.join(RES, "mipmap-" + density))
        os.makedirs(out_dir, exist_ok=True)
        out = os.path.join(out_dir, "app_icon.png")
        render(size).save(out, "PNG")
        print("wrote %s (%dpx)" % (out, size))


if __name__ == "__main__":
    main()
