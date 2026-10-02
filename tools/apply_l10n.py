"""按字面量替换做批量文案迁移。

用法：python tools/apply_l10n.py <rules.json>
rules.json 结构：[{"file": "...", "replace": [["old", "new"], ...]}, ...]
每条 old 必须在文件中恰好出现一次，否则整体失败且不写盘（避免半迁移状态）。
"""
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    groups = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    planned: list[tuple[Path, str, str]] = []
    problems: list[str] = []
    for group in groups:
        path = Path(group["file"])
        text = path.read_text(encoding="utf-8")
        for old, new in group["replace"]:
            count = text.count(old)
            if count != 1:
                problems.append(f"{path}: 出现 {count} 次，期望 1 次 -> {old[:60]!r}")
                continue
            text = text.replace(old, new)
            planned.append((path, old, new))
        group["_result"] = text

    if problems:
        print("未通过校验，未写盘：")
        for p in problems:
            print(" -", p)
        return 1

    for group in groups:
        Path(group["file"]).write_text(group["_result"], encoding="utf-8", newline="")
        print(f"已写入 {group['file']}（{len(group['replace'])} 处）")
    print(f"合计 {len(planned)} 处")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
