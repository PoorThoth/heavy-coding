#!/usr/bin/env python3
# 假 RPC 执行端（Python 原生进程树，供 driver 验收 B/C/D 用）
import json, os, subprocess, sys, time

MODE = os.environ.get("FAKE_DRV_MODE", "ok")
LOG = os.environ.get("FAKE_DRV_LOG", "")
GC = os.environ.get("FAKE_DRV_GC", "")


def out(o):
    sys.stdout.write(json.dumps(o, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(s):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(s + "\n")


out({"type": "session", "version": 3})
out({"type": "agent_start"})
line = sys.stdin.readline()
log("PROMPT " + line.rstrip("\n"))
out({"type": "response", "command": "prompt", "success": True})
out({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "driver 最终答复"}], "stopReason": "stop"}})

if MODE == "ok":
    out({"type": "agent_settled"})
    sys.stdin.read()
    raise SystemExit(0)
if MODE == "nosettle":
    raise SystemExit(0)
if MODE == "error":
    out({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "坏了"}], "stopReason": "error", "errorMessage": "provider 500"}})
    raise SystemExit(0)

# abort 模式：收 prompt 后不发 settled
if MODE == "abortdead" and GC:
    child = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(300)"])
    with open(GC, "w", encoding="utf-8") as f:
        f.write(str(child.pid))
for frame in sys.stdin:
    log("FRAME " + frame.rstrip("\n"))
    if '"abort"' in frame and MODE == "abortok":
        out({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "被中止"}], "stopReason": "aborted"}})
        out({"type": "agent_settled"})
        raise SystemExit(0)
# 忽略 abort：保持存活等被杀
while True:
    time.sleep(1)
