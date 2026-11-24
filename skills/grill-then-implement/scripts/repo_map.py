#!/usr/bin/env python3
"""仓库地图生成器 —— 一页 AGENTS.md：怎么跑、怎么验、边界在哪。

原则（三条硬纪律）：
  1. **只写实测到的事实**：每条都标注来源；探测不到就写"未知（人工补）"，绝不猜。
  2. **可重跑可更新**：`--write` 只替换 `<!-- map:auto:start -->…<!-- map:auto:end -->` 之间的内容，
     人工写的段落（坑/边界/约定）原样保留——地图可以反复刷新，人工知识不会被冲掉。
  3. **面向"减少代理探索"**：把代理要摸好几轮的东西（跑什么命令、验证入口在哪、环境陷阱）直接摆在最前。

用法:
  repo_map.py <repo>                 # 打印（stdout）
  repo_map.py <repo> --write         # 写/更新 AGENTS.md（无则创建；有则只更新自动段）
  repo_map.py <repo> --out <path>    # 写到指定文件
"""
import json
import os
import re
import shutil
import subprocess
import sys

SKIP_DIRS = {".git", "node_modules", ".next", "dist", "build", ".venv", "venv", "__pycache__",
             ".harness-logs", ".logs", "target", ".idea", ".vscode", "coverage", ".pytest_cache"}
START, END = "<!-- map:auto:start -->", "<!-- map:auto:end -->"
MAX_TREE_PER_DIR = 8


def run(cmd, cwd=None, timeout=60):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, shell=isinstance(cmd, str))
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as e:
        return 127, str(e)


def walk_files(repo, limit=6000):
    files = []
    for root, dirs, names in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for n in names:
            files.append(os.path.relpath(os.path.join(root, n), repo).replace("\\", "/"))
            if len(files) >= limit:
                return files
    return files


def which(name):
    return shutil.which(name) is not None


def detect_stack(repo, files):
    stacks = []
    ext_count = {}
    for f in files:
        e = os.path.splitext(f)[1].lower()
        if e:
            ext_count[e] = ext_count.get(e, 0) + 1
    pkg = os.path.join(repo, "package.json")
    if os.path.exists(pkg):
        try:
            p = json.load(open(pkg, encoding="utf-8"))
            deps = {**p.get("dependencies", {}), **p.get("devDependencies", {})}
            known = [k for k in ("next", "react", "vue", "nuxt", "vite", "express", "drizzle-orm",
                                 "prisma", "tailwindcss", "typescript", "vitest", "jest", "@playwright/test")
                     if k in deps]
            stacks.append("Node/" + (", ".join(known) if known else "无框架依赖"))
            if "typescript" in deps:
                stacks.append("TypeScript")
        except Exception as e:
            stacks.append(f"Node（package.json 解析失败：{e}）")
    if os.path.exists(os.path.join(repo, "go.mod")):
        mod = next((l.split()[1] for l in open(os.path.join(repo, "go.mod"), encoding="utf-8", errors="replace")
                    if l.startswith("module ")), "?")
        stacks.append(f"Go（{mod}）")
    for f, name in (("pyproject.toml", "Python(pyproject)"), ("requirements.txt", "Python(requirements)"),
                    ("Cargo.toml", "Rust"), ("pom.xml", "Java/Maven")):
        if os.path.exists(os.path.join(repo, f)):
            stacks.append(name)
    return stacks, sorted(ext_count.items(), key=lambda kv: -kv[1])[:5]


def probe(cmd, timeout=25):
    """实测一条命令能不能跑（只信 rc，不信存在性）。"""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, shell=True)
        return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip().splitlines()[:1]
    except Exception as e:
        return 127, [str(e)[:80]]


def env_facts(repo, cmds):
    """环境事实：**每条都实测**（存在性 ≠ 可用性，今天踩过 npm/npx/.cmd 与 cygpath）。"""
    facts, risky = [], []
    for c in ("npm --version", "npx --version", "node --version", "python --version", "go version"):
        rc, out = probe(c)
        facts.append(f"`{c}` → {'可用 ' + out[0] if rc == 0 and out else '不可用(rc=' + str(rc) + ')'}")
    facts.append(f"`cygpath` → {'可用' if shutil.which('cygpath') else '**不可用**（给 native 程序传 POSIX 路径会失败）'}")
    for k, v in cmds:
        if re.search(r"\b(npx|npm)\b", str(v)):
            risky.append(f"`package.json` 的 `{k}` 用了 npm/npx：**Python subprocess(shell=False) 调用 .CMD 会 WinError 2**；"
                         f"在脚本里请改 `node node_modules/<tool>/...` 直调。")
    return facts, risky


