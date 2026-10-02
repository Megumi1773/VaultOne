"""生成 Recovery Kit PDF 与备份卡所需的字体子集（Noto Sans，SIL OFL 1.1）。

字体是**按文档实际用到的字符裁剪的子集**，不是完整字体：
- `NotoSansSC-Regular.ttf`（简中 / 英文）与 `NotoSansTC-Regular.ttf`（繁中）各自只保留
  对应语言文案里出现的汉字加全部可打印 ASCII，安装包因此只增加约 100–200 KB，
  而不是完整 CJK 字体的 17–30 MB。

因此**新增文案必须重新生成字体**，否则渲染出的卡片/PDF 会出现缺字方框；
`check_l10n.py` 之外的 `check_fonts.py` 负责在 CI 里拦住这种情况。

用法：
    python tools/subset_font.py <源字体路径> [--tc]

源字体取自 Android Studio 自带的 `NotoSansCJK-Regular.ttc`（第 2 个 face 为 SC、
第 3 个为 TC），或从 Google Fonts 下载的 `NotoSansSC[wght].ttf`。
"""
import argparse
import pathlib
import re
import sys

from fontTools import subset
from fontTools.ttLib import TTCollection, TTFont
from fontTools.varLib import instancer

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONTS = ROOT / "app/assets/fonts"

# 文档（PDF / 备份卡）只用文案表里 `doc*` / `kit*` / `card*` 这几组常量。
# 只把这些常量在三种语言下的取值纳入子集，避免把整个界面文案表塞进安装包。
DOC_CONSTANT_PREFIXES = ("doc", "kit", "card")

# 渲染代码本身也含少量固定文字（例如品牌名），一并纳入。
SOURCES = [
    ROOT / "app/lib/src/state/recovery_kit.dart",
    ROOT / "app/lib/src/state/backup_card.dart",
]

STRINGS = ROOT / "app/lib/src/l10n/strings.dart"


def _literals(chunk: str) -> str:
    """取出 Dart 表达式里的单引号字面量（多行相邻字面量即隐式拼接）。"""
    return "".join(re.findall(r"'((?:[^'\\\n]|\\.)*)'", chunk))


def wanted_chars() -> set[str]:
    """文档会渲染出的全部字符：文案表里文档相关常量（三语）+ 渲染代码中的固定文字。"""
    text = STRINGS.read_text(encoding="utf-8")
    chars: set[str] = set()

    # 简体常量：`static const docXxx = '...';`
    for m in re.finditer(r"^  static const (\w+) = ", text, re.MULTILINE):
        if not m.group(1).startswith(DOC_CONSTANT_PREFIXES):
            continue
        semi = text.index(";", m.end())
        chars.update(_literals(text[m.end() : semi]))

    # 繁中与英文表：`docXxx: '...',`
    for marker in ("_zhHant = {", "_en = {"):
        start = text.index(marker)
        body = text[start : text.index("\n  };", start)]
        hits = list(re.finditer(r"^    (\w+):", body, re.MULTILINE))
        for i, m in enumerate(hits):
            if not m.group(1).startswith(DOC_CONSTANT_PREFIXES):
                continue
            stop = hits[i + 1].start() if i + 1 < len(hits) else len(body)
            chars.update(_literals(body[m.end() : stop]))

    for path in SOURCES:
        # 只取字符串字面量，注释里的汉字不会被渲染，纳入子集纯属浪费。
        chars.update(_literals(path.read_text(encoding="utf-8")))

    return {c for c in chars if ord(c) > 0x7F}


def load_source(path: str, tc: bool) -> TTFont:
    """打开源字体；`.ttc` 按语言取对应 face，可变字体实例化为 Regular(400)。"""
    if path.lower().endswith(".ttc"):
        collection = TTCollection(path, lazy=False)
        # face 顺序：JP / KR / SC / TC / HK，简中取 2，繁中取 3。
        font = collection.fonts[3 if tc else 2]
    else:
        font = TTFont(path, lazy=False)
    if "fvar" in font:
        font = instancer.instantiateVariableFont(font, {"wght": 400})
    return font


