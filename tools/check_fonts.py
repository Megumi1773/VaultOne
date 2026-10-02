"""字体子集门禁：确认内嵌字体覆盖文档（PDF / 备份卡）会渲染的全部字符。

字体是手工子集化的（见 `subset_font.py`），只含文档文案用到的字。新增文案后若忘记
重新生成字体，渲染出的卡片与 PDF 会出现缺字方框，而 `dart analyze` 与单元测试都不会报。
本脚本把这条隐性约束变成可执行检查。

退出码非 0 表示缺字。
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import subset_font  # noqa: E402

from fontTools.ttLib import TTFont  # noqa: E402

ROOT = subset_font.ROOT
FONTS = {
    "简体/英文": ROOT / "app/assets/fonts/NotoSansSC-Regular.ttf",
    "繁体": ROOT / "app/assets/fonts/NotoSansTC-Regular.ttf",
}
PUBSPEC = ROOT / "app/pubspec.yaml"


def main() -> int:
    wanted = subset_font.wanted_chars()
    failed = False

    # 字体不仅是文件，还必须登记进 pubspec 才会被打包——漏登记时运行期才报
    # “Unable to load asset”，静态检查与单元测试都可能漏掉。
    pubspec = PUBSPEC.read_text(encoding="utf-8")
    for name, path in FONTS.items():
        rel = path.relative_to(ROOT / "app").as_posix()
        if rel not in pubspec:
            print(f"{name}: {rel} 未登记在 app/pubspec.yaml 的 assets 中")
            failed = True

    for name, path in FONTS.items():
        if not path.exists():
            print(f"{name}: 字体缺失 {path}")
            failed = True
            continue
        font = TTFont(path, lazy=True)
        # `pdf` 包只支持 TrueType glyf 轮廓；CFF/CFF2 会退化成 Latin-1 并在中文处失败。
        outline = "glyf" if "glyf" in font else "CFF/CFF2（pdf 包不支持）"
        covered = set(font.getBestCmap())
        missing = sorted(c for c in wanted if ord(c) not in covered)
        status = "通过" if not missing and outline == "glyf" else f"缺 {len(missing)} 字"
        print(f"{name}（{path.name}, {path.stat().st_size // 1024} KB, 轮廓 {outline}）：{status}")
        if missing:
            print(f"  缺字：{''.join(missing)}")
            failed = True
        if outline != "glyf":
            failed = True
    if failed:
        print("修复：python tools/subset_font.py <NotoSansCJK-Regular.ttc> [--tc]")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
