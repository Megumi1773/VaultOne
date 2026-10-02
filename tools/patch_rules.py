"""修正 l10n 规则文件：按行号替换/删除条目。

用法：python tools/patch_rules.py <rules.json> <json-patch.json>
patch 结构：[{"line": 39, "new": "      [\"...\", \"...\"],"}, {"line": 49, "delete": true}]
行号为 1-based；从后往前应用，避免行号漂移。
"""
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    path = Path(sys.argv[1])
    raw = path.read_text(encoding="utf-8")
    newline = "\r\n" if "\r\n" in raw else "\n"
    lines = raw.replace("\r\n", "\n").split("\n")
    patch = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    for item in sorted(patch, key=lambda x: x["line"], reverse=True):
        idx = item["line"] - 1
        if item.get("delete"):
            del lines[idx]
        else:
            lines[idx] = item["new"]
    body = newline.join(lines)
    # 校验仍是合法 JSON
    json.loads(body)
    path.write_text(body, encoding="utf-8", newline="")
    print(f"已修正 {path}（{len(patch)} 处）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
