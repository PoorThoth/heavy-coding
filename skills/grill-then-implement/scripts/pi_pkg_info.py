#!/usr/bin/env python3
"""打印 Pi 当前装的技能包（路径<TAB>版本）——换包/A-B 前后用来做「生效证据」。"""
import json
import os
import sys

s = os.path.expanduser("~/.pi/agent/settings.json")
if not os.path.exists(s):
    print("(没有 settings.json)")
    sys.exit(0)
try:
    d = json.load(open(s, encoding="utf-8"))
except Exception as e:                      # noqa: BLE001
    print("settings.json 解析失败:", e)
    sys.exit(0)
pkgs = d.get("packages") or []
if not pkgs:
    print("(packages 为空)")
for p in pkgs:
    pp = str(p).replace("\\", "/")
    ver = ""
    pj = os.path.join(pp, "package.json")
    if os.path.exists(pj):
        try:
            ver = json.load(open(pj, encoding="utf-8")).get("version", "")
        except Exception:                   # noqa: BLE001
            ver = "(package.json 解析失败)"
    else:
        ver = "(找不到 package.json)"
    print(f"{p}\t{ver}")
