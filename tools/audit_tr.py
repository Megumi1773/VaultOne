"""审计 `AppStrings.X` 的引用点，打印每个常量在三种语言下的实际取值。

用途：迁移过程中最容易犯的错是「引用了一个拼写相近但语义不同的常量」（例如把分区标题
「网站」写成字段标签「网址」），此时默认语言下界面文案就变了，且静态检查不会报错。
本脚本把引用点与取值并排列出，便于人工核对；配合 `apply_l10n.py` 的常量值校验使用。

用法：python tools/audit_tr.py <dart 文件…>
"""
import re
import sys
from pathlib import Path

STRINGS = Path("app/lib/src/l10n/strings.dart")


def load_table() -> tuple[dict[str, str], dict[str, str], dict[str, str]]:
    """返回 (简体, 繁体, 英文) 三张「常量名 -> 值」表。

    Dart 里长文案会被拆成多行相邻字符串字面量拼接，因此这里按「`name:` 到行尾逗号」
    逐条截取，再把其中的单引号字面量依次取出拼合，而不是只匹配单行。
    """
    text = STRINGS.read_text(encoding="utf-8")
    zh: dict[str, str] = {}
    for m in re.finditer(r"^  static const (\w+) = (.*);$", text, re.MULTILINE):
        zh[m.group(1)] = _join_literals(m.group(2))

    def table_of(marker: str) -> dict[str, str]:
        start = text.index(marker)
        # 到下一个顶层 `};` 结束
        end = text.index("\n  };", start)
        body = text[start:end]
        out: dict[str, str] = {}
        pattern = re.compile(r"^    (\w+):", re.MULTILINE)
        matches = list(pattern.finditer(body))
        for i, m in enumerate(matches):
            # 该条目内容从本行 `:` 之后到下一条目（或块尾）之前
            stop = matches[i + 1].start() if i + 1 < len(matches) else len(body)
            value = _join_literals(body[m.end() : stop])
            if value:
                out[m.group(1)] = value
        return out

    return zh, table_of("_zhHant = {"), table_of("_en = {")


def _join_literals(chunk: str) -> str:
    """把一段 Dart 表达式里的单引号字面量按顺序拼起来（多行相邻字面量即隐式拼接）。"""
    return "".join(re.findall(r"'((?:[^'\\\n]|\\.)*)'", chunk))


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    zh, hant, en = load_table()
    problems = 0
    for arg in sys.argv[1:]:
        path = Path(arg)
        print(f"### {path}")
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            for name in re.findall(r"AppStrings\.(\w+)", line):
                if name not in zh:
                    print(f"{lineno}\t!! 未定义：{name}")
                    problems += 1
                    continue
                h = hant.get(name)
                e = en.get(name)
                flag = ""
                if h is None or e is None:
                    flag = "  <<< 缺译文（回退中文）"
                    problems += 1
                print(f"{lineno}\t{name}")
                print(f"\t\tzh={zh[name]!r}")
                print(f"\t\thant={h!r}\ten={e!r}{flag}")
        print()
    print(f"### 问题 {problems} 处")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
