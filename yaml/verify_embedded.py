#!/usr/bin/env python3
"""
检查源脚本与 YAML 内嵌内容是否一致（不修改文件）。

在 yaml/ 目录下:  python verify_embedded.py
"""
from __future__ import annotations

import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent


def _norm(s: str) -> str:
    return "\n".join(s.replace("\r\n", "\n").replace("\r", "\n").splitlines())


def check_sync() -> bool:
    deploy = (HERE / "deploy.yaml").read_text(encoding="utf-8")
    sync_path = HERE / "sync.sh"
    expected = _norm(sync_path.read_text(encoding="utf-8"))

    start = "  sync.sh: |\n"
    end = "\n---\napiVersion: batch/v1\nkind: CronJob\n"
    i0 = deploy.find(start)
    if i0 == -1:
        print("FAIL: deploy.yaml 中未找到 sync.sh 块")
        return False
    i0 += len(start)
    i1 = deploy.find(end, i0)
    if i1 == -1:
        print("FAIL: deploy.yaml 中未找到 CronJob 锚点")
        return False
    block = deploy[i0:i1]
    if block.endswith("\n"):
        block = block[:-1]
    # 去掉每行前 4 空格（嵌入规则）
    got_lines = []
    for line in block.splitlines():
        if line.startswith("    "):
            got_lines.append(line[4:])
        else:
            got_lines.append(line)
    got = _norm("\n".join(got_lines))

    if got == expected:
        print(f"OK: sync.sh <-> deploy.yaml ConfigMap（{sync_path.name}，{len(expected.splitlines())} 行）")
        return True
    print("FAIL: sync.sh 与 deploy.yaml 内嵌不一致。请运行: python embed_sync.py")
    _diff_hint(expected, got)
    return False


def check_apply_host_routes() -> bool:
    gw = (HERE / "gateway-route-daemon" / "gateway-route-daemon.yaml").read_text(encoding="utf-8")
    script_path = HERE / "gateway-route-daemon" / "apply-host-routes.sh"
    expected = _norm(script_path.read_text(encoding="utf-8"))

    start = "  apply-host-routes.sh: |\n"
    end = "\n---\napiVersion: apps/v1\n"
    i0 = gw.find(start)
    if i0 == -1:
        print("FAIL: gateway-route-daemon.yaml 中未找到 apply-host-routes.sh 块")
        return False
    i0 += len(start)
    i1 = gw.find(end, i0)
    if i1 == -1:
        print("FAIL: gateway-route-daemon.yaml 中未找到 DaemonSet 锚点")
        return False
    block = gw[i0:i1]
    if block.endswith("\n"):
        block = block[:-1]
    got_lines = []
    for line in block.splitlines():
        if line.startswith("    "):
            got_lines.append(line[4:])
        else:
            got_lines.append(line)
    got = _norm("\n".join(got_lines))

    if got == expected:
        print(
            f"OK: apply-host-routes.sh <-> gateway-route-daemon.yaml ConfigMap（"
            f"{len(expected.splitlines())} 行）"
        )
        return True
    print("FAIL: apply-host-routes.sh 与 gateway-route-daemon.yaml 内嵌不一致。请运行: python gateway-route-daemon/build-manifest.py")
    _diff_hint(expected, got)
    return False


def _diff_hint(a: str, b: str) -> None:
    la, lb = a.splitlines(), b.splitlines()
    print(f"  期望行数: {len(la)}，实际行数: {len(lb)}")
    for i, (x, y) in enumerate(zip(la, lb), start=1):
        if x != y:
            print(f"  首处差异约在第 {i} 行:")
            print(f"    期望: {x[:120]!r}")
            print(f"    实际: {y[:120]!r}")
            break
    else:
        if len(la) != len(lb):
            print("  （一方文件更长）")


def main() -> None:
    ok = check_sync() and check_apply_host_routes()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
