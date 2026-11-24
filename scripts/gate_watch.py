#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gate_watch.py — 工作流门禁巡检（零 token，cron no_agent 脚本）

语义：entry（AGENTS.md 锚点 + code-gate 技能 + wfctl 凭据自动加载）落地的锚点日由 HC_ANCHOR 给。
     从锚点日起满 WINDOW_DAYS 天后，若这 14 天内【没有任何 deleg 票】且【没有任何新 converge 报告】
     ⇒ 说明流程又被绕开了，报警一次（7 天内同因不重复）。
     另外做三个"入口失窃"检查：锚点被删 / 技能被删 / key 自动加载被改没 —— 命中立即报。

输出：健康时 stdout 为空（cron 不投递）；异常时打印一小段中文。
退出码恒为 0（避免 cron 把告警当失败）。
"""
import argparse
import datetime as dt
import glob
import json
import os
import sys

HOME = os.path.expanduser("~")
HC = os.environ.get("HC_HOME") or os.path.join(HOME, "AppData", "Local", "hermes")
LEDGER = os.environ.get("HC_LEDGER") or os.path.join(HC, "run_ledger.jsonl")
AGENTS = os.environ.get("HC_AGENTS") or os.path.join(HOME, "AGENTS.md")
SKILL = os.environ.get("HC_GATE_SKILL") or os.path.join(
    HC, "skills", "software-development", "code-gate", "SKILL.md")
WFCTL = os.environ.get("HC_WFCTL") or os.path.join(
    HC, "skills", "software-development", "grill-then-implement", "scripts", "wfctl.sh")
ENVFILE = os.environ.get("HC_ENV_FILE") or os.path.join(HC, ".env")
STATE = os.path.join(HC, "cache", "gate_watch_state.json")
# 要看哪几个仓库：逗号分隔，不设就不查仓库（只查入口与账本）
REPOS = [p.strip() for p in (os.environ.get("HC_WATCH_REPOS") or "").split(",") if p.strip()]

ANCHOR = dt.date.fromisoformat(os.environ.get("HC_ANCHOR") or "2026-11-25")
WINDOW_DAYS = 14
COOLDOWN_DAYS = 7
SKIP_SOURCES = {"test", "exp"}          # 自测/实验票不算真用


def load_state(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_state(path, st):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(st, fh, ensure_ascii=False, indent=1)
    except Exception:
        pass


def deleg_stats(since, ledger=LEDGER):
    """返回 (窗口内真票数, 全局最后一张票的时间)；只认 cmd=deleg，envcheck/preflight 这类不算"""
    n, last = 0, None
    try:
        with open(ledger, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if r.get("cmd") != "deleg":
                    continue
                if (r.get("source") or "live") in SKIP_SOURCES or r.get("kind") in SKIP_SOURCES:
                    continue
                ts = r.get("ts") or ""
                if last is None or ts > last:
                    last = ts
                try:
                    when = dt.datetime.fromisoformat(ts.split("+")[0].split("Z")[0]).date()
                except Exception:
                    continue
                if when >= since:
                    n += 1
    except OSError:
        return 0, None
    return n, last


def converge_stats(since):
    """返回 (窗口内新报告数, 全局最新日期)"""
    n, newest = 0, None
    for repo in REPOS:
        for p in glob.glob(os.path.join(repo, ".agents", "converge-*.md")):
            try:
                d = dt.date.fromtimestamp(os.path.getmtime(p))
            except OSError:
                continue
            if newest is None or d > newest:
                newest = d
            if d >= since:
                n += 1
    return n, newest


def entry_ok(agents_path=AGENTS):
    """入口四件：锚点 / 技能 / key 自动加载 / key 文件可读。返回缺失项列表。"""
    bad = []
    try:
        with open(agents_path, encoding="utf-8", errors="replace") as fh:
            if "CODE-GATE:START" not in fh.read():
                bad.append("~/AGENTS.md 的 CODE-GATE 锚点不见了")
    except OSError:
        bad.append("~/AGENTS.md 读不到")
    if not os.path.exists(SKILL):
        bad.append("code-gate 技能文件不见了")
    try:
        with open(WFCTL, encoding="utf-8", errors="replace") as fh:
            if "_load_env_key" not in fh.read():
                bad.append("wfctl 的 key 自动加载被改没了")
    except OSError:
        bad.append("wfctl.sh 读不到")
    if not os.path.exists(ENVFILE):
        bad.append(".env 不存在（Pi 会 rc=0 静默白跑）")
    else:
        try:
            with open(ENVFILE, encoding="utf-8", errors="replace") as fh:
                if "DEEPSEEK_API_KEY=" not in fh.read():
                    bad.append(".env 里没有 DEEPSEEK_API_KEY")
        except OSError:
            bad.append(".env 读不到")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--now", help="测试用：YYYY-MM-DD 覆盖今天")
    ap.add_argument("--state", default=STATE)
    ap.add_argument("--agents", default=AGENTS)
    ap.add_argument("--force", action="store_true", help="忽略冷却，强制出一条")
    ap.add_argument("--ledger", default=LEDGER, help="测试用：换一个账本文件")
    a = ap.parse_args()

    today = dt.date.fromisoformat(a.now) if a.now else dt.date.today()

    try:
        bad_entry = entry_ok(a.agents)
        since = today - dt.timedelta(days=WINDOW_DAYS)
        n_deleg, last_deleg = deleg_stats(since, a.ledger)
        n_conv, newest_conv = converge_stats(since)

        msgs, reason = [], ""
        if bad_entry:
            reason = "entry"
            msgs.append("【入口坏了】" + "；".join(bad_entry))
            msgs.append("修：重跑 code-gate 落地三件（~/AGENTS.md 锚点 / 技能 code-gate / wfctl 的 _load_env_key）")

        mature = (today - ANCHOR).days >= WINDOW_DAYS
        if mature and n_deleg == 0 and n_conv == 0:
            reason = (reason + "+stale") if reason else "stale"
            msgs.append("【门禁 %d 天没用过】%s ~ %s：deleg 票 %d · 新 converge 报告 %d"
                        % (WINDOW_DAYS, since, today, n_deleg, n_conv))
            msgs.append("最后一条票：%s ｜ 最后一份 converge：%s"
                        % (last_deleg or "无", newest_conv or "无"))
            msgs.append("要么挑一票按 code-gate 重模式跑通，要么把规范改成轻模式（别让图和实操各走各的）。")

        st = load_state(a.state)
        if msgs and not a.force:
            try:
                last = dt.date.fromisoformat(st.get("last_alert", ""))
                if st.get("reason") == reason and (today - last).days < COOLDOWN_DAYS:
                    return 0
            except Exception:
                pass

        if msgs:
            st.update({"last_alert": today.isoformat(), "reason": reason})
            save_state(a.state, st)
            print("工作流门禁巡检 · %s" % today.isoformat())
            print("\n".join(msgs))
    except Exception as exc:                     # 巡检自身出错也要看得见，但别当失败
        print("gate_watch 自身异常：%s: %s" % (type(exc).__name__, exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
