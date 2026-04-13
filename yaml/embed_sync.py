#!/usr/bin/env python3
"""
将同目录下的 sync.sh 嵌入 deploy.yaml 中 ConfigMap「coredns-sync-script」的 data.sync.sh 字段。

用法（在 yaml/ 目录下）:
  python embed_sync.py

修改 sync.sh 后执行一次，再提交 deploy.yaml，避免手写内联脚本与源文件不一致。
"""
from __future__ import annotations

import pathlib

HERE = pathlib.Path(__file__).resolve().parent
DEPLOY = HERE / "deploy.yaml"
SYNC = HERE / "sync.sh"

MARKER_START = "  sync.sh: |\n"
# 下一段为 CronJob，作为嵌入结束锚点（勿与文件中其它 batch/v1 混淆）
MARKER_END = "---\napiVersion: batch/v1\nkind: CronJob\n"


def main() -> None:
    root = DEPLOY.read_text(encoding="utf-8")
    sync = SYNC.read_text(encoding="utf-8")
    lines = sync.splitlines()
    embedded = "\n".join("    " + line for line in lines)

    i0 = root.find(MARKER_START)
    if i0 == -1:
        raise SystemExit(f"{DEPLOY}: 未找到 {MARKER_START!r}")
    i0 += len(MARKER_START)

    i1 = root.find(MARKER_END, i0)
    if i1 == -1:
        raise SystemExit(f"{DEPLOY}: 未找到 CronJob 锚点（{MARKER_END!r}）")

    new_root = root[:i0] + embedded + "\n" + root[i1:]
    DEPLOY.write_text(new_root, encoding="utf-8", newline="\n")
    print(f"embedded sync.sh ({len(lines)} lines) -> {DEPLOY}")


if __name__ == "__main__":
    main()
