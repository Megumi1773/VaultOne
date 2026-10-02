"""删除文案表中指定名字的常量与其全部语言条目（源码以中文原文为键，原文相同的条目必须复用）。

用法：python tools/drop_strings.py <name> [<name> ...]
"""
import re
import sys
from pathlib import Path

PATH = Path("app/lib/src/l10n/strings.dart")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    text = PATH.read_text(encoding="utf-8")
    for name in sys.argv[1:]:
        before = text
        text = re.sub(rf"^  static const {name} = .*;\n", "", text, flags=re.MULTILINE)
        text = re.sub(rf"^    {name}: .*,\n", "", text, flags=re.MULTILINE)
        removed = len(before) - len(text)
        print(f"{name}: 删除 {removed} 字符")
        # 仍被引用时报出来，避免留下编译错误
        refs = [
            p
            for p in Path("app/lib").rglob("*.dart")
            if "l10n" not in p.parts and f"AppStrings.{name}" in p.read_text(encoding="utf-8")
        ]
        for ref in refs:
            print(f"  仍被引用: {ref}")
    PATH.write_text(text, encoding="utf-8", newline="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