def ensure_glyf(font: TTFont, max_err: float = 1.0) -> TTFont:
    """把 CFF/CFF2（三次贝塞尔）轮廓转成 TrueType glyf（二次贝塞尔）。

    `pdf` 包只支持 TrueType 轮廓：它对 CFF 字体取不到字形度量，会退回 Latin-1 编码并
    在遇到中文时报 “This font does not support Unicode characters”。Android Studio
    自带的 Noto Sans CJK 正是 CFF2，因此这里必须转换，而不是仅做子集。
    """
    if "glyf" in font:
        return font

    from fontTools.pens.cu2quPen import Cu2QuPen
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib import newTable

    glyph_set = font.getGlyphSet()
    order = font.getGlyphOrder()
    glyf = newTable("glyf")
    glyf.glyphOrder = order
    glyf.glyphs = {}
    for name in order:
        pen = TTGlyphPen(glyph_set)
        glyph_set[name].draw(Cu2QuPen(pen, max_err, reverse_direction=True))
        glyf[name] = pen.glyph()
    font["glyf"] = glyf
    font["loca"] = newTable("loca")

    # TrueType 需要 maxp 1.0 与 glyf 轮廓；CFF 专用表一并移除。
    # maxp 从 CFF 版本（0.5）升到 1.0 时，必须补上 glyf 才需要的字段，
    # 否则编译时报 KeyError（maxZones 等）。
    maxp = font["maxp"]
    maxp.tableVersion = 0x00010000
    maxp.numGlyphs = len(order)
    for field, value in (
        ("maxPoints", 0),
        ("maxContours", 0),
        ("maxCompositePoints", 0),
        ("maxCompositeContours", 0),
        ("maxZones", 2),
        ("maxTwilightPoints", 0),
        ("maxStorage", 0),
        ("maxFunctionDefs", 0),
        ("maxInstructionDefs", 0),
        ("maxStackElements", 0),
        ("maxSizeOfInstructions", 0),
        ("maxComponentElements", 0),
        ("maxComponentDepth", 0),
    ):
        setattr(maxp, field, value)

    for tag in ("CFF ", "CFF2", "VORG", "vhea", "vmtx"):
        if tag in font:
            del font[tag]
    font.sfntVersion = "\x00\x01\x00\x00"
    font["head"].indexToLocFormat = 0
    return font


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("src", help="源字体路径（.ttf / .otf / .ttc）")
    parser.add_argument("--tc", action="store_true", help="生成繁体中文子集（NotoSansTC）")
    args = parser.parse_args()

    chars = wanted_chars()
    text = "".join(sorted(chars)) + "".join(chr(c) for c in range(0x20, 0x7F))
    font = load_source(args.src, args.tc)

    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    sub = subset.Subsetter(opts)
    sub.populate(text=text)
    sub.subset(font)

    # 子集化之后再转换轮廓：先缩小字形集合，转换成本与产物体积都更小。
    font = ensure_glyf(font)

    out = FONTS / ("NotoSansTC-Regular.ttf" if args.tc else "NotoSansSC-Regular.ttf")
    FONTS.mkdir(parents=True, exist_ok=True)
    font.save(out)

    # 复核：产出的字体必须是 TrueType 轮廓，且覆盖全部目标字符。
    saved = TTFont(out, lazy=True)
    covered = set(saved.getBestCmap())
    missing = sorted(c for c in chars if ord(c) not in covered)
    outline = "glyf" if "glyf" in saved else "CFF（pdf 包不支持）"
    print(f"{out.name} ({out.stat().st_size // 1024} KB, {len(chars)} 目标字符, 轮廓 {outline})")
    if missing:
        print(f"缺字 {len(missing)} 个：{''.join(missing)}")
        return 1
    if outline != "glyf":
        print("轮廓不是 glyf，PDF 渲染会失败")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
