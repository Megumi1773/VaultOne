"""文案表门禁：确保每个 `AppStrings.X` 引用都已定义且在繁中/英文下有译文。

迁移期间最容易犯的错不是语法错误，而是**引用了语义不同的常量**（例如把分区标题「网站」
写成字段标签「网址」）——静态检查不会报，默认语言下界面文案却被悄悄改掉。本脚本做两件事：

1. 每个 `AppStrings.X` 引用点都必须在文案表里有定义；
2. 每个字符串常量必须在繁体中文与英文表里都有条目（否则运行时回退中文原文）。

豁免：非文案常量（枚举列表、默认语言、纯符号占位）在 `NOT_TRANSLATED` 中显式列出。
退出码非 0 表示门禁失败。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "app" / "lib"
STRINGS = LIB / "src" / "l10n" / "strings.dart"

# 非面向用户的成员：枚举清单、默认语言、纯符号占位，以及方法（不是文案常量）。
NOT_TRANSLATED = {"supported", "defaultLanguage", "placeholder", "format", "translate", "of"}


def join_literals(chunk: str) -> str:
    """把一段 Dart 表达式里的单引号字面量按顺序拼起来（多行相邻字面量即隐式拼接）。"""
    return "".join(re.findall(r"'((?:[^'\\\n]|\\.)*)'", chunk))


def _const_block(text: str, name: str) -> str | None:
    """取 `static const <name> = ...;` 的完整表达式，允许跨行（到分号为止）。"""
    m = re.search(rf"^  static const {name} = ", text, re.MULTILINE)
    if not m:
        return None
    semi = text.index(";", m.end())
    return text[m.end() : semi]


def load_strings() -> tuple[dict[str, str], dict[str, str], dict[str, str]]:
    text = STRINGS.read_text(encoding="utf-8")
    zh: dict[str, str] = {}
    for m in re.finditer(r"^  static const (\w+) = ", text, re.MULTILINE):
        name = m.group(1)
        block = _const_block(text, name)
        value = join_literals(block or "")
        if value:
            zh[name] = value

    def table_of(marker: str) -> dict[str, str]:
        start = text.index(marker)
        end = text.index("\n  };", start)
        body = text[start:end]
        out: dict[str, str] = {}
        pattern = re.compile(r"^    (\w+):", re.MULTILINE)
        matches = list(pattern.finditer(body))
        for i, m in enumerate(matches):
            stop = matches[i + 1].start() if i + 1 < len(matches) else len(body)
            value = join_literals(body[m.end() : stop])
            if value:
                out[m.group(1)] = value
        return out

    return zh, table_of("_zhHant = {"), table_of("_en = {")


def main() -> int:
    zh, hant, en = load_strings()
    problems: list[str] = []

    # 1) 引用点必须已定义
    refs = 0
    for path in sorted(LIB.rglob("*.dart")):
        if "l10n" in path.parts or "rust" in path.parts:
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            for name in re.findall(r"AppStrings\.(\w+)", line):
                refs += 1
                if name not in zh and name not in NOT_TRANSLATED:
                    problems.append(f"{path.relative_to(ROOT)}:{lineno} 引用了未定义的 AppStrings.{name}")

    # 2) 每个文案常量都要有繁中与英文译文
    for name in zh:
        if name in NOT_TRANSLATED:
            continue
        for lang, table in (("zhHant", hant), ("en", en)):
            if name not in table:
                problems.append(f"AppStrings.{name} 缺少 {lang} 译文（zh={zh[name]!r}）")

    # 3) 译文表不得残留已删除的常量
    for lang, table in (("zhHant", hant), ("en", en)):
        for name in table:
            if name not in zh:
                problems.append(f"{lang} 表残留在已删除的常量 {name}")

    print(f"文案常量 {len(zh)} 个；引用点 {refs} 处；繁中 {len(hant)} 条；英文 {len(en)} 条")
    if problems:
        print(f"门禁失败，{len(problems)} 处：")
        for p in problems:
            print(" -", p)
        return 1
    print("门禁通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