def detect_commands(repo, files):
    """返回 (关键命令表, 说明行, 验证入口)。命令必须是**本机实测可用**的形式。"""
    cmds, notes, verifiers = [], [], []
    pkg = os.path.join(repo, "package.json")
    if os.path.exists(pkg):
        try:
            scripts = json.load(open(pkg, encoding="utf-8")).get("scripts", {})
            for k, v in scripts.items():
                cmds.append((k, v))
        except Exception:
            pass
    # 验证入口：harness / 测试框架
    hdir = os.path.join(repo, "harness")
    if os.path.isdir(hdir):
        for f in sorted(os.listdir(hdir)):
            if f.startswith("verify") and f.endswith(".py"):
                verifiers.append(f"python harness/{f}   # 仓库自带验收器（判据见文件内 rows.append）")
    tests = [f for f in files if re.search(r"(^|/)(tests?|__tests__)/", f) or re.search(r"\.(test|spec)\.[jt]sx?$", f)]
    if tests:
        kinds = set()
        if any(f.endswith((".test.js", ".spec.js", ".test.jsx", ".test.ts", ".test.tsx", ".spec.ts")) for f in tests):
            kinds.add("js")
        if any(f.endswith(".py") for f in tests):
            kinds.add("py")
        if any(f.endswith("_test.go") for f in tests):
            kinds.add("go")
        verifiers.append(f"测试文件 {len(tests)} 个（类型: {','.join(sorted(kinds))}）——具体跑法见 AGENTS.md 人工段/Taskfile")
    if os.path.exists(os.path.join(repo, "go.mod")):
        verifiers.append("go vet ./... && go test ./...")
    return cmds, notes, verifiers


def detect_scripts_notes(repo):
    """package.json scripts 的一手提示（哪些脚本明确是坏的/过时的，靠能否跑通判断不了就不断言）。"""
    notes = []
    pkg = os.path.join(repo, "package.json")
    if os.path.exists(pkg):
        try:
            scripts = json.load(open(pkg, encoding="utf-8")).get("scripts", {})
            nd = os.path.join(repo, "node_modules")
            for k, v in scripts.items():
                tool = (re.findall(r"^([a-zA-Z0-9_\-]+)", str(v).strip()) or [""])[0]
                if tool and tool not in ("node", "next", "tsc") and not os.path.isdir(os.path.join(nd, tool)):
                    notes.append(f"⚠️ `npm run {k}` → `{v}`：依赖 `{tool}` 但 `node_modules/{tool}` 不存在 ⇒ 大概率跑不通，别用它当验证。")
        except Exception:
            pass
    return notes


def detect_agents_dir(repo):
    adir = os.path.join(repo, ".agents")
    if not os.path.isdir(adir):
        return None
    out = []
    tdir = os.path.join(adir, "tasks")
    if os.path.isdir(tdir):
        for t in sorted(os.listdir(tdir)):
            files = sorted(os.listdir(os.path.join(tdir, t)))
            out.append(f"`.agents/tasks/{t}/` → {', '.join(files)}")
    conv = sorted(f for f in os.listdir(adir) if f.startswith("converge-"))
    if conv:
        out.append(f"收敛报告：{', '.join(conv[-2:])}")
    return out


