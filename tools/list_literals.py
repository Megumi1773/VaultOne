"""列出某个 Dart 文件里的中文字面量，并标出与现有文案表常量**撞值**的项。

撞值意味着不能新建常量，必须复用既有常量名，否则文案表出现重复键。
用法：python tools/list_literals.py <dart 文件…>
"""
import io
import re
import sys
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_l10n  # noqa: E402


def main() -> int:
    zh, _, _ = check_l10n.load_strings()
    by_value = {v: k for k, v in zh.items()}
    literal = re.compile(r"'((?:[^'\\\n]|\\.)*)'")
    for arg in sys.argv[1:]:
        print(f"### {arg}")
        seen: list[tuple[str, str | None]] = []
        for line in Path(arg).read_text(encoding="utf-8").splitlines():
            for m in literal.finditer(line):
                text = m.group(1)
                if not re.search(r"[\u4e00-\u9fff]", text):
                    continue
                if text not in [s for s, _ in seen]:
                    seen.append((text, by_value.get(text)))
        for text, existing in seen:
            tag = f"撞值-> {existing}" if existing else "新增"
            print(f"  {tag:<28} | {text}")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
