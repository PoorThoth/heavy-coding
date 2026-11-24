#!/usr/bin/env python3
"""任务骨架生成器 —— 把 SPEC/任务书/收敛报告模板渲染到仓库里。

用法（一般由 wfctl 调用）:
  python task_scaffold.py spec     <repo> <slug> "<目标>"
  python task_scaffold.py converge <repo> <slug> <spec_path>
说明:
  * 只写 `.agents/**`（不碰业务代码）；已存在的文件不覆盖（打印提示）
  * 收敛报告会从 SPEC 里抽出 CR 清单填进"判据清单"行
"""
import datetime
import os
import re
import sys

TPL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "templates", "task")


def render(tpl_name, mapping):
    tpl = open(os.path.join(TPL_DIR, tpl_name), encoding="utf-8").read()
    for k, v in mapping.items():
        tpl = tpl.replace(f"<{k}>", v)
    return tpl


def write_new(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        print(f"跳过（已存在）: {path}")
        return False
    open(path, "w", encoding="utf-8", newline="\n").write(text)
    print(f"生成: {path}")
    return True


def main():
    mode = sys.argv[1]
    repo = os.path.abspath(sys.argv[2])
    slug = sys.argv[3]
    today = datetime.date.today().isoformat()
    proj = os.path.basename(repo.rstrip("/\\"))

    if mode == "spec":
        goal = sys.argv[4] if len(sys.argv) > 4 else "<一句话目标>"
        m = {"SLUG": slug, "目标": goal, "日期": today, "项目名": proj}
        tdir = os.path.join(repo, ".agents", "tasks", slug)
        a = write_new(os.path.join(tdir, "SPEC.md"), render("SPEC.md.tpl", m))
        b = write_new(os.path.join(tdir, "brief.md"), render("brief.md.tpl", m))
        print("\n下一步：")
        print(f"  1) 填 {(os.path.join('.agents','tasks',slug,'SPEC.md')).replace(os.sep,'/')} 的验收判据（CR1..）")
        print(f"  2) wfctl preflight {repo}")
        print(f"  3) wfctl deleg {repo} .agents/tasks/{slug}/brief.md")
        print(f"  4) Hermes 独立验收（harness/verify_*.py + tsc + 反例）")
        print(f"  5) wfctl converge {repo} .agents/tasks/{slug}/SPEC.md --init  → 填报告 → 再跑（可加 --strict）")
        return 0 if (a or b) else 1

    if mode == "converge":
        spec_rel = sys.argv[4]
        spec_path = os.path.join(repo, spec_rel)
        criteria = []
        if os.path.exists(spec_path):
            txt = open(spec_path, encoding="utf-8", errors="replace").read()
            criteria = sorted({c for c in re.findall(r"\bCR\d+\b", txt)}, key=lambda s: int(s[2:]))
        # 🔴 2026-11-25 实测：原来按日期命名 ⇒ 同一天两个任务共用一个报告，
        # 后一个任务的 --init 会把前一个任务的证据表冲掉（真实发生：probe 冲掉 shout）。
        path = os.path.join(repo, ".agents", f"converge-{slug}-{today}.md")
        goal = f"{slug}"
        if os.path.exists(spec_path):
            first = next((l for l in open(spec_path, encoding="utf-8", errors="replace")
                          if l.startswith("# ")), "")
            goal = re.sub(r"^SPEC\s*[—–\-]+\s*", "", first.lstrip("# ").strip()).strip()
            goal = re.sub(r"（[^）]*）\s*$", "", goal).strip() or slug
        spec_txt = open(spec_path, encoding="utf-8", errors="replace").read() if os.path.exists(spec_path) else ""

        def ptr_of(c):
            m = re.search(r"\b%s\b[^\n]*\[test:\s*([^\]]+)\]" % c, spec_txt)
            return m.group(1).strip() if m else "（SPEC 没写 [test: …]）"

        rows_code = "\n".join("| %s | （待填） | `文件.go:行号` | （待填） |" % c for c in criteria) or "| CR1 | （待填） | `文件.go:行号` | （待填） |"
        rows_test = "\n".join("| %s | `%s` | （待填：我亲自跑的结果） |" % (c, ptr_of(c)) for c in criteria) or "| CR1 |  |  |"
        ok = write_new(path, render("converge.md.tpl", {
            "SLUG": slug, "目标": goal, "日期": today, "项目名": proj,
            "CR 列表": "、".join(criteria) if criteria else "（SPEC 里没找到 CRn）",
            "CR 表格": "| CR | 要求 | 实现（文件:行） | 被调用路径 |\n|---|---|---|---|\n" + rows_code,
            "CR 测试表格": "| CR | 证据（测试/命令） | 我执行的结果 |\n|---|---|---|\n" + rows_test,
        }))
        print(f"判据清单：{criteria if criteria else '（未找到）'}")
        return 0 if ok else 1

    print("用法: task_scaffold.py spec|converge <repo> <slug> [...]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
