#!/usr/bin/env python3
"""账本派生指标：验收失败轮次 / 返工率 / 白跑率 / 成本（从 run_ledger.jsonl 直接算）。

为什么要它: 账本一直在记，但没人看 ⇒ "门禁停摆一个月"和"某票连红 3 轮"都发现不了。
这两个指标本来就在账本里，一条命令就能出，不需要新埋点。

用法:
  python ledger_stats.py [--dir D] [--since YYYY-MM-DD] [--top N] [--json] [--all]
     --dir    只看某个仓库（路径末尾匹配即可，posix/反斜杠都认）
     --since  只统计该日期之后（按记录里的 ts，带时区）
     --top    票表最多显示 N 行（默认 15）
     --all    包含 source=test/exp 的试跑记录（默认排除，免得自测票污染真实指标）
退出码: 0 有数据 · 3 账本为空/不存在
"""
import json
import os
import re
import sys
from collections import defaultdict

LEDGER = os.environ.get("HC_LEDGER") or os.path.join(
    os.environ.get("HC_HOME") or os.path.join(os.path.expanduser("~"), "AppData", "Local", "hermes"), "run_ledger.jsonl")


def arg(flag, default=None):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


def norm_dir(d):
    d = (d or "").replace("\\", "/").rstrip("/")
    if re.match(r"^/[A-Za-z]/", d):
        d = d[1].upper() + ":" + d[2:]
    return d.lower()


def load():
    if not os.path.exists(LEDGER):
        return None
    out = []
    for line in open(LEDGER, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if isinstance(r, dict):
            out.append(r)
    return out


def main():
    recs = load()
    if not recs:
        print(f"账本为空或不存在: {LEDGER}")
        return 3
    only_dir = arg("--dir")
    since = arg("--since")
    top = int(arg("--top", "15"))
    include_tests = "--all" in sys.argv

    keep = []
    for r in recs:
        if not include_tests and (r.get("source") or "live") in ("test", "exp"):
            continue
        if only_dir and not norm_dir(r.get("dir")).endswith(norm_dir(only_dir).split("/")[-1]):
            continue
        if since and (r.get("ts") or "") < since:
            continue
        keep.append(r)

    tickets = defaultdict(lambda: {"deleg": 0, "fail": 0, "last_rc": None, "cost": 0.0,
                                   "dur": 0, "tok_in": 0, "tok_out": 0, "verify_fail": 0,
                                   "converge_fail": 0})
    deleg_total = deleg_fail = 0
    verify_total = verify_fail = 0
    converge_total = converge_fail = 0
    for r in keep:
        cmd = r.get("cmd") or "?"
        d = os.path.basename(norm_dir(r.get("dir")))
        slug = r.get("slug") or "（无 slug）"
        key = f"{d}/{slug}"
        rc = r.get("rc")
        if cmd == "deleg":
            t = tickets[key]
            t["deleg"] += 1
            deleg_total += 1
            if rc not in (0, None):
                t["fail"] += 1
                deleg_fail += 1
            t["last_rc"] = rc
            t["cost"] += float(r.get("cost_usd") or 0)
            t["dur"] += int(r.get("dur_s") or 0)
            t["tok_in"] += int(r.get("in_tokens") or 0)
            t["tok_out"] += int(r.get("out_tokens") or 0)
        elif cmd == "verify":
            verify_total += 1
            if rc not in (0, None):
                verify_fail += 1
                tickets[key]["verify_fail"] += 1
        elif cmd == "converge":
            converge_total += 1
            if rc not in (0, None):
                converge_fail += 1
                tickets[key]["converge_fail"] += 1

    n_tickets = len(tickets)
    ok_tickets = sum(1 for t in tickets.values() if t["last_rc"] == 0)
    redo_tickets = sum(1 for t in tickets.values() if t["fail"] > 0)
    cost = sum(t["cost"] for t in tickets.values())
    fails = [t["fail"] for t in tickets.values()]
    res = {
        "records": len(keep),
        "tickets": n_tickets,
        "tickets_ok": ok_tickets,
        "redo_tickets": redo_tickets,
        "deleg_total": deleg_total,
        "deleg_fail": deleg_fail,
        "verify_total": verify_total,
        "verify_fail": verify_fail,
        "converge_total": converge_total,
        "converge_fail": converge_fail,
        "fail_rounds_total": sum(fails),
        "fail_rounds_max": max(fails) if fails else 0,
        "cost_usd": round(cost, 5),
        "tokens": sum(t["tok_in"] + t["tok_out"] for t in tickets.values()),
    }

    if "--json" in sys.argv:
        print(json.dumps({"summary": res,
                          "tickets": {k: v for k, v in sorted(tickets.items())}},
                         ensure_ascii=False, indent=1))
        return 0

    span = f"{min((r.get('ts') or '') for r in keep)[:10]} → {max((r.get('ts') or '') for r in keep)[:10]}"
    print(f"账本统计 —— {len(keep)} 条记录 · 票 {n_tickets} · deleg {deleg_total} 次 · {span}")
    if not include_tests:
        print("（已排除 source=test/exp；要看全量加 --all）")
    print()
    print(f"{'票（仓库/slug）':<42}{'deleg':>6}{'失败轮':>7}{'验失':>6}{'终rc':>6}{'成本$':>10}")
    for k, t in sorted(tickets.items(), key=lambda kv: (-kv[1]["fail"], -kv[1]["deleg"]))[:top]:
        print(f"{k[:40]:<42}{t['deleg']:>6}{t['fail']:>7}{t['verify_fail']:>6}"
              f"{str(t['last_rc']):>6}{t['cost']:>10.5f}")
    print()
    pct = lambda a, b: f"{(100.0 * a / b):.1f}%" if b else "—"
    print("合计")
    print(f"  票数 {n_tickets} · 成功票 {ok_tickets}（{pct(ok_tickets, n_tickets)}）")
    print(f"  返工率 {pct(redo_tickets, n_tickets)}（{redo_tickets}/{n_tickets} 票有过 ≥1 轮失败）")
    print(f"  验收失败轮次 {res['fail_rounds_total']} 次（单票最多 {res['fail_rounds_max']} 轮）")
    print(f"  白跑率 {pct(deleg_fail, deleg_total)}（deleg {deleg_fail}/{deleg_total} 次 rc≠0）")
    print(f"  验收命令失败：verify {verify_fail}/{verify_total} · converge {converge_fail}/{converge_total}")
    print(f"  成本 ${res['cost_usd']:.5f} · tokens {res['tokens']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
