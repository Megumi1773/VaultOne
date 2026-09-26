"""生成 VaultOne 应用图标母版（1024×1024）。平台图标由 flutter_launcher_icons 从母版派生。

    python tools/make_icon.py

图形与应用内 ZoMark 一致：切角方块（左上/右下切角）+ 保险库转盘圆环 + 贯穿的 "1" 竖笔。
"""
import pathlib

from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "app/assets/icon"
S = 1024
SS = 4  # 超采样抗锯齿

TOP = (74, 124, 255)
BOTTOM = (36, 87, 230)
INK = (255, 255, 255)


def gradient(size):
    g = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(g)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return g


def mark(size, inset_ratio, cut_ratio=0.24, with_body=True):
    n = size * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    inset = int(n * inset_ratio)
    s = n - 2 * inset
    cut = int(s * cut_ratio)
    x0, y0 = inset, inset
    poly = [(x0 + cut, y0), (x0 + s, y0), (x0 + s, y0 + s - cut), (x0 + s - cut, y0 + s), (x0, y0 + s), (x0, y0 + cut)]
    if with_body:
        mask = Image.new("L", (n, n), 0)
        ImageDraw.Draw(mask).polygon(poly, fill=255)
        img.paste(gradient(n), (0, 0), mask)
    d = ImageDraw.Draw(img)
    stroke = int(s * 0.105)
    cx, cy, r = x0 + s / 2, y0 + s / 2, s * 0.25
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=INK, width=stroke)
    d.line([(x0 + s * 0.56, y0 + s * 0.16), (x0 + s * 0.44, y0 + s * 0.84)], fill=INK, width=stroke)
    return img.resize((size, size), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # 通用图标（iOS 不允许透明，填满整个画布）
    full = Image.new("RGB", (S, S))
    full.paste(gradient(S))
    glyph = mark(S, 0.0, cut_ratio=0.0, with_body=False)
    inner = glyph.resize((int(S * 0.62), int(S * 0.62)), Image.LANCZOS)
    full.paste(inner, ((S - inner.width) // 2, (S - inner.height) // 2), inner)
    full.save(OUT / "icon_1024.png")
    # 桌面/网页用：带切角轮廓的透明图标（含轻微阴影）
    body = mark(S, 0.08)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (0, 0), body.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    canvas.alpha_composite(shadow, (0, 14))
    canvas.alpha_composite(body)
    canvas.save(OUT / "icon_desktop_1024.png")
    # Android 自适应图标前景（安全区 66%）
    fg = mark(S, 0.0, cut_ratio=0.0, with_body=False).resize((int(S * 0.5), int(S * 0.5)), Image.LANCZOS)
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    layer.alpha_composite(fg, ((S - fg.width) // 2, (S - fg.height) // 2))
    layer.save(OUT / "adaptive_foreground.png")
    print("icons written to", OUT)


if __name__ == "__main__":
    main()
