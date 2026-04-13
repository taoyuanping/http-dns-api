#!/usr/bin/env python3
"""
依次执行:
  1) embed_sync.py   — sync.sh -> deploy.yaml
  2) gateway-route-daemon/build-manifest.py — apply-host-routes.sh -> gateway-route-daemon.yaml

在 yaml/ 目录下:  python build_all.py
"""
from __future__ import annotations

import subprocess
import sys
import pathlib

HERE = pathlib.Path(__file__).resolve().parent


def main() -> None:
    py = sys.executable
    subprocess.run([py, str(HERE / "embed_sync.py")], check=True)
    subprocess.run([py, str(HERE / "gateway-route-daemon" / "build-manifest.py")], check=True)
    print("ok: deploy.yaml + gateway-route-daemon.yaml 已重新生成")


if __name__ == "__main__":
    main()
