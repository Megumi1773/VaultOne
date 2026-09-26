"""生成 Recovery Kit PDF 所需的中文字体子集（Noto Sans SC，SIL OFL 1.1）。

用法：
    curl -L -o NotoSansSC.ttf "https://github.com/google/fonts/raw/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf"
    python tools/subset_font.py NotoSansSC.ttf

只保留 recovery_kit.dart 中出现的汉字与全部可打印 ASCII，并实例化为 Regular(400) 静态字体，
使安装包仅增加约 60 KB，而不是完整字体的 17 MB。
"""
import pathlib
import re
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC_DART = ROOT / "app/lib/src/state/recovery_kit.dart"
OUT = ROOT / "app/assets/fonts/NotoSansSC-Regular.ttf"


def main(src: str) -> None:
    text = SRC_DART.read_text(encoding="utf-8")
    cjk = set(re.findall(r"[^\x00-\x7f]", text))
    chars = "".join(sorted(cjk)) + "".join(chr(c) for c in range(0x20, 0x7F))
    font = TTFont(src)
    if "fvar" in font:
        font = instancer.instantiateVariableFont(font, {"wght": 400})
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    sub = subset.Subsetter(opts)
    sub.populate(text=chars)
    sub.subset(font)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    font.save(OUT)
    print(f"{OUT} ({OUT.stat().st_size // 1024} KB, {len(cjk)} CJK glyphs)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "NotoSansSC.ttf")
