"""重复真相源排查：同一份事实/文案/定义在仓库里应当只有一处权威来源。

规则（默认生效）：**只保留一处真实存在**——同一文案、同一常量、同一枚举标签只允许有
一个权威定义，其余位置必须引用它；重复副本在改动时会静默分叉，是本仓库反复踩到的坑。

本脚本检查：
1. 文案表内部：不同常量名对应同一中文原文（必然导致 `equal_keys_in_const_map`，且说明
   两处语义其实是一个）；
2. Dart 源码：排除文案表后，仍在多处硬编码的同一中文字面量（应迁进文案表）；
3. 文案表与枚举标签：`ItemKind` 等枚举的标签与文案常量重复定义同一文案。

用法：python tools/check_duplicates.py [--all]
不带 `--all` 时只报告 1、3 两类（2 类在迁移期间噪声较大，仅汇总计数）。
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_l10n  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "app" / "lib"


def duplicates_by_value(table: dict[str, str]) -> dict[str, list[str]]:
    rev: dict[str, list[str]] = defaultdict(list)
    for name, value in table.items():
        rev[value].append(name)
    return {v: names for v, names in rev.items() if len(names) > 1}


def hardcoded_literals() -> dict[str, list[str]]:
    """统计文案表之外仍在硬编码的中文字面量出现位置。"""
    hits: dict[str, list[str]] = defaultdict(list)
    literal = re.compile(r"'((?:[^'\\\n]|\\.)*)'")
    for path in sorted(LIB.rglob("*.dart")):
        if "l10n" in path.parts or "rust" in path.parts:
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            stripped = line.lstrip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            for m in literal.finditer(re.sub(r"//.*$", "", line)):
                text = m.group(1)
                if re.search(r"[\u4e00-\u9fff]", text):
                    hits[text].append(f"{path.relative_to(ROOT)}:{lineno}")
    return hits


def enum_label_collisions(zh: dict[str, str]) -> list[str]:
    """枚举标签与文案常量重复定义同一文案。"""
    problems: list[str] = []
    by_value = {v: k for k, v in zh.items()}
    for path in sorted(LIB.rglob("*.dart")):
        if "rust" in path.parts:
            continue
        text = path.read_text(encoding="utf-8")
        for m in re.finditer(r"^\s+\w*\('([^']+)',\s*'([^']*[\u4e00-\u9fff][^']*)'", text, re.MULTILINE):
            value = m.group(2)
            if value in by_value:
                lineno = text[: m.start()].count("\n") + 1
                problems.append(
                    f"{path.relative_to(ROOT)}:{lineno} 枚举标签 {value!r} 与 AppStrings.{by_value[value]} 重复定义"
                )
    return problems


def main() -> int:
    zh, hant, en = check_l10n.load_strings()
    problems: list[str] = []

    # 中文表以**原文为键**（`translate` 按原文查表），因此同一中文原文出现两次会产生重复键，
    # 属于必须修的错误：合并为一个常量、其余位置引用它。
    for value, names in sorted(duplicates_by_value(zh).items()):
        problems.append(f"zh 表内 {names} 对应同一原文 {value!r}（合并为一个常量，其余引用它）")

    # 繁中/英文表里不同原文给出同一译文是正常的（例如「新建」「添加」都译作「新增」），
    # 只作提示，不算失败。
    for lang, table in (("zhHant", hant), ("en", en)):
        shared = duplicates_by_value(table)
        if shared:
            print(f"{lang} 表内译文重合 {len(shared)} 组（不同原文同译，正常）：")
            for value, names in sorted(shared.items()):
                print(f"  {value!r} <- {names}")

    problems.extend(enum_label_collisions(zh))

    hits = hardcoded_literals()
    repeated = {v: locs for v, locs in hits.items() if len(locs) > 1}

    print(f"文案常量 {len(zh)}；zh 表内重复原文 {sum(1 for _ in duplicates_by_value(zh))} 组")
    print(f"文案表外硬编码中文字面量 {len(hits)} 种，其中多处出现的 {len(repeated)} 种（迁移期噪声，仅汇总）")
    if "--all" in sys.argv:
        for value, locs in sorted(repeated.items(), key=lambda kv: -len(kv[1])):
            print(f"  {value!r} x{len(locs)}: {', '.join(locs[:4])}")

    if problems:
        print(f"重复真相源失败，{len(problems)} 处：")
        for p in problems:
            print(" -", p)
        return 1
    print("未发现重复真相源")
    return 0


if __name__ == "__main__":
    sys.exit(main())
