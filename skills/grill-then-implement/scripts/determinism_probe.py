#!/usr/bin/env python3
"""确定性探针：同一请求跑 N 次，比较输出逐字哈希（用于 A/B 标定的噪声下限）。

背景（DeepInfer 给的想法，2026-10-21）：它把 **batch-invariant inference + deterministic sampling**
做成了显式开关（`DEEPINFER_BATCH_INVARIANT=1` + 固定 `seq_seed`）。我们的成本路由标定 / A/B 实验
同样需要"同输入 ⇒ 同输出"，否则差异里混着采样噪声，结论不可比。

用法（OpenAI 兼容端点，如 DGX vLLM）：
    python determinism_probe.py --base http://192.168.5.68:8001/v1 --model qwen3.8-27b --runs 3
    python determinism_probe.py --base https://api.deepseek.com/v1 --model deepseek-v4-flash --runs 3 --key-env DEEPSEEK_API_KEY
输出：每次的 sha256 前缀 + 是否全同；rc=0 全同 / 1 有差异 / 3 连不上。
提示：temperature>0 时必然不同，本脚本固定 temperature=0 且带 seed；若仍不同 ⇒ 该后端不确定 ⇒
      标定结论必须写"噪声下限 = 不一致率 X/3"，或换 batch-invariant 后端。
"""
import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

PROMPT = "只输出这一行，不要任何解释：wfctl determinism probe ok"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="…/v1")
    ap.add_argument("--model", required=True)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--key-env", default="", help="读哪个环境变量当 Bearer（本地 vLLM 可不填）")
    ap.add_argument("--max-tokens", type=int, default=32)
    ap.add_argument("--timeout", type=int, default=120)
    a = ap.parse_args()

    key = os.environ.get(a.key_env, "").strip() if a.key_env else ""
    body = json.dumps({
        "model": a.model,
        "messages": [{"role": "user", "content": PROMPT}],
        "temperature": 0,
        "seed": 42,
        "max_tokens": a.max_tokens,
    }, ensure_ascii=False).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"

    hashes, texts = [], []
    for i in range(1, a.runs + 1):
        req = urllib.request.Request(a.base.rstrip("/") + "/chat/completions", data=body,
                                     headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=a.timeout) as r:
                d = json.loads(r.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as e:
            print(f"run{i}: HTTP {e.code} {e.read()[:200]!r}", file=sys.stderr)
            return 3
        except Exception as exc:
            print(f"run{i}: 连接失败 {type(exc).__name__}: {exc}", file=sys.stderr)
            return 3
        txt = d["choices"][0]["message"]["content"]
        h = hashlib.sha256(txt.encode("utf-8")).hexdigest()[:12]
        hashes.append(h)
        texts.append(txt)
        print(f"run{i}: sha={h}  out={txt.strip()[:60]!r}")

    same = len(set(hashes)) == 1
    print(f"\n{'逐字一致' if same else '不一致'}：{len(set(hashes))} 种输出 / {a.runs} 次")
    if not same:
        print("  ⇒ 该后端在 temperature=0 下仍不确定：A/B 结论必须带噪声下限，或换 batch-invariant 后端")
    return 0 if same else 1


if __name__ == "__main__":
    sys.exit(main())
