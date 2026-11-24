#!/usr/bin/env python3
"""事件流瘦身器 —— 折叠 message_update 增量帧（正文丢弃，只留计数）。

背景（实测 2026-10-18）：单票事件流 10.3MB / 17.3MB，其中 ~76% 是 `message_update`
（流式增量正文）。settled / stop_reason / tokens / 最终文本只依赖 message_end、
turn_end、agent_settled 与 usage —— 增量帧对判定毫无用处，纯占盘。

用法：
  wfctl.sh deleg ... --mode json        # 执行端 stdout 经本脚本落盘（流式折叠）
  python slim_events.py --in <原始> --out <新>     # 事后瘦身（rpc 路径用）
  python slim_events.py --in-place <文件>          # 就地瘦身（原子替换）

行为：
  * `{"type":"message_update",...}` 整行丢弃，只累计计数；
  * 每累计 --flush-every 条（默认 64）写一行折叠标记
    `{"type":"message_update_collapsed","count":N}` —— 保持文件有增长（看门狗采样用），
    且解析侧忽略未知 type，不影响判定；
  * 其余事件**逐字节原样**写出；非 JSON 行也原样保留（不静默丢数据）；
  * 每条写出即 flush（json 模式看门狗靠文件增长判活）。
"""
import argparse
import os
import re
import sys

PAT = re.compile(rb'"type"\s*:\s*"message_update"')


def _open_src(path):
    if path:
        return open(path, "rb")
    return sys.stdin.buffer


def slim(src, dst, flush_every=64):
    dropped = 0
    kept = 0
    bytes_in = 0
    bytes_out = 0
    pending = 0

    def flush_marker():
        nonlocal pending, bytes_out
        if pending:
            line = b'{"type":"message_update_collapsed","count":%d}\n' % pending
            dst.write(line)
            bytes_out += len(line)
            pending = 0

    try:
        for line in src:
            bytes_in += len(line)
            if PAT.search(line):
                dropped += 1
                pending += 1
                if pending >= max(1, flush_every):
                    flush_marker()
                    dst.flush()
                continue
            flush_marker()
            if not line.endswith(b"\n"):
                line += b"\n"
            dst.write(line)
            bytes_out += len(line)
            kept += 1
            dst.flush()
        flush_marker()
    finally:
        dst.flush()
    return {"dropped": dropped, "kept": kept, "bytes_in": bytes_in, "bytes_out": bytes_out}


def main(argv=None):
    ap = argparse.ArgumentParser(description="折叠 message_update 的事件流瘦身器")
    ap.add_argument("--in", dest="inp", default="", help="输入文件（缺省=stdin）")
    ap.add_argument("--out", default="", help="输出文件")
    ap.add_argument("--in-place", dest="in_place", default="", help="就地瘦身（原子替换）")
    ap.add_argument("--flush-every", type=int, default=64, help="每 N 条增量写一次折叠标记")
    ap.add_argument("--stats", action="store_true", help="向 stderr 打印统计")
    a = ap.parse_args(argv)

    if a.in_place:
        tmp = a.in_place + ".slim.tmp"
        with _open_src(a.in_place) as src, open(tmp, "wb") as dst:
            st = slim(src, dst, a.flush_every)
        os.replace(tmp, a.in_place)
    elif a.out:
        with _open_src(a.inp) as src, open(a.out, "wb") as dst:
            st = slim(src, dst, a.flush_every)
    else:
        ap.error("需要 --out 或 --in-place")

    if a.stats:
        pct = 100.0 * (1 - st["bytes_out"] / st["bytes_in"]) if st["bytes_in"] else 0.0
        sys.stderr.write(
            "slim: dropped=%d kept=%d bytes %d -> %d (-%.1f%%)\n"
            % (st["dropped"], st["kept"], st["bytes_in"], st["bytes_out"], pct)
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
