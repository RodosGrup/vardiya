"""Vardiya uygulama ikonunu üretir: açık zeminde izometrik masa ve mavi, kulaklıklı çalışan.
Çalıştırma: python3 scripts/make_icon.py"""
import math, os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4  # kenar yumuşatma için büyük çizip küçültüyoruz
W = S * SS
OUT = os.path.join(os.path.dirname(__file__), "..", "Vardiya", "Resources", "Assets.xcassets", "AppIcon.appiconset")

def iso(x, y, z, scale, ox, oy):
    return (ox + (x - y) * 0.866 * scale, oy + (x + y) * 0.5 * scale - z * scale)

def main():
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    # macOS ikon ızgarası: 1024 içinde 824'lük yuvarlak kare
    inset = 100 * SS
    box = [inset, inset, W - inset, W - inset]
    grad = Image.new("RGBA", (W, W))
    gd = ImageDraw.Draw(grad)
    top, bottom = (255, 255, 255), (226, 235, 248)
    for yy in range(W):
        t = yy / W
        gd.line([(0, yy), (W, yy)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=185 * SS, fill=255)
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)
    sc, ox, oy = 128 * SS, W / 2, W * 0.53
    P = lambda x, y, z: iso(x, y, z, sc, ox, oy)

    # zemin karosu
    floor = [P(-1.6, -1.6, 0), P(1.6, -1.6, 0), P(1.6, 1.6, 0), P(-1.6, 1.6, 0)]
    d.polygon(floor, fill=(214, 227, 246, 255))
    for i in range(-1, 2):
        d.line([P(i, -1.6, 0), P(i, 1.6, 0)], fill=(198, 214, 238, 255), width=3 * SS)
        d.line([P(-1.6, i, 0), P(1.6, i, 0)], fill=(198, 214, 238, 255), width=3 * SS)

    def box3(x, y, z, w, dd, h, top, left, right):
        x1, y1, z1 = x + w, y + dd, z + h
        d.polygon([P(x, y1, z1), P(x1, y1, z1), P(x1, y1, z), P(x, y1, z)], fill=left)
        d.polygon([P(x1, y, z1), P(x1, y1, z1), P(x1, y1, z), P(x1, y, z)], fill=right)
        d.polygon([P(x, y, z1), P(x1, y, z1), P(x1, y1, z1), P(x, y1, z1)], fill=top)

    white, side, edge = (255, 255, 255, 255), (232, 238, 247, 255), (182, 197, 220, 255)
    dark = (24, 34, 56, 255)
    # sandalye
    box3(-0.3, -1.25, 0.32, 0.6, 0.5, 0.08, white, side, edge)
    box3(-0.3, -1.3, 0.4, 0.6, 0.07, 0.55, white, white, side)
    # çalışan
    blue = (26, 111, 224, 255)
    c = P(0, -0.85, 0.92)
    r = 0.34 * sc
    d.rounded_rectangle([c[0] - r, c[1] - r * 0.85, c[0] + r, c[1] + r * 1.0], radius=r * 0.8, fill=blue)
    h = P(0, -0.85, 1.6)
    hr = 0.22 * sc
    d.ellipse([h[0] - hr, h[1] - hr, h[0] + hr, h[1] + hr], fill=blue)
    # kulaklık
    d.arc([h[0] - hr * 1.25, h[1] - hr * 1.25, h[0] + hr * 1.25, h[1] + hr * 1.25], 195, 345, fill=dark, width=int(0.06 * sc))
    for s in (-1, 1):
        ex = h[0] + s * hr * 1.12
        d.rounded_rectangle([ex - 0.07 * sc, h[1] - 0.08 * sc, ex + 0.07 * sc, h[1] + 0.12 * sc], radius=0.04 * sc, fill=dark)
    # masa
    for lx, ly in [(-0.95, -0.42), (0.95, -0.42), (-0.95, 0.42), (0.95, 0.42)]:
        d.line([P(lx, ly, 0.55), P(lx, ly, 0)], fill=edge, width=int(0.05 * sc))
    box3(-1.05, -0.5, 0.5, 2.1, 1.0, 0.08, white, side, edge)
    # laptop
    box3(-0.38, -0.42, 0.58, 0.76, 0.5, 0.03, (60, 70, 92, 255), dark, dark)
    # menteşe karaktere uzak kenarda, ekran ona dönük
    d.polygon([P(-0.38, 0.08, 0.61), P(0.38, 0.08, 0.61), P(0.38, 0.18, 1.07), P(-0.38, 0.18, 1.07)], fill=dark)
    g = P(0, 0.13, 0.84)
    gr = 0.05 * sc
    d.ellipse([g[0] - gr, g[1] - gr, g[0] + gr, g[1] + gr], fill=(88, 170, 255, 255))
    # kahve
    k = P(0.72, 0.15, 0.58)
    d.rounded_rectangle([k[0] - 0.1 * sc, k[1] - 0.22 * sc, k[0] + 0.1 * sc, k[1]], radius=0.03 * sc, fill=white, outline=edge, width=int(0.02 * sc))

    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + 12 * SS, W - inset, W - inset + 12 * SS], radius=185 * SS, fill=(0, 0, 0, 60))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18 * SS))
    final = Image.alpha_composite(shadow, img).resize((S, S), Image.LANCZOS)

    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            final.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, f"icon_{size}@{scale}x.png"))
    final.save(os.path.join(os.path.dirname(__file__), "icon_1024.png"))

main()


def banner():
    """README kapağı: Jarvis ile aynı düzen (koyu zemin, solda ikon, sağda ad ve alt başlık)."""
    from PIL import ImageFont
    icon = Image.open(os.path.join(OUT, "icon_512@2x.png")).convert("RGBA")
    W, H = 1600, 600
    img = Image.new("RGBA", (W, H), (6, 7, 10, 255))
    # Yumuşak gölge
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((120, 90, 560, 530), radius=100, fill=(0, 0, 0, 160))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    img.alpha_composite(shadow)
    img.alpha_composite(icon.resize((460, 460), Image.LANCZOS), (110, 70))
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 150)
        sub = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 44)
    except Exception:
        font = ImageFont.load_default(); sub = font
    d = ImageDraw.Draw(img)
    d.text((660, 190), "Vardiya", font=font, fill=(240, 240, 245, 255))
    d.text((666, 360), "Claude oturumlarınız bir ofiste, masa başında", font=sub, fill=(140, 144, 152, 255))
    docs = os.path.join(os.path.dirname(__file__), "..", "docs")
    os.makedirs(docs, exist_ok=True)
    img.save(os.path.join(docs, "banner.png"))
    icon.resize((512, 512), Image.LANCZOS).save(os.path.join(docs, "logo.png"))
    print("docs/banner.png + docs/logo.png üretildi")


if __name__ == "__main__":
    banner()
