#!/usr/bin/env python3
"""DeepSeek 官方 Search / Fetch 客户端（阶段 0 的证据采集器）。

严格按官方文档实现：https://api-docs.deepseek.com/zh-cn/guides/search/
  POST https://api.deepseek.com/v1/tools/search   {"query","count","ori_question","localization","need_content"}
  POST https://api.deepseek.com/v1/tools/fetch    {"url"}
鉴权：Authorization: Bearer <DEEPSEEK_API_KEY>；Content-Type: application/json

与「家目录插件 plugins/deepseek-native」的区别（两条通道，别混）：
  · 本脚本 = **官方结构化 Search API**：一次纯搜索请求，返回 rerank_score/title/url/snippet/summary/
    content/site_name/date/authority（need_content=False 时 content 为空串）；计费 ¥5/1000 次成功请求；
    账号级 QPS=5（Search 与 Fetch 各自独立）。
  · 插件 deepseek_native = 走 `POST /v1/responses` + 服务端 web_search 工具（模型 deepseek-v4-pro，
    tool_choice=required），来源靠从回答文本里正则抓 URL ⇒ 慢、按 token 计费、无结构化元数据。
    通用 `web_search` 工具仍用它（有 Tavily 兜底）；**阶段 0 的证据采集用本脚本**。

误差与重试（照抄官方）：408 / 429 / 5xx ⇒ 等待后重试；402 ⇒ 余额不足（停）；其它 4xx ⇒ 不重试。
限速：官方 QPS=5（账号级，与 key 无关）⇒ 本脚本用状态文件做 ≤5 次/秒 的节流，不越限、不白吃 429。

用法：
    python ds_search.py "<query>" [--count 5] [--content] [--ori-question Q] [--localization IP]
    python ds_search.py --fetch <url>
    python ds_search.py "<query>" --md            # 输出可直接粘进 lookup.md 的 Markdown 表
退出码：0 成功；2 上游 4xx（不重试）；3 重试后仍失败；4 余额不足（402）
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://api.deepseek.com"
SEARCH_URL = BASE + "/v1/tools/search"
FETCH_URL = BASE + "/v1/tools/fetch"
TIMEOUT = 45
QPS_LIMIT = 5                      # 官方：账号级，Search 与 Fetch 各自独立
MIN_INTERVAL = 1.0 / QPS_LIMIT     # 0.2s
STATE = os.path.join(os.environ.get("HC_HOME") or os.path.join(os.path.expanduser("~"), "AppData", "Local", "hermes"), "cache",
                     "deepseek_search_qps.json")
ENV_FILE = os.environ.get("HC_ENV_FILE") or os.path.join(os.environ.get("HC_HOME") or os.path.join(os.path.expanduser("~"), "AppData", "Local", "hermes"), ".env")


def api_key():
    key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if not key and os.path.exists(ENV_FILE):
        for line in open(ENV_FILE, encoding="utf-8", errors="replace"):
            if line.startswith("DEEPSEEK_API_KEY="):
                key = line.split("=", 1)[1].strip()
                break
    return key


def throttle():
    """≤5 次/秒：按状态文件里上一次请求时间做最小间隔等待（跨进程也生效）。"""
    now = time.time()
    last = 0.0
    try:
        last = float(json.load(open(STATE, encoding="utf-8")).get("last", 0.0))
    except Exception:
        pass
    wait = MIN_INTERVAL - (now - last)
    if wait > 0:
        time.sleep(wait)
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        json.dump({"last": time.time()}, open(STATE, "w", encoding="utf-8"))
    except Exception:
        pass


def post(url, payload, key):
    """返回 (status, dict|raw)。408/429/5xx 重试 ≤2 次（指数退避，尊重 Retry-After）。"""
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")   # 中文必须走 UTF-8 字节，别用 shell -d
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json",
               "Accept": "application/json"}
    delays = [1, 3]
    last_status, last_raw = None, b""
    for attempt in range(3):
        throttle()
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                return int(r.status), json.loads(r.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as e:
            raw = e.read() or b""
            last_status, last_raw = int(e.code), raw
            if e.code == 402:
                return 402, {"error": {"message": "402 余额不足（充值后再试）"}}
            if e.code in (408, 429) or 500 <= e.code < 600:
                ra = e.headers.get("Retry-After")
                if ra and ra.isdigit():
                    delays[attempt] = max(1, int(ra))
                if attempt < 2:
                    time.sleep(delays[attempt])
                    continue
                break
            return int(e.code), {"error": {"message": raw.decode("utf-8", "replace")[:300]}}
        except Exception as exc:
            last_status, last_raw = 0, str(exc).encode()
            if attempt < 2:
                time.sleep(delays[attempt])
                continue
            break
    return last_status or 0, {"error": {"message": last_raw.decode("utf-8", "replace")[:300]}}


def md_table(results):
    out = ["| # | rerank | 权威 | 日期 | 站点 | 标题 | URL |", "|---|---|---|---|---|---|---|"]
    for i, r in enumerate(results, 1):
        date = (r.get("date") or "")[:10]
        out.append(f"| {i} | {r.get('rerank_score')} | {r.get('authority')} | {date} | "
                   f"{(r.get('site_name') or '')} | {(r.get('title') or '').replace('|', '/')[:60]} | {r.get('url')} |")
    out.append("")
    for i, r in enumerate(results, 1):
        s = (r.get("summary") or r.get("snippet") or "").replace("\n", " ")
        if s:
            out.append(f"- **[{i}] 摘要**：{s[:400]}")
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    key = api_key()
    if not key:
        print("缺 DEEPSEEK_API_KEY（环境变量或 $HC_HOME/.env）", file=sys.stderr)
        return 3

    if args[0] == "--fetch":
        url = args[1]
        status, data = post(FETCH_URL, {"url": url}, key)
        if status != 200:
            print(f"Fetch 失败 HTTP {status}: {data.get('error', {})}", file=sys.stderr)
            return 2 if 400 <= status < 500 and status not in (402, 408, 429) else 3
        print(f"# {data.get('title') or '(no title)'}\n\n{data.get('content') or ''}")
        return 0

    query = args[0]
    opts = {"count": 5, "need_content": False, "ori_question": None, "localization": None, "md": False}
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--count" and i + 1 < len(args):
            opts["count"] = max(1, min(50, int(args[i + 1]))); i += 2
        elif a == "--content":
            opts["need_content"] = True; i += 1
        elif a == "--ori-question" and i + 1 < len(args):
            opts["ori_question"] = args[i + 1]; i += 2
        elif a == "--localization" and i + 1 < len(args):
            opts["localization"] = args[i + 1]; i += 2
        elif a == "--md":
            opts["md"] = True; i += 1
        else:
            i += 1

    payload = {"query": query, "count": opts["count"], "need_content": opts["need_content"]}
    if opts["ori_question"]:
        payload["ori_question"] = opts["ori_question"]
    if opts["localization"]:
        payload["localization"] = opts["localization"]

    status, data = post(SEARCH_URL, payload, key)
    if status != 200:
        print(f"Search 失败 HTTP {status}: {json.dumps(data, ensure_ascii=False)[:300]}", file=sys.stderr)
        return 4 if status == 402 else (2 if 400 <= status < 500 and status not in (408, 429) else 3)

    results = data.get("results") or []
    if opts["md"]:
        print(md_table(results))
    else:
        print(f"# Search: {query}  (results={len(results)}, count={opts['count']}, "
              f"need_content={opts['need_content']})")
        for i, r in enumerate(results, 1):
            print(f"\n[{i}] rerank={r.get('rerank_score')} authority={r.get('authority')} "
                  f"date={(r.get('date') or '')[:10]} site={r.get('site_name')}")
            print(f"    {r.get('title')}")
            print(f"    {r.get('url')}")
            print(f"    {(r.get('summary') or r.get('snippet') or '')[:300]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
