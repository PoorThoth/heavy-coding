#!/usr/bin/env python3
"""收敛报告门禁（给无人值守链路用）—— 没有可消费的报告就算失败。

判据（全部满足才 PASS，exit 0）：
  1. 仓库里存在 `.agents/converge-*.md`（取最新一份）
  2. 报告带终判：`Converged` 或 `未收敛`
  3. SPEC 的每条验收判据（默认自动识别 `**CRn**` / `- [ ] CRn` / `CRn`）都在报告里出现
  4. 报告至少含 1 处 `文件:行` 代码证据（如 `fee.py:12`）
  5. 若终判是「未收敛」→ 必须有缺口清单（含 `缺口`/`Gap` 字样）
  6. **每条 CR 都有测试证据**（v2.0 新增，三向一致的第三向）：
     SPEC 的 CR 行写 `[test: path/to/test.py::test_case]`，检查器会
     ① 文件存在 ② 用例名在文件里找得到 ③ 真跑这一条（pytest / go test -run / node --test），rc=0 才算过。
     纯文档类 CR 可写 `[test: n/a: <≥8 字理由>]`（豁免，会打印出来）。
     逃生门：`--allow-missing-tests`（打成 WARN，不发红）· `--no-run`（只做静态检查，不跑测试）。

用法:
  python converge_check.py <repo_dir> [--spec SPEC.md] [--min-refs 1] [--json]
退出码: 0=PASS  2=FAIL（附缺哪条）
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys


def arg(flag, default=None):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


repo = sys.argv[1]
spec_rel = arg("--spec", "SPEC.md")
min_refs = int(arg("--min-refs", "1"))

spec_path = os.path.join(repo, spec_rel)
criteria = []
spec = ""
if os.path.exists(spec_path):
    spec = open(spec_path, encoding="utf-8", errors="replace").read()
    criteria = sorted({m for m in re.findall(r"\b([A-Z]{2,4}-?\d{1,3})\b", spec)},
                      key=lambda s: (len(s), s))
    criteria = [c for c in criteria if re.match(r"^CR\d+$", c)] or criteria

reports = sorted(glob.glob(os.path.join(repo, ".agents", "**", "converge*.md"), recursive=True),
                 key=os.path.getmtime, reverse=True)
# 同一天多个任务会有多份报告 —— 先从 spec 路径里取 slug，优先选文件名带该 slug 的那份
_slug = None
_m = re.search(r"tasks[/\\]([^/\\]+)[/\\]", spec_rel)
if _m:
    _slug = _m.group(1)
if _slug:
    _cand = [r for r in reports if _slug in os.path.basename(r)]
    if _cand:
        reports = _cand
report = reports[0] if reports else None
body = open(report, encoding="utf-8", errors="replace").read() if report else ""
flat = re.sub(r"\s+", " ", body)

verdict = None
# 先认「显式判定」行（避免正文里出现"未收敛缺口 0 条"这类短语把 verdict 带偏 —— 自测踩过）
m = re.search(r"(?:判定|结论|Verdict)\s*[:：]?\s*\**\s*(Converged|未收敛)", flat, re.I)
if m:
    verdict = "未收敛" if "未收敛" in m.group(1) else "Converged"
if verdict is None:
    m2 = re.search(r"\*\*\s*(Converged|未收敛)", flat)
    if m2:
        verdict = "未收敛" if "未收敛" in m2.group(1) else "Converged"
if verdict is None:
    verdict = "未收敛" if re.search(r"未收敛|not converged", flat) else ("Converged" if re.search(r"Converged", flat) else None)
missing_criteria = [c for c in criteria if c not in flat]
refs = re.findall(r"\b[\w./\\-]+\.(?:py|go|ts|js|vue|sh|sql):\d+", flat)
gaps_section = bool(re.search(r"缺口|Gap|不满足|未接线|未接", flat))

# ---- 每条 CR 的测试证据（v2.0）：
# 实测背景：三向一致只验了两向（规格↔代码、规格↔报告），"每条判据有测试"一直是人肉。
CR_PTR = re.compile(r"\[test:\s*([^\]]+)\]")


def collect_cr_tests(spec_text):
    """{CRn: [指针…]}；CR 可能出现在多行（表格行/子项），全部收集"""
    out = {}
    for line in spec_text.splitlines():
        ids = re.findall(r"\b(CR\d+)\b", line)
        ptrs = CR_PTR.findall(line)
        for cid in ids:
            out.setdefault(cid, [])
        # 指针只归「本行第一条 CR」——否则理由里提到别的 CR（如「已被 CR1 覆盖」）会把指针算到 CR1 头上（自测踩到）
        if ptrs and ids:
            out[ids[0]].extend(ptrs)
    return out


def run_case(repo, fp, rel, case):
    """跑单条用例。返回 (rc|None, note)：None = 无 runner 跑不了（不算失败，但会被点名）"""
    base = case.split("/")[0]
    low = rel.lower()
    env = dict(os.environ)
    try:
        if low.endswith(".py"):
            if shutil.which("pytest"):
                cmd = ["pytest", "-q", f"{rel}::{case}"]
            else:
                cmd = [sys.executable, "-m", "pytest", "-q", f"{rel}::{case}"]
        elif low.endswith(".go"):
            pkg = "./" + (os.path.dirname(rel).replace(os.sep, "/") or ".")
            pat = "^%s$" % re.escape(base)
            if "/" in case:
                pat = "^%s$/^%s$" % (re.escape(base), re.escape(case.split("/", 1)[1]))
            if not shutil.which("go"):
                return None, "没有 go 命令"
            cmd = ["go", "test", pkg, "-run", pat, "-count=1"]
        elif low.endswith((".js", ".mjs", ".cjs", ".ts")):
            if not shutil.which("node"):
                return None, "没有 node 命令"
            cmd = ["node", "--test", "--test-name-pattern", base, rel]
        else:
            return None, "该后缀没有 runner"
        pr = subprocess.run(cmd, cwd=repo, capture_output=True, text=True,
                            timeout=300, env=env)
        if pr.returncode == 0:
            return 0, ""
        tail = (pr.stdout or pr.stderr or "").strip().splitlines()[-3:]
        return pr.returncode, " / ".join(tail)
    except subprocess.TimeoutExpired:
        return 124, "超过 300s"
    except FileNotFoundError:
        return None, "runner 不可用"
    except Exception as e:  # 任何意外都不能把门禁炸掉
        return None, f"执行异常: {e}"


def check_cr_tests(repo, criteria, spec_text, allow_missing, no_run):
    r = {"missing": [], "waived": [], "failed": [], "ran": [], "unrun": []}
    if not criteria:
        return r
    ptrs = collect_cr_tests(spec_text)
    for cid in criteria:
        ps = ptrs.get(cid) or []
        if not ps:
            r["missing"].append(cid)
            continue
        passed = False
        for raw in ps:
            p = raw.strip()
            if p.lower().startswith("n/a"):
                reason = p.split(":", 1)[1].strip() if ":" in p else ""
                if len(reason) >= 8:
                    r["waived"].append(f"{cid}: {reason}")
                    passed = True
                else:
                    r["failed"].append(f"{cid}: `n/a` 必须带 ≥8 字理由（为什么这条不需要测试）")
                continue
            if "::" not in p:
                r["failed"].append(f"{cid}: 指针格式应为 `<文件>::<用例>`，实际是 `{p}`")
                continue
            rel, case = [x.strip() for x in p.split("::", 1)]
            if "<" in rel or "<" in case:
                r["failed"].append(f"{cid}: 占位没填 —— 把 `{p}` 换成真的 `<文件>::<用例>`")
                continue
            fp = os.path.join(repo, rel.replace("/", os.sep))
            if not os.path.exists(fp):
                r["failed"].append(f"{cid}: 测试文件不存在 `{rel}`")
                continue
            try:
                src = open(fp, encoding="utf-8", errors="replace").read()
            except Exception as e:
                r["failed"].append(f"{cid}: 读不了 `{rel}`（{e}）")
                continue
            base = case.split("/")[0]
            if not re.search(r"\b%s\b" % re.escape(base), src):
                r["failed"].append(f"{cid}: `{rel}` 里找不到用例 `{base}`")
                continue
            if no_run:
                r["unrun"].append(f"{cid}: {rel}::{case}（--no-run 未执行）")
                passed = True
                continue
            rc, note = run_case(repo, fp, rel, case)
            if rc == 0:
                r["ran"].append(f"{cid}: {rel}::{case}")
                passed = True
            elif rc is None:
                r["unrun"].append(f"{cid}: {rel}::{case}（{note}）")
                passed = True
            else:
                r["failed"].append(f"{cid}: `{rel}::{case}` 跑不过（rc={rc}）{('｜' + note) if note else ''}")
        if not passed and not any(cid in x for x in r["failed"]):
            r["failed"].append(f"{cid}: 没有任何一条测试证据可用")
    if allow_missing and r["missing"]:
        r["waived"].extend(f"{c}: --allow-missing-tests 放行" for c in r["missing"])
        r["missing"] = []
    return r


cr_res = check_cr_tests(repo, criteria, spec if os.path.exists(spec_path) else "",
                        "--allow-missing-tests" in sys.argv, "--no-run" in sys.argv)

checks = {
    "report_exists": bool(report),
    "verdict_present": verdict is not None,
    "criteria_all_mentioned": bool(criteria) and not missing_criteria,
    "has_code_evidence": len(refs) >= min_refs,
    "gap_list_present_when_not_converged": (verdict != "未收敛") or gaps_section,
    "cr_tests_ok": (not cr_res["missing"]) and (not cr_res["failed"]),
}
ok = all(checks.values())
res = {"repo": repo, "report": os.path.relpath(report, repo) if report else None,
       "spec": spec_rel if os.path.exists(spec_path) else None,
       "criteria_total": len(criteria), "criteria_missing": missing_criteria,
       "verdict": verdict, "evidence_refs": len(refs), "checks": checks, "pass": ok,
       "cr_tests": cr_res}
if "--json" in sys.argv:
    print(json.dumps(res, ensure_ascii=False, indent=1))
else:
    print(f"收敛门禁 [{os.path.basename(repo)}]: {'PASS' if ok else 'FAIL'}")
    print(f"  报告={res['report'] or '（无）'} 终判={verdict} 判据={len(criteria)-len(missing_criteria)}/{len(criteria)} 证据={len(refs)} 处")
    if criteria:
        print(f"  测试证据: 跑通 {len(cr_res['ran'])} · 缺 {len(cr_res['missing'])} · 失败 {len(cr_res['failed'])}"
              f" · 豁免 {len(cr_res['waived'])} · 未执行 {len(cr_res['unrun'])}")
    for k, v in checks.items():
        if not v:
            print(f"  ✗ {k}" + (f"（缺 {missing_criteria}）" if k == "criteria_all_mentioned" else ""))
    for line in cr_res["missing"]:
        print(f"  ✗ {line}: SPEC 里没有 `[test: 文件::用例]`（或 `[test: n/a: 理由]`）")
    for line in cr_res["failed"]:
        print(f"  ✗ {line}")
    for line in cr_res["waived"]:
        print(f"  ○ 豁免 {line}")
    for line in cr_res["unrun"]:
        print(f"  ⚠ 未执行 {line}")

# 退出码约定（给无人值守链路分段处理）：
#   0 = PASS（报告完整；终判是 Converged，或未收敛但未开 strict）
#   2 = FAIL（报告缺失/不完整 —— 必须重跑收敛或修报告）
#   3 = 未收敛（仅在 --fail-on-unconverged 下 —— 应回 G3 修，或告警人工介入）
if not ok:
    sys.exit(2)
if "--fail-on-unconverged" in sys.argv and verdict == "未收敛":
    print("收敛门禁：报告完整但终判=未收敛（strict 模式下按失败处理 → 回 G3 或告警）")
    sys.exit(3)
sys.exit(0)