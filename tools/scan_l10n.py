"""扫描 Dart 源码中尚未迁移的中文字符串字面量。

用法：python tools/scan_l10n.py app/lib/src/ui/screens/settings_page.dart
输出：按出现顺序列出 `行号<TAB>字面量`，只统计非注释行的单引号 / 双引号字面量。
"""
import re
import sys

CJK = re.compile(r'[\u4e00-\u9fff]')
# 单引号或双引号字面量（不跨越行尾，允许转义）
LITERAL = re.compile(r"'((?:[^'\\\n]|\\.)*)'|\"((?:[^\"\\\n]|\\.)*)\"")


def scan(path: str) -> list[tuple[int, str]]:
    out: list[tuple[int, str]] = []
    for lineno, line in enumerate(open(path, encoding="utf-8"), start=1):
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue
        # 去掉行尾注释，避免把注释里的中文算进去
        code = re.sub(r"//.*$", "", line)
        for m in LITERAL.finditer(code):
            text = m.group(1) if m.group(1) is not None else m.group(2)
            if CJK.search(text):
                out.append((lineno, text))
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    total = 0
    for path in sys.argv[1:]:
        rows = scan(path)
        print(f"### {path}  ({len(rows)} 条)")
        for lineno, text in rows:
            print(f"{lineno}\t{text}")
        total += len(rows)
    print(f"### 合计 {total} 条")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
