#!/usr/bin/env python3
"""改动行覆盖门禁（diff coverage）—— 测试跑过 ≠ 你改的那几行被执行过。

做的事:
  1. 用 `git diff --unified=0 <base>` 取**本次改动新增的行**（含未跟踪的新文件：整份都算改动）
  2. 跑一遍测试并把逐行命中记下来
     · Go     : `go test ./... -coverprofile=…`（有 go.mod 时）
     · Python : `covrunner.py`（sys.settrace，零依赖；有 pytest 的仓库才跑）
     · 其它   : 不测（明确报 SKIP，不装绿）
  3. 比对：改动的代码行里，有多少被执行过；低于 --min 就失败
     仓库根的 `.diffcovignore`（每行一个 glob）里的文件不参与比对 —— 显式豁免，不是偷偷降阈值

用法:
  python diffcov.py <repo_dir> [--base HEAD] [--min 1.0] [--paths a.py,b.py] [--json] [--keep]
退出码:
  0 = 改动行覆盖达标
  4 = 无法测量（没有改动 / 没有 git / 没有可用 runner）—— 调用方应按 SKIP 处理，不能当通过
  5 = 有改动行没被执行过（低于阈值）
"""
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

CODE_EXT = {".go", ".py", ".js", ".mjs", ".cjs", ".ts", ".vue", ".sh", ".sql"}
TEST_PAT = re.compile(r"(^|/)(tests?|__tests__|spec)/|(_test\.go)$|(^|/)test_[^/]*\.py$|_test\.py$"
                      r"|(\.test\.|\.spec\.)[cm]?[jt]sx?$")


def docstring_lines(fp, src):
    """文档字符串不会产生 line 事件 —— 不排掉就会「改了句话覆盖率归零」（实测：28/47）。"""
    if not fp.endswith(".py"):
        return set()
    import ast
    try:
        tree = ast.parse("\n".join(src))
    except SyntaxError:
        return set()
    out = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            body = getattr(node, "body", []) or []
            if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant) \
               and isinstance(body[0].value.value, str):
                out.update(range(body[0].lineno, (body[0].end_lineno or body[0].lineno) + 1))
    return out


def is_test_path(rel):
    return bool(TEST_PAT.search(rel))
SKILL_SCRIPTS = os.path.dirname(os.path.abspath(__file__))


def load_ignore(repo):
    """.diffcovignore：每行一个 glob，可带 # 注释。

    为什么要有: 有些改动天生测不了（只在上线时执行的胶水脚本、没有测试挂点的 CLI）。
    这类文件与其把阈值偷偷降到 0.6，不如**在版本库里显式列出来**——看得见、可复查、会被删。
    """
    fp = os.path.join(repo, ".diffcovignore")
    if not os.path.exists(fp):
        return []
    pats = []
    for line in open(fp, encoding="utf-8", errors="replace"):
        s = line.split("#")[0].strip()
        if s:
            pats.append(s)
    return pats


def arg(flag, default=None):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


def sh(cmd, cwd=None, timeout=600):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


