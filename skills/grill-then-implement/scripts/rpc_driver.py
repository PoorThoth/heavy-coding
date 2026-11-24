#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rpc_driver.py — 用 Python 直接驱动 Pi 的 RPC 模式（stdin/stdout 帧流）。

为什么需要它（2026-10-18 实测）：
  bash 的 FIFO + fd3 + 重定向在 Windows 原生 exe（pi.exe）下拿不到 stdout ——
  Pi 明明干完了活（session 里有产物/答复），事件流却是 0 字节，成功被报成失败。
  用 Python 的 subprocess 管道直接读写，一次就通。

协议（本驱动只做最小实现）：
  启动:  pi --provider <p> --model <m> [--session <path>] [--continue] --mode rpc
  写:    {"id":"req-1","type":"prompt","message":"<prompt-file 全文>"}
  读:    stdout 每行一条 JSON 事件，原样 append 到 --events
  正常:  见到 {"type":"agent_settled"} ⇒ 退出码 0
  异常:  message_end 且 stopReason ∈ {error,aborted,length} ⇒ 6
  停滞:  连续 --idle-timeout 秒无新事件且**不在工具执行中** ⇒ 写 {"type":"abort"}；
         工具执行中（tool_execution_start 已到、tool_execution_end 未到）不计入停滞
         —— 实测 2026-10-19：长工具调用期间本来就不产生事件，旧逻辑会误杀正常票。
         再等 --abort-grace 秒仍无 settled ⇒ 杀进程树，退出码 124
  早退:  进程退出但从未见 settled ⇒ 7