def build(repo):
    repo = os.path.abspath(repo)
    files = walk_files(repo)
    stacks, top_ext = detect_stack(repo, files)
    cmds, notes, verifiers = detect_commands(repo, files)
    notes = list(notes) + detect_scripts_notes(repo)
    rc, gitst = run(["git", "status", "--porcelain"], cwd=repo)
    dirty = len([l for l in gitst.splitlines() if l.strip()]) if rc == 0 else None
    rc2, branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo)
    rc3, last = run(["git", "log", "-1", "--format=%h %s"], cwd=repo)

    L = []
    L.append("# 仓库地图（AGENTS.md）—— 先读这里，别急着翻目录\n")
    L.append(f"> 由 `wfctl map {os.path.basename(repo)}` 自动生成；人工段（坑/边界/约定）请写在下方 `map:auto:end` 之后，刷新地图不会覆盖。\n")
    L.append("## 一句话\n")
    L.append(f"- 仓库：`{repo}` ｜ 分支：`{branch.strip() if rc2 == 0 else '未知'}`"
             f" ｜ 最近提交：`{last.strip() if rc3 == 0 else '未知'}`"
             f" ｜ 未提交改动：{dirty if dirty is not None else '非 git 仓库'}\n")
    L.append("## 技术栈（自动探测）\n")
    L.append(f"- {' / '.join(stacks) if stacks else '未识别（人工补）'}")
    L.append(f"- 文件总数：{len(files)} ｜ 主要扩展名：{', '.join(f'{e}×{c}' for e, c in top_ext) or '—'}\n")

    L.append("## 怎么跑（关键命令）\n")
    if cmds:
        for k, v in cmds:
            L.append(f"- `{k}` → `{v}`")
    else:
        L.append("- （package.json 无 scripts；人工补）")
    if verifiers:
        L.append("\n## 怎么验（先跑这个）\n")
        for v in verifiers:
            L.append(f"- {v}")
    else:
        L.append("\n## 怎么验（先跑这个）\n- **未知**：本仓库没找到 harness/verify_*.py，也没有测试文件 ⇒ 验收判据要先建（`wfctl harness <dir> --init`）")
    L.append("\n## 环境事实（**逐条实测**，别重复踩）\n")
    envf, risky = env_facts(repo, cmds)
    for f in envf:
        L.append(f"- {f}")
    for n in list(notes) + risky:
        L.append(f"- {n}")
    L.append("- 路径给 native 程序（git/node/python）时必须 `cygpath -w` 转 Windows 形式，MSYS 路径会失败。")
    L.append(f"- `git` 工作树状态：{'干净' if dirty == 0 else ('有 ' + str(dirty) + ' 处未提交改动' if dirty else '非 git 仓库')}（跑批前先提交基线）。")
    adir = detect_agents_dir(repo)
    L.append("\n## 代理产出约定（自动探测）\n")
    if adir:
        for a in adir:
            L.append(f"- {a}")
    else:
        L.append("- 无 `.agents/`（用 `wfctl task <dir> <slug> \"<目标>\"` 建任务骨架：SPEC + 五段式任务书）")
    L.append("\n## 目录速览（两层，跳过 node_modules/.git 等）\n")
    L.append("```")
    for d in sorted(os.listdir(repo)):
        full = os.path.join(repo, d)
        if d in SKIP_DIRS or d.startswith(".git"):
            continue
        if os.path.isdir(full):
            sub = [x for x in sorted(os.listdir(full)) if x not in SKIP_DIRS][:MAX_TREE_PER_DIR]
            L.append(f"{d}/  → {', '.join(sub)}{' …' if len(sub) >= MAX_TREE_PER_DIR else ''}")
        else:
            L.append(d)
    L.append("```")

    L.append("\n## 坑与边界（**人工补 3–5 条**，自动探测不了）\n")
    L.append("<!-- 例：这一条必须是“代理自己会踩、而文档能提前拦住”的 -->")
    L.append("- <坑 1：例如某个命令看起来对但会失败，正确做法是…>")
    L.append("- <坑 2：例如改动 X 会导致 Y 报错，必须同时改 Z>")
    L.append("- <边界：哪些东西不许碰（生产库/部署/密钥/无关文件）>")
    return "\n".join(L) + "\n"


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else "."
    text = build(repo)
    out = None
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]
    elif "--write" in sys.argv:
        out = os.path.join(os.path.abspath(repo), "AGENTS.md")
    if not out:
        print(text)
        return 0
    if os.path.exists(out):
        old = open(out, encoding="utf-8", errors="replace").read()
        if START in old and END in old:
            new = re.sub(re.escape(START) + r".*?" + re.escape(END), START + "\n" + text + END, old, flags=re.S)
            action = "更新自动段（人工段原样保留）"
        else:
            new = old.rstrip() + f"\n\n{START}\n{text}{END}\n"
            action = "追加自动段（原有人工内容保留在前）"
    else:
        new = f"{START}\n{text}{END}\n"
        action = "新建"
    open(out, "w", encoding="utf-8", newline="\n").write(new)
    print(f"{action}: {out}  （{len(new.splitlines())} 行）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
