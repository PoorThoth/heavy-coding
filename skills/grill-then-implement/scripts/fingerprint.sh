#!/usr/bin/env bash
# 行为等价性指纹 —— 证明"改动前后行为一致"，比"测试全绿"更强（Pitfall 87）
#
# 用法（在项目根执行）：
#   fingerprint.sh record <名字> "<产生输出的命令>"   # 记录基线（存 .fingerprints/<名字>.txt + .sha256）
#   fingerprint.sh verify <名字> "<产生输出的命令>"   # 复跑并逐位比对（不一致 = 非零退出）
#   fingerprint.sh list                                # 列出已记录基线
#   fingerprint.sh show   <名字>                       # 打印基线与当前 sha
#   fingerprint.sh diff   <名字>                       # 与基线差异（前 40 行）
#
# 要点：
#   ① 命令输出必须**可复现**（无时间戳/随机数/绝对路径/耗时）——不确定就先 record 两次比对；
#   ② 输出里请包含**逐笔/逐点明细 + 关键统计**，而不是只 print "ok"（覆盖面决定证明力）；
#   ③ 标准用法：改之前 record → 改之后 verify → **逐位一致**才算重构成功。
#
# 环境变量：FINGERPRINT_DIR（默认 .fingerprints）
set -uo pipefail

DIR="${FINGERPRINT_DIR:-.fingerprints}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}

short() { cut -c1-16; }

run_cmd() { # $1 = 命令；输出到 stdout
  local c="$1"
  eval "$c" 2>&1
}

action="${1:-}"
[ -z "$action" ] && usage 0

case "$action" in
  record)
    name="${2:-}"; cmd="${3:-}"
    [ -n "$name" ] && [ -n "$cmd" ] || usage 2
    mkdir -p "$DIR"
    out="$(run_cmd "$cmd")" || true
    if [ -z "$out" ]; then echo "❌ 命令无输出——指纹必须有可比对的内容（先检查命令）"; exit 1; fi
    printf '%s\n' "$out" > "$DIR/$name.txt"
    printf '%s\n' "$out" | hash_of > "$DIR/$name.sha256"
    echo "✅ 已记录基线 '$name'：sha256=$(short < "$DIR/$name.sha256")…  行数=$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    ;;
  verify)
    name="${2:-}"; cmd="${3:-}"
    [ -n "$name" ] && [ -n "$cmd" ] || usage 2
    [ -f "$DIR/$name.sha256" ] || { echo "❌ 没有基线 '$name'——先跑 record"; exit 2; }
    out="$(run_cmd "$cmd")" || true
    now=$(printf '%s\n' "$out" | hash_of)
    was=$(cat "$DIR/$name.sha256")
    if [ "$now" = "$was" ]; then
      echo "✅ 行为一致：'$name' sha256=$(echo "$now" | short)…（与基线逐位相同）"
      exit 0
    fi
    printf '%s\n' "$out" > "$DIR/$name.actual.txt"
    echo "❌ 行为**已改变**：'$name'"
    echo "   基线 sha256=$(echo "$was" | short)…"
    echo "   现在 sha256=$(echo "$now" | short)…"
    echo "   差异（前 40 行，< 基线 / > 现在）："
    diff "$DIR/$name.txt" "$DIR/$name.actual.txt" | head -40 | sed 's/^/   /'
    echo "   提示：若你确实要改行为，用 record 重新建立基线（并说明为什么）。"
    exit 1
    ;;
  list)
    [ -d "$DIR" ] || { echo "（还没有任何基线）"; exit 0; }
    for f in "$DIR"/*.sha256; do
      [ -f "$f" ] || continue
      printf '%-30s %s…\n' "$(basename "$f" .sha256)" "$(short < "$f")"
    done
    ;;
  show)
    name="${2:-}"; [ -n "$name" ] || usage 2
    [ -f "$DIR/$name.sha256" ] || { echo "❌ 没有基线 '$name'"; exit 2; }
    echo "基线 '$name' sha256=$(cat "$DIR/$name.sha256")  行数=$(wc -l < "$DIR/$name.txt" | tr -d ' ')"
    ;;
  diff)
    name="${2:-}"; [ -n "$name" ] || usage 2
    [ -f "$DIR/$name.txt" ] && [ -f "$DIR/$name.actual.txt" ] || { echo "❌ 需要基线 + 一次 verify 产生的 .actual.txt"; exit 2; }
    diff "$DIR/$name.txt" "$DIR/$name.actual.txt" | head -60
    ;;
  -h|--help|help) usage 0 ;;
  *) usage 2 ;;
esac
