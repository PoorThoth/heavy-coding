#!/usr/bin/env python3
"""harness_kit —— 仓库自带验收器的公共工具（Hermes × Pi 工作流 v4.3 引入）。

设计原则（吸收 2026「harness engineering」范式）：
  * 判据必须**独立于被测代码**（自己按 SPEC/README 口径复算，不调被测方的测试）
  * 每个验收器 = 一个可执行脚本，**约定式**放 `harness/verify_*.py`，退出码 0=PASS / 非 0=FAIL
  * 机器可读优先：`checker.report()` 打印逐条判据，供人看、也供 `wfctl harness` 汇总

用法（在仓库的 harness/verify_x.py 里）:
    from harness_kit import Checker, run_cli, parse_table, insert_only_diff, approx
    c = Checker("miniorder 验收")
    c.check("CR1 基础费率", lambda: (approx(base_fee_x(), 1.0), "spot=1.0"))
    c.finish()          # 打印 + sys.exit(0/2)
"""
from __future__ import annotations

import difflib
import hashlib
import os
import re
import subprocess
import sys


# ---------------------------------------------------------------- 运行外部命令
def run(argv, cwd=None, timeout=300, env=None):
    """跑一个命令，返回 (rc, stdout, stderr)；不抛异常。"""
    p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                       timeout=timeout, env=env)
    return p.returncode, p.stdout, p.stderr


def run_cli(args, cwd=None, timeout=300):
    """用当前解释器跑一个 python 脚本/模块：run_cli(['-m','pkg.cli','--x','1'], cwd=repo)"""
    return run([sys.executable, *args], cwd=cwd, timeout=timeout)


def parse_table(text, sep="\t", total_key="TOTAL"):
    """解析 `k<TAB>v` 形式的表格输出 → ({k: float}, total|None)"""
    rows, total = {}, None
    for line in text.splitlines():
        if sep not in line:
            continue
        k, v = line.split(sep, 1)
        try:
            val = float(v.strip())
        except ValueError:
            continue
        if k.strip() == total_key:
            total = val
        else:
            rows[k.strip()] = val
    return rows, total


def approx(a, b, tol=0.02):
    try:
        return abs(float(a) - float(b)) <= tol
    except (TypeError, ValueError):
        return False


def raises(fn, exc_name="Exception"):
    try:
        fn()
        return False
    except Exception as e:                       # noqa: BLE001
        return exc_name in type(e).__name__ or any(exc_name in b.__name__ for b in type(e).__mro__)


# ---------------------------------------------------------------- 「只新增」校验
def insert_only_diff(old_bytes: bytes, new_bytes: bytes, max_added=15):
    """校验 new 相对 old 只做了插入（不许删/改行）。返回 dict。"""
    def fm(b):
        if not b.startswith(b"---"):
            return b""
        i = b.find(b"\n---", 3)
        return b[: i + 4] if i > 0 else b""
    eol_same = (b"\r\n" in old_bytes) == (b"\r\n" in new_bytes)
    old = old_bytes.replace(b"\r\n", b"\n").decode("utf-8", "replace")
    new = new_bytes.replace(b"\r\n", b"\n").decode("utf-8", "replace")
    fm_same = fm(old_bytes) == fm(new_bytes)
    ol = old[len(fm(old_bytes)):].splitlines()
    nl = new[len(fm(new_bytes)):].splitlines()
    sm = difflib.SequenceMatcher(None, ol, nl, autojunk=False)
    deleted = sum(b - a for tag, a, b, c, d in sm.get_opcodes() if tag in ("delete", "replace"))
    added = [l for tag, a, b, c, d in sm.get_opcodes() if tag in ("insert", "replace") for l in nl[c:d]]
    return {"deleted_lines": deleted, "added_lines": len(added), "added": added,
            "frontmatter_same": fm_same, "eol_same": eol_same,
            "pass": deleted == 0 and len(added) <= max_added and fm_same and eol_same}


# ---------------------------------------------------------------- 行为指纹
def fingerprint(argv, cwd=None, timeout=300):
    """跑一个命令，返回 (rc, sha256(输出))——用于「行为逐位不变」的对拍。"""
    rc, out, err = run(argv, cwd=cwd, timeout=timeout)
    return rc, hashlib.sha256((out + err).encode("utf-8", "replace")).hexdigest()


def file_sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


# ---------------------------------------------------------------- 判据收集器
class Checker:
    def __init__(self, title, verbose=True):
        self.title = title
        self.verbose = verbose
        self.results = []

    def check(self, name, fn):
        """fn 返回 (ok: bool, note: str) 或 bool。异常视为 FAIL（异常信息进 note）。"""
        try:
            r = fn()
            ok, note = (r if isinstance(r, tuple) else (r, ""))
        except Exception as e:                    # noqa: BLE001
            ok, note = False, f"{type(e).__name__}: {e}"
        self.results.append((name, bool(ok), str(note)))
        if self.verbose:
            print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f"  — {note}" if note else ""))
        return bool(ok)

    @property
    def passed(self):
        return sum(1 for _, ok, _ in self.results if ok)

    def finish(self, exit_on_fail=2):
        total = len(self.results)
        print(f"\nHARNESS {self.title}: {self.passed}/{total} 通过")
        for name, ok, note in self.results:
            if not ok:
                print(f"  ✗ {name} — {note}")
        sys.exit(0 if self.passed == total else exit_on_fail)


def repo_root(marker=".git"):
    """从当前文件往上找仓库根（默认找 .git）。"""
    d = os.path.dirname(os.path.abspath(sys.argv[0]))
    while True:
        if os.path.exists(os.path.join(d, marker)):
            return d
        nd = os.path.dirname(d)
        if nd == d:
            return os.getcwd()
        d = nd


def read(path):
    return open(path, encoding="utf-8", errors="replace").read()
