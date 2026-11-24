#!/usr/bin/env python3
"""时程基线（time-horizon baseline）—— 把每次委托/验收/收敛记成一条记录，回答：
  * 单票委托要多久（中位/均值/最长）
  * 白跑率（rc=0 但零产出）与失败分桶
  * 无人工干预连续成功多少票（streak）
  * 按天趋势（改流程/换模型前后对比的锚点）

用法：
  run_ledger.py append --cmd deleg --dir <dir> --rc 0 --dur 276 [--note '<slug>'] [--out-bytes N] [--agent pi]
                          [--source live|selftest|backfill|manual]   # 缺省读 WFCTL_LEDGER_SOURCE，再缺省 live
  run_ledger.py import-legacy [<glob 根目录>...]   # 导入历史 times*.txt（幂等，靠 id 去重）
  run_ledger.py report [--cmd deleg] [--json] [--days N] [--all] [--source <值>]
                          # 默认**只统计 live**（自测/导入单独看）；--all = 全部来源 + 全部 kind
  run_ledger.py cost --model <名> --in N --out N [--at <ISO>]   # 按内置价目表算单票成本
  run_ledger.py verify-numbers                    # 自检：报警官数字 vs 手算基准

记录落 $HC_HOME/run_ledger.jsonl（可用 WF_LEDGER 覆盖）；只追加，不改写。
白跑判定：rc==0 且（耗时≤3s 或 out_bytes<200 或 commits==0）且 settled != 1
——"看起来成功、其实什么都没做"。
  * settled==1（事件流里有 agent_settled = 本轮自动工作真跑完了）⇒ 一律不算白跑；
  * 记录缺 settled 字段（wfctl v1.10.0 之前的老票）⇒ 视为未知，保持旧判定（不翻历史旧账）；
  * settled==0 ⇒ 按旧规则判（可能确实是静默零产出）。
"""
import datetime
import glob
import json
import os
import re
import statistics
import sys

HOME = os.path.expanduser("~")
LEDGER = os.environ.get("WF_LEDGER") or os.environ.get("HC_LEDGER") or os.path.join(
    os.environ.get("HC_HOME") or os.path.join(HOME, "AppData", "Local", "hermes"), "run_ledger.jsonl")
WHITE_SEC = 3          # ≤3s 视为"没干活"
WHITE_BYTES = 200      # 输出 <200 字节视为无产出
TIMEOUT_SEC = 600      # 单票超时线（与 brief 里"约 600s 有时限"对齐）

# ---------------------------------------------------------------- 价目表（CR3）
# 单位：USD / 1M tokens。**内置**（离线可算，不联网查价）；换价只改这里。
# 峰值时段按 SPEC：UTC 01–04、06–10，仅周一至周五；其余时间算非峰值。
PRICING = {
    "pro":   {"peak": (0.55, 2.19), "off": (0.28, 1.10)},
    "flash": {"peak": (0.28, 0.42), "off": (0.14, 0.28)},
}


def price_tier(model):
    """模型名含 pro ⇒ pro 档，其余（含 deepseek-v4-flash）一律 flash 档。"""
    return "pro" if "pro" in (model or "").lower() else "flash"