# ---------- 1) 改动行 ----------
def changed_lines(repo, base):
    """{相对路径: set(新文件侧行号)}"""
    out = {}
    try:
        r = sh(["git", "diff", "--unified=0", base, "--"], cwd=repo)
    except (OSError, ValueError) as e:
        return None, f"进不了仓库目录 {repo}（{e}）"
    if r.returncode != 0:
        return None, f"git diff 失败: {(r.stderr or '').strip()[:120]}"
    cur = None
    for line in r.stdout.splitlines():
        if line.startswith("+++ b/"):
            cur = line[6:].strip()
            out.setdefault(cur, set())
        elif line.startswith("@@") and cur:
            m = re.search(r"\+(\d+)(?:,(\d+))?", line)
            if not m:
                continue
            start = int(m.group(1))
            cnt = int(m.group(2) or 1)
            out[cur].update(range(start, start + cnt))
    # 未跟踪的新文件：整份算改动
    try:
        r2 = sh(["git", "ls-files", "--others", "--exclude-standard"], cwd=repo)
    except (OSError, ValueError):
        r2 = None
    if r2 is not None and r2.returncode == 0:
        for rel in r2.stdout.split():
            rel = rel.strip().replace("\\", "/")
            if os.path.splitext(rel)[1].lower() not in CODE_EXT:
                continue
            fp = os.path.join(repo, rel.replace("/", os.sep))
            try:
                n = sum(1 for _ in open(fp, encoding="utf-8", errors="replace"))
            except OSError:
                continue
            out.setdefault(rel, set()).update(range(1, n + 1))
    # 🔴 空行/纯注释行永远不会"被执行"——不排掉会让门禁恒红（实测踩到：greet.py 报 3、4 行未覆盖，
    # 那两行是空行）。patch coverage 的通行口径也只统计可执行行。
    COMMENT_PREFIX = ("#", "//", "/*", "*", "--", "<!--")
    ignore = load_ignore(repo)
    # 只测「本票动过的文件」：git diff HEAD 会带上别人未提交的 WIP（实测：本仓有 4 个
    # 别的会话的改动被算成本票的 281 行，覆盖率 10% 直接把门禁打红）。
    raw = arg("--paths") or os.environ.get("WF_DIFFCOV_PATHS", "")
    only_paths = [s.strip() for s in raw.split(",") if s.strip()]
    res = {}
    for rel, lines in out.items():
        if not lines or os.path.splitext(rel)[1].lower() not in CODE_EXT or rel.startswith(".agents/"):
            continue
        if any(fnmatch.fnmatch(rel, pat) for pat in ignore):
            continue
        if only_paths and not any(fnmatch.fnmatch(rel, pat) for pat in only_paths):
            continue
        # 测试文件本身不进 patch coverage：coverprofile 里根本没有测试文件，
        # 不排除的话"每加一个测试文件就必红"（实测踩到：mul_test.go 0/7）
        if is_test_path(rel):
            continue
        fp = os.path.join(repo, rel.replace("/", os.sep))
        try:
            src = open(fp, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        doc = docstring_lines(fp, src)
        keep = set()
        for ln in lines:
            if 1 <= ln <= len(src) and ln not in doc:
                s = src[ln - 1].strip()
                if s and not s.startswith(COMMENT_PREFIX):
                    keep.add(ln)
        if keep:
            res[rel] = keep
    return res, None


# ---------- 2) 逐行命中 ----------
def cov_go(repo, tmp):
    prof = os.path.join(tmp, "cover.out")
    r = sh(["go", "test", "./...", "-count=1", "-coverprofile=" + prof], cwd=repo)
    if not os.path.exists(prof):
        return None, f"go test 没产出 coverprofile（rc={r.returncode}）：{(r.stderr or r.stdout or '')[:120]}"
    # 🔴 go 的 coverprofile 里是 **模块路径**（example.com/calc/calc/calc.go），不是文件系统路径 ——
    # 直接 relpath 会全对不上（实测：加了测试仍报 0 覆盖）。要按 go.mod 的 module 名剥前缀。
    mod = ""
    gm = os.path.join(repo, "go.mod")
    if os.path.exists(gm):
        for line in open(gm, encoding="utf-8", errors="replace"):
            if line.strip().startswith("module "):
                mod = line.split(None, 1)[1].strip()
                break
    hit = {}
    for line in open(prof, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("mode:"):
            continue
        m = re.match(r"^(.+?):(\d+)\.\d+,(\d+)\.\d+\s+(\d+)\s+(\d+)$", line)
        if not m:
            continue
        path, l1, l2, _stmts, cnt = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4), int(m.group(5))
        path = path.replace("\\", "/")
        if mod and path.startswith(mod.strip("/") + "/"):
            rel = path[len(mod.strip("/")) + 1:]
        elif os.path.isabs(path):
            rel = os.path.relpath(path, repo).replace(os.sep, "/")
        else:
            rel = path
        if cnt > 0:
            hit.setdefault(rel, set()).update(range(l1, l2 + 1))
    return hit, None


def pytest_interpreter():
    """pytest 脚本旁边的 python —— Hermes 自带 python 没有 pytest（实测坑）"""
    exe = shutil.which("pytest")
    if not exe:
        return None
    d = os.path.dirname(exe)
    for name in ("python.exe", "python", "python3"):
        cand = os.path.join(d, name)
        if os.path.exists(cand):
            return cand
    return None


def cov_python(repo, tmp):
    py = pytest_interpreter()
    if not py:
        return None, "PATH 上没有 pytest"
    out = os.path.join(tmp, "pyhit.json")
    runner = os.path.join(SKILL_SCRIPTS, "covrunner.py")
    if not os.path.exists(runner):
        return None, "缺 covrunner.py"
    # 子进程隔离缓存：并发/残留的 __pycache__ 会让 line 事件对不上行号
    # （实测：同一条命令先 2/32 后 32/32，怀疑 .pyc 与源码版本错位）。
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.pop("PYTHONPATH", None)
    r = subprocess.run([py, runner, repo, out, "-q", "-p", "no:cacheprovider"],
                       cwd=repo, capture_output=True, text=True, timeout=900, env=env)
    if not os.path.exists(out):
        return None, f"covrunner 没产出（rc={r.returncode}）：{(r.stderr or r.stdout or '')[:120]}"
    data = json.load(open(out, encoding="utf-8"))
    return {k: set(v) for k, v in data.items()}, None


def measure(repo, tmp):
    has_go = os.path.exists(os.path.join(repo, "go.mod"))
    has_py = any(f.endswith(".py") for f in os.listdir(repo)) or os.path.isdir(os.path.join(repo, "tests"))
    hit, notes = {}, []
    if has_go:
        h, err = cov_go(repo, tmp)
        if h: hit.update({k: v for k, v in h.items()})
        if err: notes.append("go: " + err)
    if has_py and not has_go:
        h, err = cov_python(repo, tmp)
        if h: hit.update(h)
        if err: notes.append("py: " + err)
    if not hit:
        return None, "；".join(notes) or "没有可用 runner"
    return hit, "；".join(notes)


# ---------- 3) 比对 ----------
def main():
    repo = os.path.abspath(sys.argv[1])
    base = arg("--base", "HEAD")
    # 默认 1.0：改动的可执行行必须全被执行过。实测过 0.8 的坑 —— 新增一个没人调用的函数，
    # 只有 def 行在 import 时执行，3/4=75% 的文件内比例、整体 88.9% 仍会 PASS（假绿）。
    min_ratio = float(arg("--min", "1.0"))
    changed, err = changed_lines(repo, base)
    if changed is None:
        print(f"[SKIP] {err}（rc=4）")
        return 4
    if not changed:
        print("[SKIP] 没有代码改动（相对 %s）—— rc=4" % base)
        return 4
    tmp = tempfile.mkdtemp(prefix="diffcov-")
    try:
        hit, note = measure(repo, tmp)
    finally:
        if "--keep" not in sys.argv:
            shutil.rmtree(tmp, ignore_errors=True)
    if hit is None:
        print(f"[SKIP] 无法测量覆盖：{note}（rc=4 —— 按 SKIP 处理，别当通过）")
        return 4

    details, tot, cov = [], 0, 0
    for rel, lines in sorted(changed.items()):
        got = len(lines & hit.get(rel, set()))
        tot += len(lines)
        cov += got
        if got < len(lines):
            miss = sorted(lines - hit.get(rel, set()))[:6]
            details.append({"file": rel, "changed": len(lines), "covered": got, "missing": miss})
    ratio = (cov / tot) if tot else 1.0
    ok = ratio >= min_ratio
    res = {"repo": repo, "base": base, "min": min_ratio, "changed_lines": tot,
           "covered_lines": cov, "ratio": round(ratio, 3), "pass": ok,
           "uncovered": details, "notes": note}
    if "--json" in sys.argv:
        print(json.dumps(res, ensure_ascii=False, indent=1))
    else:
        print(f"改动行覆盖: {'PASS' if ok else 'FAIL'}  {cov}/{tot} 行被执行（{ratio:.1%}，阈值 {min_ratio:.0%}）")
        if note:
            print(f"  备注: {note}")
        for d in details[:6]:
            print(f"  ✗ {d['file']}: 改动 {d['changed']} 行，只覆盖 {d['covered']}，未执行行 {d['missing']}")
    if not ok:
        return 5
    return 0


if __name__ == "__main__":
    sys.exit(main())