只依赖标准库；不读 .env、不打印任何凭据。
"""

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import traceback

BAD_STOP_REASONS = {"error", "aborted", "length"}
IS_WINDOWS = os.name == "nt"


def _eprint(msg):
    sys.stderr.write("[rpc-driver] %s\n" % msg)
    sys.stderr.flush()


def _native_path(p):
    """MSYS/Git-Bash 的 /c/... 路径 → Windows 路径（原生 Python 不认 /c/...）。"""
    if not p or not IS_WINDOWS:
        return p
    if not p.startswith("/"):
        return p
    cyg = shutil.which("cygpath")
    if cyg:
        try:
            r = subprocess.run([cyg, "-w", p], capture_output=True, text=True, timeout=10)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except Exception:
            pass
    # 退化：/c/foo → C:\\foo，/d/foo → D:\\foo
    if len(p) >= 3 and p[2] == "/" and p[1].isalpha():
        return p[1].upper() + ":\\" + p[3:].replace("/", "\\")
    return p


def _resolve_cmd(pi_bin):
    """把 --pi-bin 解析成可执行命令列表。

    真 Pi 是 .exe，直接执行。为便于自测（以及跨平台），也接受：
      *.py          → 当前 Python 解释器
      *.sh          → bash（Git Bash / MSYS）
      *.cmd / *.bat → cmd.exe /c
    """
    low = pi_bin.lower()
    pi_bin = _native_path(pi_bin)
    if low.endswith(".py"):
        return [sys.executable, pi_bin]
    if low.endswith(".sh"):
        bash = shutil.which("bash")
        if not bash:
            for cand in (r"C:\Program Files\Git\bin\bash.exe",
                         r"C:\Program Files (x86)\Git\bin\bash.exe"):
                if os.path.isfile(cand):
                    bash = cand
                    break
        if not bash:
            raise SystemExit("rpc_driver: --pi-bin 是 .sh，但找不到 bash")
        return [bash, pi_bin]
    if low.endswith(".cmd") or low.endswith(".bat"):
        return [os.environ.get("COMSPEC", "cmd.exe"), "/c", pi_bin]
    return [pi_bin]


def _kill_tree(proc, why):
    """杀整个进程树（Windows: taskkill /T /F；POSIX: 进程组 TERM→KILL）。"""
    if proc is None or proc.poll() is not None:
        return
    pid = proc.pid
    _eprint("%s ⇒ 终止进程树 (pid=%s)" % (why, pid))
    if IS_WINDOWS:
        try:
            subprocess.run(
                ["taskkill", "/T", "/F", "/PID", str(pid)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=15,
            )
        except Exception as exc:  # noqa: BLE001 - 尽力而为
            _eprint("taskkill 失败: %s" % exc)
    else:
        try:
            os.killpg(pid, 15)
        except Exception:
            try:
                proc.terminate()
            except Exception:
                pass
        time.sleep(0.2)
        try:
            os.killpg(pid, 9)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
    try:
        proc.wait(timeout=8)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=3)
        except Exception:
            pass


def _event_text(obj):
    """从 message_end / message_update 里取 assistant 文本。"""
    msg = obj.get("message")
    if not isinstance(msg, dict):
        return None
    if msg.get("role") != "assistant":
        return None
    parts = msg.get("content")
    if not isinstance(parts, list):
        return None
    texts = []
    for part in parts:
        if isinstance(part, dict) and part.get("type") == "text":
            t = part.get("text")
            if isinstance(t, str):
                texts.append(t)
    if not texts:
        return None
    return "".join(texts)


def _stop_reason(obj):
    msg = obj.get("message")
    if isinstance(msg, dict) and isinstance(msg.get("stopReason"), str):
        return msg["stopReason"]
    if isinstance(obj.get("stopReason"), str):
        return obj["stopReason"]
    return None


class RpcDriver:
    def __init__(self, args):
        self.args = args
        self.proc = None
        self.events = []
        self.last_assistant_text = ""
        self.settled = False
        self.bad_stop = None
        self.saw_eof = False
        self.aborted = False
        self.in_tool = False
        self._q = queue.Queue()
        self._reader_done = threading.Event()

    # ------------------------------------------------------------ spawn
    def start(self):
        a = self.args
        cmd = _resolve_cmd(a.pi_bin)
        cmd += ["--provider", a.provider, "--model", a.model]
        if a.session:
            cmd += ["--session", a.session]
        if a.continue_session:
            cmd += ["--continue"]
        cmd += ["--mode", "rpc"]

        os.makedirs(os.path.dirname(os.path.abspath(a.events)) or ".", exist_ok=True)
        os.makedirs(os.path.dirname(os.path.abspath(a.stderr)) or ".", exist_ok=True)
        self._events_fp = open(a.events, "ab", buffering=0)
        self._stderr_fp = open(a.stderr, "ab", buffering=0)

        kwargs = {}
        if IS_WINDOWS:
            # 独立进程组：taskkill /T 更好抓子树
            kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        else:
            kwargs["start_new_session"] = True
        _eprint("spawn: %s" % " ".join(cmd))
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._stderr_fp,
            bufsize=0,
            **kwargs
        )
        self._t = threading.Thread(target=self._read_loop, name="rpc-reader", daemon=True)
        self._t.start()

    def _read_loop(self):
        try:
            while True:
                line = self.proc.stdout.readline()
                if not line:
                    break
                try:
                    self._events_fp.write(line)
                    self._events_fp.flush()
                except Exception:
                    pass
                self._q.put(line)
        finally:
            self._q.put(None)
            self._reader_done.set()

    # ------------------------------------------------------------ frames
    def send_prompt(self, prompt_text):
        frame = json.dumps(
            {"id": "req-1", "type": "prompt", "message": prompt_text},
            ensure_ascii=False,
        )
        return self._send(frame)

    def send_abort(self):
        self._send('{"type":"abort"}')

    def _send(self, line):
        if self.proc is None or self.proc.stdin is None:
            return False
        try:
            self.proc.stdin.write((line + "\n").encode("utf-8"))
            self.proc.stdin.flush()
            return True
        except Exception as exc:  # noqa: BLE001
            _eprint("写 stdin 失败: %s" % exc)
            return False

    def close_stdin(self):
        try:
            if self.proc and self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass

    # ------------------------------------------------------------ run
    def run(self):
        a = self.args
        self.start()
        with open(a.prompt_file, "r", encoding="utf-8", errors="replace") as f:
            prompt = f.read()

        # 1) 等执行端就绪（进程若先退出就不必再等）
        deadline = time.monotonic() + max(0.0, a.ready_wait)
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                break
            time.sleep(0.05)

        # 2) 写 prompt 帧
        if self.proc.poll() is None:
            if not self.send_prompt(prompt):
                _eprint("无法写 prompt 帧 ⇒ rc=7")
                self._cleanup()
                return 7
        else:
            _eprint("执行端在写 prompt 前就退出了")
            self._cleanup()
            return 7

        last_event = time.monotonic()
        abort_at = None
        rc = None

        while True:
            now = time.monotonic()

            # 停滞检测（只在尚未发 abort 时触发）。工具执行期间不计入停滞：
            # tool_execution_start → in_tool=True，tool_execution_end 才清除。
            if abort_at is None and a.idle_timeout and a.idle_timeout > 0:
                if self.in_tool:
                    last_event = now
                elif now - last_event >= a.idle_timeout:
                    _eprint("连续 %.1fs 无新事件（阈值 %ss）⇒ 发 abort 帧"
                            % (now - last_event, a.idle_timeout))
                    self.aborted = True
                    self.send_abort()
                    abort_at = now
                    last_event = now

            # abort 宽限期：仍无 settled ⇒ 杀树，rc=124
            if abort_at is not None and now - abort_at >= max(0.0, a.abort_grace):
                rc = 124
                _kill_tree(self.proc, "abort 无响应（>%ss）⇒ 退化 kill 进程树" % a.abort_grace)
                break

            timeout = 0.25
            if abort_at is not None:
                timeout = min(timeout, max(0.01, a.abort_grace - (now - abort_at)))
            try:
                line = self._q.get(timeout=timeout)
            except queue.Empty:
                if self.proc.poll() is not None and self._reader_done.is_set() and self._q.empty():
                    # 进程退出且管道读尽
                    line = None
                else:
                    continue

            if line is None:
                self.saw_eof = True
                if self.aborted:
                    rc = 124
                elif self.settled:
                    rc = 0
                elif self.bad_stop:
                    rc = 6
                else:
                    _eprint("进程退出但从未见 agent_settled ⇒ rc=7")
                    rc = 7
                break

            last_event = time.monotonic()
            self._handle_line(line)
            if self.settled:
                if self.aborted:
                    _eprint("abort 生效（收到 agent_settled）⇒ rc=124")
                    rc = 124
                else:
                    rc = 0
                break
            if self.bad_stop and not self.aborted:
                _eprint("stopReason=%s ⇒ rc=6" % self.bad_stop)
                rc = 6
                break

        self._cleanup()
        return rc

    def _handle_line(self, raw):
        try:
            text = raw.decode("utf-8", "replace").strip()
        except Exception:
            return
        if not text:
            return
        try:
            obj = json.loads(text)
        except Exception:
            return
        if not isinstance(obj, dict):
            return
        typ = obj.get("type")
        if typ == "tool_execution_start":
            self.in_tool = True
            return
        if typ == "tool_execution_end":
            self.in_tool = False
            return
        if typ == "agent_settled":
            self.settled = True
            return
        if typ == "message_end":
            t = _event_text(obj)
            if t is not None:
                self.last_assistant_text = t
            sr = _stop_reason(obj)
            if sr in BAD_STOP_REASONS:
                self.bad_stop = sr

    def _cleanup(self):
        # 正常结束：先关 stdin（Pi 收到 EOF 会自行退出），5s 不退再杀树（这是清理，不是「退化 kill」）
        if self.proc is not None and self.proc.poll() is None:
            self.close_stdin()
            try:
                self.proc.wait(timeout=5)
            except Exception:
                _kill_tree(self.proc, "收尾：进程未在 5s 内自行退出")
        else:
            self.close_stdin()
        try:
            if not self._reader_done.is_set():
                self._reader_done.wait(timeout=2)
        except Exception:
            pass
        for fp in (getattr(self, "_events_fp", None), getattr(self, "_stderr_fp", None)):
            try:
                if fp:
                    fp.close()
            except Exception:
                pass

    # ------------------------------------------------------------ output
    def print_final_text(self):
        if self.last_assistant_text:
            sys.stdout.write(self.last_assistant_text)
            if not self.last_assistant_text.endswith("\n"):
                sys.stdout.write("\n")
            sys.stdout.flush()


def parse_args(argv):
    p = argparse.ArgumentParser(description="Pi RPC 驱动器（Python 直连版）")
    p.add_argument("--pi-bin", required=True)
    p.add_argument("--provider", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--prompt-file", required=True)
    p.add_argument("--events", required=True)
    p.add_argument("--stderr", required=True)
    p.add_argument("--session", default="")
    p.add_argument("--continue", dest="continue_session", action="store_true")
    p.add_argument("--ready-wait", type=float, default=3.0)
    p.add_argument("--idle-timeout", type=float, default=600.0,
                   help="连续多少秒无新事件视为停滞（0=关闭）")
    p.add_argument("--abort-grace", type=float, default=10.0,
                   help="发 abort 后等多少秒仍无 settled 就杀进程树")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    for name in ("pi_bin", "prompt_file", "events", "stderr", "session"):
        setattr(args, name, _native_path(getattr(args, name)))
    driver = RpcDriver(args)
    try:
        rc = driver.run()
    except KeyboardInterrupt:
        _kill_tree(driver.proc, "收到 KeyboardInterrupt")
        rc = 130
    except Exception as exc:  # noqa: BLE001
        _eprint("driver 异常: %r" % (exc,))
        traceback.print_exc(file=sys.stderr)
        _kill_tree(driver.proc, "driver 异常")
        rc = 1
    driver.print_final_text()
    return rc


if __name__ == "__main__":
    sys.exit(main())