def is_peak(when=None):
    """UTC 01:00–03:59 或 06:00–09:59 的周一至周五 = 峰值。"""
    dt = when or datetime.datetime.now(datetime.timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    dt = dt.astimezone(datetime.timezone.utc)
    if dt.weekday() >= 5:      # 周六/周日
        return False
    return 1 <= dt.hour < 4 or 6 <= dt.hour < 10


def unit_price(model, when=None):
    """⇒ (输入单价, 输出单价)，USD / 1M tokens。"""
    pin, pout = PRICING[price_tier(model)]["peak" if is_peak(when) else "off"]
    return pin, pout


def compute_cost(in_tokens, out_tokens, model, when=None):
    """按 tokens + 价目表算 cost_usd（缺 token 不算 = 返回 None）。"""
    if in_tokens is None and out_tokens is None:
        return None
    pin, pout = unit_price(model, when)
    it = int(in_tokens or 0)
    ot = int(out_tokens or 0)
    return round(it / 1e6 * pin + ot / 1e6 * pout, 6)


def _parse_dt(s):
    """ISO 时间字符串 ⇒ aware datetime；坏值/空 ⇒ None（调用方回落到 now）。"""
    if not s:
        return None
    try:
        dt = datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def env_source():
    """落账来源：命令行 --source > 环境变量 WFCTL_LEDGER_SOURCE > live。
    自测必须显式标 selftest —— 否则 2 秒的假票混进 live，成功率/白跑率/成本全错。"""
    return (os.environ.get("WFCTL_LEDGER_SOURCE") or "live").strip() or "live"


def source_of(r):
    """老记录没有 source 字段 ⇒ 视为 live（只做统计过滤，不改写历史）。"""
    return (str(r.get("source") or "live")).strip() or "live"


def load():
    """返回 (records, bad_lines)。坏行不致命——统计不能因为一行脏数据全废。"""
    if not os.path.exists(LEDGER):
        return [], 0
    out, bad, seen = [], 0, set()
    for line in open(LEDGER, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            bad += 1
            continue
        rid = r.get("id")
        if rid and rid in seen:
            continue
        if rid:
            seen.add(rid)
        out.append(r)
    out.sort(key=lambda r: r.get("ts", ""))
    return out, bad


def append_rec(rec):
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    with open(LEDGER, "a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def settled_of(r):
    """取 settled 三态：1 / 0 / None（未知）。账本里既有 int 也有 wfctl 写来的字符串 "1"/"0"。"""
    v = r.get("settled")
    if v is None:
        return None
    if isinstance(v, bool):
        return 1 if v else 0
    if isinstance(v, int):
        return v
    s = str(v).strip().lower()
    if s in ("1", "true", "yes"):
        return 1
    if s in ("0", "false", "no"):
        return 0
    return None


def is_white(r):
    if r.get("rc") != 0:
        return False
    if settled_of(r) == 1:      # 有终止事件 ⇒ 真跑完了，哪怕 5 秒 50 字节也不算白跑
        return False
    if r.get("dur_s", 999) <= WHITE_SEC:
        return True
    ob = r.get("out_bytes")
    if ob is not None and ob < WHITE_BYTES:
        return True
    if r.get("commits") is not None and r.get("commits") == 0:
        return True
    return False


def bucket(r):
    if r.get("rc") != 0:
        return "rc≠0（报错退出）"
    if r.get("dur_s", 0) > TIMEOUT_SEC:
        return f"超时(>{TIMEOUT_SEC}s)"
    if is_white(r):
        return "白跑（静默零产出）"
    return "有产出"


def streak(records):
    """当前连续成功票数 + 历史最长。成功 = rc==0 且有产出。"""
    cur = best = 0
    for r in records:
        if r.get("rc") == 0 and not is_white(r):
            cur += 1
            best = max(best, cur)
        else:
            cur = 0
    return cur, best


EXPLORE_PREFIX = ("ls", "find", "grep", "rg", "cat", "head", "tail", "tree", "which", "stat", "wc", "du", "pwd",
                  "git status", "git log", "git ls-files")
PITFALL_PATTERNS = ("command not found", "No such file or directory", "not recognized as an internal",
                    "npm ERR", "Cannot find module", "ENOENT")


def _tool_calls(path):
    """从 pi 的 --mode json 轨迹里抽每次工具调用（去重：只认 tool_execution_start）。"""
    calls = []
    if not os.path.exists(path):
        return calls
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "tool_execution_start":
            calls.append(d)
    return calls


def classify(d):
    name = (d.get("toolName") or "?").lower()
    args = d.get("args") or {}
    cmd = str(args.get("command") or "")
    if name in ("read", "glob", "grep", "list", "search", "find", "ls"):
        return name, True, cmd
    if name == "bash":
        head = cmd.strip().split("\n")[0].strip()
        if any(head.startswith(p) for p in EXPLORE_PREFIX) or "| grep" in cmd or ">/dev/null" in cmd and head.startswith(("ls", "find")):
            return name, True, cmd
        return name, False, cmd
    return name, False, cmd


def cmd_trace_stats(args):
    """统计一次 pi --mode json 轨迹：工具调用数 / 探索型调用数 / 报错数 / 环境坑命中数。
    `--final-error` 只打印最后的错误信息（连接错误/重试耗尽这类），供 wfctl 硬失败时提示。"""
    path = args[0]
    stats_only = "--stats" in args
    if "--final-error" in args:
        err = ""
        for line in open(path, encoding="utf-8", errors="replace") if os.path.exists(path) else []:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") == "auto_retry_end" and d.get("finalError"):
                err = str(d["finalError"])
            m = d.get("message") or {}
            if m.get("stopReason") == "error" and m.get("errorMessage"):
                err = str(m["errorMessage"])
        print(err or "（未记录错误信息；可能是模型/网络问题，见轨迹文件）")
        return 0
    calls = _tool_calls(path)
    explore = sum(1 for d in calls if classify(d)[1])
    names = {}
    for d in calls:
        n = (d.get("toolName") or "?")
        names[n] = names.get(n, 0) + 1
    errs = 0
    hits = 0
    final_text = ""
    for line in open(path, encoding="utf-8", errors="replace") if os.path.exists(path) else []:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "tool_execution_end":
            if d.get("isError"):
                errs += 1
            blob = json.dumps(d.get("result") or {}, ensure_ascii=False)
            hits += sum(blob.count(p) for p in PITFALL_PATTERNS)
        if d.get("type") == "message_end" and (d.get("message") or {}).get("role") == "assistant":
            parts = [c.get("text", "") for c in (d["message"].get("content") or []) if c.get("type") == "text"]
            if any(parts):
                final_text = "\n".join(parts)
    line1 = (f"tool_calls={len(calls)} explore_calls={explore} tool_errors={errs} "
             f"pitfall_hits={hits} tools={json.dumps(names, ensure_ascii=False)}")
    if stats_only:
        print(f"tool_calls={len(calls)} explore_calls={explore} tool_errors={errs} pitfall_hits={hits}")
    else:
        print(line1)
        if final_text:
            print("\n--- 执行端最终输出 ---\n" + final_text[:4000])
    return 0


def cmd_append(args):
    rec = {"ts": now_iso(), "source": env_source()}
    # settled/missing 必须是 JSON 数字：baseline 的白跑判定按整数比较，字符串 "1" 会让下游类型不一致。
    # 读取侧由 settled_of() 兼容老的字符串记录（"1"/"0" 与 int 等价），所以历史票不受影响。
    ints = ("out_bytes", "rc", "dur_s", "commits", "tool_calls", "explore_calls", "tool_errors", "pitfall_hits",
            "settled", "missing", "in_tokens", "out_tokens")
    floats = ("cost_usd",)
    i = 0
    while i < len(args):
        tok = args[i]
        if "=" in tok and not tok.startswith("--"):
            k, v = tok.split("=", 1)          # 支持 `tool_calls=2` 这种裸键值（trace-stats --stats 的输出）
            i += 1
        else:
            k = tok.lstrip("-").replace("-", "_")
            v = args[i + 1] if i + 1 < len(args) else ""
            i += 2
        if k == "dur":
            k = "dur_s"
        if k == "note":
            k = "slug"
        if k == "test":
            k, v = "kind", "test"
        if k in ints:
            try:
                v = int(v)
            except ValueError:
                pass
        elif k in floats:
            try:
                v = float(v)
            except ValueError:
                pass
        rec[k] = v
    # CR3：给了 tokens 但没给 cost_usd ⇒ 用内置价目表补算（模型从 rec['model'] 取，缺则按 flash）
    if rec.get("cost_usd") is None:
        cost = compute_cost(rec.get("in_tokens"), rec.get("out_tokens"), rec.get("model"),
                            _parse_dt(rec.get("at") or rec.get("ts")))
        if cost is not None:
            rec["cost_usd"] = cost
    append_rec(rec)
    return 0


def cmd_cost(args):
    """自测/对账入口：cost --model pro --in 1000000 --out 1000000 [--at 2026-10-19T02:00:00Z]"""
    model = ""
    it = ot = 0
    at = None
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--model", "--in", "--out", "--at"):
            v = args[i + 1] if i + 1 < len(args) else ""
            i += 2
        elif "=" in a:
            a, v = a.split("=", 1)
            i += 1
        else:
            i += 1
            continue
        if a == "--model":
            model = v
        elif a == "--in":
            it = int(v or 0)
        elif a == "--out":
            ot = int(v or 0)
        elif a == "--at":
            at = v
    when = _parse_dt(at)
    pin, pout = unit_price(model, when)
    print(json.dumps({"model": model, "tier": price_tier(model), "peak": is_peak(when or datetime.datetime.now(datetime.timezone.utc)),
                      "unit_in": pin, "unit_out": pout, "in_tokens": it, "out_tokens": ot,
                      "cost_usd": compute_cost(it, ot, model, when)}, ensure_ascii=False))
    return 0


def parse_legacy_file(path, root):
    """解析一条 times*.txt：形如 'bug-old\tbug_old.md\t46s\trc=0\tcommits=2'（列序不定）。"""
    recs = []
    for ln, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split("\t") if p.strip()]
        rec = {"cmd": "deleg", "source": "backfill", "agent": "pi",
               "id": f"legacy:{os.path.relpath(path, root).replace(os.sep, '/')}:{ln}",
               "bench": os.path.basename(os.path.dirname(path)),
               "label": parts[0] if parts else "", "slug": parts[1] if len(parts) > 1 else ""}
        for p in parts:
            m = re.fullmatch(r"(\d+)s", p)
            if m:
                rec["dur_s"] = int(m.group(1))
            m = re.fullmatch(r"rc=(\d+)", p)
            if m:
                rec["rc"] = int(m.group(1))
            m = re.fullmatch(r"commits=(\d+)", p)
            if m:
                rec["commits"] = int(m.group(1))
            m = re.fullmatch(r"plan_bytes=(\d+)", p)
            if m:
                rec["plan_bytes"] = int(m.group(1))
        rec.setdefault("rc", 0)
        rec.setdefault("dur_s", 0)
        # 日期取自目录名（wf-accept-2026-10-08 → 2026-10-08），否则用文件 mtime
        m = re.search(r"(\d{4}-\d{2}-\d{2})", os.path.basename(os.path.dirname(path)))
        if m:
            rec["ts"] = f"{m.group(1)}T12:00:00+08:00"
        else:
            rec["ts"] = datetime.datetime.fromtimestamp(os.path.getmtime(path)).astimezone().isoformat(timespec="seconds")
        recs.append(rec)
    return recs


def cmd_import(args):
    roots = args or [os.getcwd()]
    existing, _ = load()
    have = {r.get("id") for r in existing if r.get("id")}
    added = skipped = 0
    for root in roots:
        for path in sorted(glob.glob(os.path.join(root, "**", "times*.txt"), recursive=True)):
            for rec in parse_legacy_file(path, root):
                if rec["id"] in have:
                    skipped += 1
                    continue
                append_rec(rec)
                have.add(rec["id"])
                added += 1
    print(f"导入历史记录: 新增 {added} 条，跳过（已存在）{skipped} 条 → {LEDGER}")
    return 0


def cmd_report(args):
    cmd_filter = None
    days = None
    want_all = "--all" in args
    only_source = None
    as_json = "--json" in args
    for i, a in enumerate(args):
        if a == "--cmd" and i + 1 < len(args):
            cmd_filter = args[i + 1]
        if a == "--days" and i + 1 < len(args):
            days = int(args[i + 1])
        if a == "--source" and i + 1 < len(args):
            only_source = args[i + 1]
    recs, bad = load()
    # --all = 看全部（含自测/导入 + 全部 kind）；默认只统计 live 的真实工作票。
    if not want_all and "--all-kinds" not in args:
        recs = [r for r in recs if r.get("kind") not in ("test", "exp")]   # 默认只统计真实工作
    excluded = 0
    if only_source:
        excluded = sum(1 for r in recs if source_of(r) != only_source)
        recs = [r for r in recs if source_of(r) == only_source]
    elif not want_all:
        excluded = sum(1 for r in recs if source_of(r) != "live")
        recs = [r for r in recs if source_of(r) == "live"]
    if days:
        cut = (datetime.datetime.now().astimezone() - datetime.timedelta(days=days)).isoformat(timespec="seconds")
        recs = [r for r in recs if r.get("ts", "") >= cut]
    if cmd_filter:
        recs = [r for r in recs if r.get("cmd") == cmd_filter]
    deleg = [r for r in recs if r.get("cmd") == "deleg"]
    durs = [r.get("dur_s", 0) for r in deleg]
    cur, best = streak(deleg)
    tc = [r["tool_calls"] for r in deleg if isinstance(r.get("tool_calls"), int)]
    ex = [r["explore_calls"] for r in deleg if isinstance(r.get("explore_calls"), int)]
    ph = [r["pitfall_hits"] for r in deleg if isinstance(r.get("pitfall_hits"), int)]
    costs = [r["cost_usd"] for r in deleg if isinstance(r.get("cost_usd"), (int, float))]
    trace_n = len(tc)
    buckets = {}
    for r in deleg:
        buckets[bucket(r)] = buckets.get(bucket(r), 0) + 1
    byday = {}
    for r in deleg:
        d = r.get("ts", "")[:10]
        byday.setdefault(d, []).append(r)
    stats = {
        "记录总数": len(recs), "坏行（已跳过）": bad,
        "统计口径": ("all" if want_all else (only_source or "live")),
        "已排除非live": excluded,
        "委托票数": len(deleg),
        "有产出": sum(1 for r in deleg if bucket(r) == "有产出"),
        "白跑票数": sum(1 for r in deleg if is_white(r)),
        "白跑率": f"{(sum(1 for r in deleg if is_white(r)) / len(deleg) * 100):.0f}%" if deleg else "—",
        "耗时_最小": min(durs) if durs else None, "耗时_中位": statistics.median(durs) if durs else None,
        "耗时_均值": round(statistics.mean(durs), 1) if durs else None, "耗时_最长": max(durs) if durs else None,
        "成本样本": len(costs),
        "总花费_usd": round(sum(costs), 6) if costs else 0.0,
        "单票中位成本_usd": round(statistics.median(costs), 6) if costs else None,
        "单票均值成本_usd": round(statistics.mean(costs), 6) if costs else None,
        "当前连续成功": cur, "历史最长连续成功": best,
        "分桶": buckets,
        "探索轮次（PI_TRACE=1 的票）": {
            "样本数": trace_n,
            "平均工具调用": round(statistics.mean(tc), 1) if tc else None,
            "平均探索型调用": round(statistics.mean(ex), 1) if ex else None,
            "平均环境坑命中": round(statistics.mean(ph), 1) if ph else None,
        },
        "按天": {d: {"票数": len(v), "中位秒": statistics.median([x.get('dur_s', 0) for x in v]),
                     "白跑": sum(1 for x in v if is_white(x))} for d, v in sorted(byday.items())},
        "账本": LEDGER,
    }
    if as_json:
        print(json.dumps(stats, ensure_ascii=False, indent=2))
        return 0
    print(f"=== 时程基线（{LEDGER}）===")
    print(f"口径: {stats['统计口径']}" + (f"（已排除 {excluded} 条非 live（自测/导入）；--all 可看全部）" if excluded else ""))
    print(f"记录 {stats['记录总数']} 条（坏行 {bad}）｜委托 {stats['委托票数']} 票｜有产出 {stats['有产出']}"
          f"｜白跑 {stats['白跑票数']}（{stats['白跑率']}）")
    if durs:
        print(f"单票耗时：最小 {stats['耗时_最小']}s ／ 中位 {stats['耗时_中位']:.0f}s ／ "
              f"均值 {stats['耗时_均值']}s ／ 最长 {stats['耗时_最长']}s")
    print(f"连续成功：当前 {cur} 票 ｜ 历史最长 {best} 票")
    if costs:
        print(f"花费：总 ${stats['总花费_usd']:.4f}（{stats['成本样本']} 票有成本）｜"
              f"单票中位 ${stats['单票中位成本_usd']:.4f} ／ 均值 ${stats['单票均值成本_usd']:.4f}")
    else:
        print("花费：暂无成本记录（老票没有 usage 字段，不影响其余指标）")
    print("分桶：" + "；".join(f"{k}={v}" for k, v in sorted(buckets.items(), key=lambda kv: -kv[1])))
    if trace_n:
        t = stats["探索轮次（PI_TRACE=1 的票）"]
        print(f"探索轮次（{t['样本数']} 票有轨迹）：平均工具调用 {t['平均工具调用']} 次"
              f"（其中探索型 {t['平均探索型调用']} 次）｜平均环境坑命中 {t['平均环境坑命中']} 次")
    for d, v in stats["按天"].items():
        print(f"  {d}  票数={v['票数']}  中位={v['中位秒']:.0f}s  白跑={v['白跑']}")
    return 0


def cmd_verify_numbers(args):
    """自检：账本直算 vs `report --json` 必须一致（口径默认 live，排除 kind=test/exp）。
    不再硬编码快照数字 —— 数据只增不减，硬编码会每次真票都假报警；改为两条代码路径交叉校验。
    """
    recs, _ = load()
    deleg = [r for r in recs if r.get("cmd") == "deleg" and r.get("kind") not in ("test", "exp")
             and source_of(r) == "live"]
    durs = sorted(r.get("dur_s", 0) for r in deleg)
    got = {"票数": len(deleg), "中位": statistics.median(durs) if durs else None,
           "最长": max(durs) if durs else None, "最小": min(durs) if durs else None}
    import subprocess
    try:
        out = subprocess.run([sys.executable, os.path.abspath(__file__), "report", "--json"],
                             capture_output=True, text=True, encoding="utf-8")
        rep = json.loads(out.stdout)
    except Exception as e:                                    # noqa: BLE001
        print(f"自检不通过：report 无法解析（{e}）")
        return 1
    exp = {"票数": rep.get("委托票数"), "中位": rep.get("耗时_中位"),
           "最长": rep.get("耗时_最长"), "最小": rep.get("耗时_最小")}
    ok = got == exp
    print(f"{'基准':<6}{'report':<10}{'直算':<10}")
    for k in exp:
        print(f"{k:<6}{exp[k]!s:<10}{got[k]!s:<10}{'OK' if exp[k] == got[k] else 'MISMATCH'}")
    print(("自检通过" if ok else "自检不通过") +
          f"（live 票 {len(deleg)}；另有 {sum(1 for r in recs if r.get('cmd') == 'deleg' and source_of(r) != 'live')} 条非 live 已排除）")
    return 0 if ok else 1


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == "append":
        return cmd_append(rest)
    if cmd == "import-legacy":
        return cmd_import(rest)
    if cmd == "report":
        return cmd_report(rest)
    if cmd == "verify-numbers":
        return cmd_verify_numbers(rest)
    if cmd == "trace-stats":
        return cmd_trace_stats(rest)
    if cmd == "cost":
        return cmd_cost(rest)
    print(f"未知子命令: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
