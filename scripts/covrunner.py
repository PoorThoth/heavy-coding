#!/usr/bin/env python3
"""在 pytest 进程里做「按行命中」记录（零第三方依赖，替代 coverage.py）。

用法:
  python covrunner.py <repo_dir> <out.json> [pytest 参数...]

做法: sys.settrace 只记录 repo 目录内的行命中 —— 比 stdlib trace 模块快两个数量级
（trace 会把 pytest/site-packages 全追一遍，实测 11.9s vs 本脚本 <2s）。
输出: {"src/a.py": [1,2,3], ...}（相对 repo，posix 分隔）
退出码: pytest 的退出码（0 全过 / 1 有失败 / 5 没收集到用例）
"""
import json
import os
import sys

repo = os.path.abspath(sys.argv[1])
out = sys.argv[2]
extra = sys.argv[3:]

hits = {}
repo_c = os.path.normcase(repo)
# 🔴 每个 line 事件都做 abspath/relpath 太贵：实测真实仓库全套 300 例要 6 分钟。
# 按 code object 缓存「这个函数属于哪个文件」，命中路径只剩一次 dict 查找。
_code_cache = {}


def _rel_of(code):
    try:
        return _code_cache[id(code)]
    except KeyError:
        pass
    fn = code.co_filename
    rel = None
    if not fn.startswith("<"):     # <frozen abc> 之类伪文件名会被 abspath 拼到 repo 下（实测踩到）
        try:
            nf = os.path.normcase(os.path.abspath(fn))
            if nf.startswith(repo_c) and "site-packages" not in nf:
                rel = os.path.relpath(nf, repo_c).replace(os.sep, "/")
        except Exception:
            rel = None
    _code_cache[id(code)] = rel
    return rel


def tracer(frame, event, arg):
    if event == "line":
        rel = _rel_of(frame.f_code)
        if rel:
            s = hits.get(rel)
            if s is None:
                s = hits[rel] = set()
            s.add(frame.f_lineno)
    return tracer


def main():
    # 关掉 pytest 的 assert 重写缓存噪音；只跑测试
    args = extra or ["-q"]
    try:
        import pytest
    except ImportError:
        print("covrunner: 当前解释器没有 pytest", file=sys.stderr)
        return 3
    rc = 0
    old = sys.gettrace()
    sys.settrace(tracer)
    try:
        rc = pytest.main(args)
    finally:
        sys.settrace(old)
    with open(out, "w", encoding="utf-8") as f:
        json.dump({k: sorted(v) for k, v in sorted(hits.items())}, f)
    return int(rc)


if __name__ == "__main__":
    sys.exit(main())
