#!/usr/bin/env bash
# =============================================================================
# selftest_wfctl.sh — wfctl deleg 四条护栏的正反例自证（CR7）
#
# 不碰真 DeepSeek：用 PI_BIN 指向假执行端（临时脚本），只验护栏逻辑本身。
# 用法: bash scripts/selftest_wfctl.sh        # rc=0 = 全过
#
# 用例（期望值来自 D:/wf-test/logs/p3_wfctl_hardening/SPEC.md）：
#   ① 看门狗     假执行端 sleep 300 + --stall-timeout 3 ⇒ ≤13s 被杀、rc=124、打印 STALLED after
#   ② 预期产物   expect 不存在的文件 ⇒ rc=3 + MISSING；expect 存在的文件 ⇒ rc 不变
#   ③ 单票锁     后台占锁再跑 ⇒ rc=4 + another deleg is running
#   ④ 实测事实   缺行 ⇒ rc=5；写「实测事实: 不适用（…）」⇒ 放行
#   ⑤ 正常任务   rc=0
#   ⑥ 账本字段   stalled/missing 入库
#   ⑦ 密钥外泄   假执行端发 stopReason=error + errorMessage=No API key found ⇒ rc≠0、输出无 sk-*/长串/命令替换
#   ⑧ 事件完成   事件流含 agent_settled ⇒ rc=0，stdout 只悬最终文本（无原始 JSONL），事件已落盘
#   ⑨ 异常结束   message_end stopReason=error ⇒ rc=6，并打印 stop_reason
#   ⑩ 无 settled 进程退出但无 agent_settled ⇒ rc=7 + NO agent_settled
#   ⑪ 静默超时   发 1 条事件后静默超过 stall ⇒ rc=124
#   ⑫ 白跑判定   rc=0/dur=5s/out=50B/**settled=1** ⇒ 不计白跑（有终止事件=真跑完）
#   ⑬ 白跑判定   同上但 settled=0 ⇒ 计白跑
#   ⑭ 白跑判定   同上但**无 settled 字段**（老票）⇒ 仍计白跑（历史兼容，不翻旧账）
#   ⑮ 白跑判定   rc=0/dur=120s/out=5000B/settled=0 ⇒ 不计白跑（旧规则本来就不算）
#   ⑯ 账本类型   新写记录的 settled/missing 是 JSON 数字（int），不是字符串
#   ⑰ 读取兼容   老记录 settled:"1"（字符串）仍按整数 1 处理，白跑判定与整数版一致
#   ⑱ 杀进程树   假执行端 spawn `sleep 300` 孙进程 ⇒ 停滞被杀后 5s 内孙进程必须不存在（CR1）
#   ⑲ 会话可续   启动参数里出现 `--session <promptdir>/pi-session`，ledger 记 session（CR2）
#   ⑳ 续跑提示   rc=6/7/124 时打印「可续跑：wfctl.sh deleg <dir> <brief> --continue」（CR2）
#   ㉑ 成本记账   事件流带 usage ⇒ ledger 记 in/out_tokens + cost_usd，baseline 有总花费（CR3）
#   ㉒ 无 usage   事件流不带 usage ⇒ 不写 tokens/cost，不崩（CR3）
#   ㉓ RPC 正常   --stop-mode rpc 等 agent_settled ⇒ rc=0，事件落盘，未退化 kill（CR4）
#   ㉔ RPC abort  停滞 ⇒ 发出 {"type":"abort"} 帧，abort 生效（≤10s）后 rc=124（CR4）
#   ㉕ RPC 退化   执行端不理 abort ⇒ >10s 后退化杀进程树（连孙进程），rc=124（CR4）
#   ㉖ driver 正常 直调 rpc_driver.py：prompt 帧 ⇒ agent_settled ⇒ rc=0（CR4 修正）
#   ㉗ driver 异常 stopReason=error ⇒ rc=6（CR4 修正）
#   ㉘ driver 早退 进程退出但无 settled ⇒ rc=7（CR4 修正）
#   ㉙ driver 杀树 忽略 abort ⇒ abort 帧 + 宽限后 taskkill /T /F，孙进程消失，rc=124（CR4 修正）
#   ㉚ json 工具中 发 tool_execution_start 后静默 >阈值 ⇒ **不得**判停滞（A 验收）
#   ㉛ rpc 工具中 同上（driver 侧工具感知）⇒ rc=0（A 验收）
#   ㉜ 事件瘦身   message_update 折叠后体积降 ≥60%，settled/stop_reason/tokens/文本逐项一致（C）
#   ㉝ verify 绿   go 工程 + converge --strict + 账本全绿 ⇒ rc=0（D）
#   ㉞ verify 红   人为弄红一个 go test ⇒ rc=1 且指出项（D）
#   ㉟ verify 账本 账本 rc≠0 ⇒ rc=1 且打印本票账本项（本票 rc/cost/tokens）
#   ㊱ gofmt CRLF 全 CRLF 但缩进正确的仓库 ⇒ gofmt 项不得判红（仅换行差异已忽略）
#   ㊲ gofmt 真乱 CRLF + 缩进错乱 ⇒ gofmt 项 rc=1 且指出该文件（真实红保留）
#   ㊳ 来源分流   默认 live / WFCTL_LEDGER_SOURCE=selftest / --source 优先；report 默认只算 live 并报「已排除 N 条」，--all 看全部
#   ㊴ 基线隔离   追加 3 条 selftest 后 baseline 票数不变，--all 才 +3
#   ㊵ converge 骨架带 `文件.go:行号`，填真 file:line ⇒ --strict PASS；删掉 ⇒ FAIL 且提示「证据须为 文件:行」
#
# ⑫–⑰ 只碰临时账本（WF_LEDGER 指向 $TMP），不污染真 run_ledger.jsonl。
#
# ⑧–⑪ 与 ⑦ 默认走 `--mode json`（假执行端伪造 JSONL 事件，不真调模型）；print 旧路径见 IMPL_JSON.md 演练。
#
# ⑦ 反例自证（不必自动化）：把 wfctl.sh 的 No-API-key fail 消息改回带
#   `"$(grep -m1 ... .env | cut -d= -f2-)"` 的版本后重跑本脚本 —— ⑦ 必 FAIL
#   （fail 用 printf 打印，不会真的执行；但消息里会留下 "$(" 字面片段，⑦ 的
#     `grep -Eq '\$\(|`'` 断言会命中。若某天该消息被 eval/命令替换执行，则会直接
#     回显真 key，⑦ 的 sk-* 与 32 位长串断言也会命中）。
# =============================================================================
set -uo pipefail

# 本脚本所有落账（含 wfctl 子进程）一律 source=selftest —— 假执行端的 2 秒票绝不能混进 live，
# 否则 baseline 的成功率/白跑率/成本全错（真实踩过：149 条里 98 条是自测噪声）。
export WFCTL_LEDGER_SOURCE=selftest

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$SCRIPTS_DIR/wfctl.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wfctl-selftest.XXXXXX")"
LOCK=""
cleanup() {
  [ -n "${BG_PID:-}" ] && kill -9 "$BG_PID" 2>/dev/null
  [ -n "$LOCK" ] && rm -f "$LOCK" 2>/dev/null
  # 孙进程若因失败而残留，按 winpid 收尾（MSYS pid 杀不到原生 sleep.exe）
  local w
  for f in "$TMP"/*.gcwin; do
    [ -f "$f" ] || continue
    w="$(cat "$f" 2>/dev/null || true)"
    [ -n "$w" ] && MSYS2_ARG_CONV_EXCL='*' taskkill /F /PID "$w" >/dev/null 2>&1 || true
  done
  # WF_SELFTEST_KEEP=1 ⇒ 保留临时目录（取证用，例如把 RPC 帧日志抄进 IMPL.md）
  if [ -n "${WF_SELFTEST_KEEP:-}" ]; then
    printf '== 保留临时目录: %s ==\n' "$TMP"
  else
    rm -rf "$TMP" 2>/dev/null
  fi
}
trap cleanup EXIT

PASS=0; FAILN=0
ok()  { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf 'FAIL %s | 期望: %s | 实际: %s\n' "$1" "$2" "$3"; FAILN=$((FAILN+1)); }

# ---------------------------------------------------------------- 假执行端
FAKE="$TMP/fake_pi.sh"
cat > "$FAKE" <<'FAKEEOF'
#!/usr/bin/env bash
# 假 Pi：吃掉 stdin（真 Pi 从管道读任务书），按 FAKE_MODE 行为。
# rpc* 模式例外：stdin 是 RPC 帧流（保持打开），不能先吃掉。
# 事件流工厂：$1=最终文本 $2=stopReason [$3=errorMessage] [$4=usage JSON]
ev_stream() {
  printf '{"type":"session","version":3}\n'
  printf '{"type":"agent_start"}\n'
  printf '{"type":"message_start","message":{"role":"assistant","content":[]}}\n'
  printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"%s"}],"stopReason":"%s","errorMessage":"%s"%s}}\n' \
    "$1" "$2" "${3:-}" "${4:+,${DQ}usage${DQ}:$4}"
}
DQ='"'

# CR1 孙进程：写 msys pid + Win32 pid（MSYS pid 杀不到原生 sleep.exe，测试必须用 winpid 验死）
spawn_gc() {
  sleep 300 &
  echo $! > "${FAKE_GC_PID:-/dev/null}"
  cat "/proc/$!/winpid" > "${FAKE_GC_WINPID:-/dev/null}" 2>/dev/null || true
}

# 原生孙进程（Windows python.exe）：taskkill /T /F 能可靠抓到
spawn_gc_py() {
  python -c 'import time; time.sleep(300)' &
  echo $! > "${FAKE_GC_PID:-/dev/null}"
  cat "/proc/$!/winpid" > "${FAKE_GC_WINPID:-/dev/null}" 2>/dev/null || true
}

case "${FAKE_MODE:-ok}" in
  rpc*)
    IFS= read -r frame || true                 # prompt 帧（单行 JSON），落盘供断言
    printf 'PROMPT %s\n' "$frame" >> "${FAKE_RPC_LOG:-/dev/null}"
    printf '{"type":"response","command":"prompt","success":true}\n'
    printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"rpc 最终答复"}],"stopReason":"stop","usage":{"input":1500,"output":250}}}\n'
    if [ "$FAKE_MODE" = "rpcok" ]; then
      printf '{"type":"agent_settled"}\n'
      cat >/dev/null                           # 等 wfctl 关 stdin（EOF）后退出
      exit 0
    fi
    if [ "$FAKE_MODE" = "rpctool" ]; then
      # A 验收（rpc）：工具执行中被静默 >阈值 ⇒ driver 不得误发 abort
      printf '{"type":"tool_execution_start","toolCallId":"t1","toolName":"bash"}\n'
      sleep 8
      printf '{"type":"tool_execution_end","toolCallId":"t1","toolName":"bash"}\n'
      printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"rpc 工具跑完了"}],"stopReason":"stop"}}\n'
      printf '{"type":"agent_settled"}\n'
      cat >/dev/null
      exit 0
    fi
    # ㉕ 的孙进程必须是**原生**进程（taskkill /T /F 才抓得到；MSYS 的sleep 可能漏）
    [ "$FAKE_MODE" = "rpcgc" ] && spawn_gc_py
    while IFS= read -r l; do                   # rpchang / rpcdead：等 abort 帧
      printf 'FRAME %s\n' "$l" >> "${FAKE_RPC_LOG:-/dev/null}"
      case "$l" in
        *'"abort"'*)
          if [ "$FAKE_MODE" = "rpchang" ]; then
            printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"被中止"}],"stopReason":"aborted"}}\n'
            printf '{"type":"agent_settled"}\n'
            exit 0
          fi ;;
      esac
    done
    sleep 300                                  # 不理 abort，等被杀
    ;;
  grandchild) spawn_gc; wait ;;
  toolhold)
    # A 验收：工具执行中被静默 >阈值 ⇒ 看门狗必须放行（不是真卡死）
    printf '{"type":"agent_start"}\n'
    printf '{"type":"tool_execution_start","toolCallId":"t1","toolName":"bash","args":{}}\n'
    sleep 8
    printf '{"type":"tool_execution_end","toolCallId":"t1","toolName":"bash","result":{}}\n'
    ev_stream "工具跑完了" stop
    printf '{"type":"agent_settled"}\n' ;;
  bulk)
    # C 验收：大事件流（大量 message_update 增量帧）⇒ 落盘时必须折叠
    _bf="$(mktemp)"
    {
      printf '{"type":"session","version":3}\n'
      printf '{"type":"agent_start"}\n'
      _pad="$(printf 'x%.0s' $(seq 1 700))"
      _i=0
      while [ "$_i" -lt 400 ]; do
        printf '{"type":"message_update","message":{"role":"assistant"},"delta":{"type":"text_delta","text":"%s"}}\n' "$_pad"
        _i=$((_i+1))
      done
      printf '{"type":"tool_execution_start","toolCallId":"t1","toolName":"bash"}\n'
      printf '{"type":"tool_execution_end","toolCallId":"t1","toolName":"bash"}\n'
      printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"bulk 最终答复"}],"stopReason":"stop","usage":{"input":1234,"output":56}}}\n'
      printf '{"type":"agent_settled"}\n'
    } > "$_bf"
    cat "$_bf"
    [ -n "${FAKE_RAW:-}" ] && cat "$_bf" >> "$FAKE_RAW"
    rm -f "$_bf" ;;
  argv)       printf '%s\n' "$*" > "${FAKE_ARGV:-/dev/null}"
              ev_stream "最终答复: fake ok" stop
              printf '{"type":"agent_settled"}\n' ;;
  usage)      ev_stream "最终答复: 带 usage" stop "" '{"input":1500,"output":250}'
              printf '{"type":"agent_settled"}\n' ;;
  sleep)    exec sleep 300 ;;
  quiet)    printf '{"type":"session"}\n'; exec sleep 300 ;;
  ok)       ev_stream "最终答复: fake ok" stop
            printf '{"type":"agent_end","messages":[]}\n{"type":"agent_settled"}\n' ;;
  write)
    if [ -n "${FAKE_OUT:-}" ]; then mkdir -p "$(dirname "$FAKE_OUT")"; : > "$FAKE_OUT"; fi
    ev_stream "fake pi: wrote ${FAKE_OUT:-<none>}" stop
    printf '{"type":"agent_settled"}\n' ;;
  nokey)    ev_stream "" error "No API key found for provider deepseek" ;;
  err)      ev_stream "部分输出（即将中断）" error "provider 500" ;;
  nosettle) ev_stream "做了一半" stop ;;
  plain)    echo "fake pi: plain ok (print mode)" ;;
  *)        ev_stream "最终答复: fake ok" stop
            printf '{"type":"agent_settled"}\n' ;;
esac
exit 0
FAKEEOF
chmod +x "$FAKE"

# ---------------------------------------------------------------- 假执行端（Python，直测 driver）
# 必须是 Python 原生进程：driver 的 taskkill /T /F 要能可靠杀掉它的孙进程。
FAKEPY="$TMP/fake_rpc_pi.py"
cat > "$FAKEPY" <<'FAKEPYEOF'
import json, os, subprocess, sys, time
MODE = os.environ.get("FAKE_DRV_MODE", "ok")
LOG = os.environ.get("FAKE_DRV_LOG", "")
GC = os.environ.get("FAKE_DRV_GC", "")
def out(o):
    sys.stdout.write(json.dumps(o, ensure_ascii=False) + "\n")
    sys.stdout.flush()
def log(s):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(s + "\n")
out({"type": "session", "version": 3})
out({"type": "agent_start"})
line = sys.stdin.readline()
log("PROMPT " + line.rstrip("\n"))
out({"type": "response", "command": "prompt", "success": True})
out({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "driver 最终答复"}], "stopReason": "stop"}})
if MODE == "ok":
    out({"type": "agent_settled"})
    sys.stdin.read()
    raise SystemExit(0)
if MODE == "nosettle":
    raise SystemExit(0)
if MODE == "error":
    out({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "坏了"}], "stopReason": "error"}})
    raise SystemExit(0)
if MODE == "abortdead" and GC:
    child = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(300)"])
    with open(GC, "w", encoding="utf-8") as f:
        f.write(str(child.pid))
for frame in sys.stdin:
    log("FRAME " + frame.rstrip("\n"))
    if '"abort"' in frame and MODE == "abortok":
        out({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "被中止"}], "stopReason": "aborted"}})
        out({"type": "agent_settled"})
        raise SystemExit(0)
while True:
    time.sleep(1)
FAKEPYEOF

DRV="$SCRIPTS_DIR/rpc_driver.py"
DRVWIN="$(cygpath -w "$DRV" 2>/dev/null || echo "$DRV")"
FAKEPYW="$(cygpath -w "$FAKEPY" 2>/dev/null || echo "$FAKEPY")"
PROMPT_DRV="$TMP/drv_prompt.txt"
printf 'driver 自测 prompt\n' > "$PROMPT_DRV"
PROMPT_DRVW="$(cygpath -w "$PROMPT_DRV" 2>/dev/null || echo "$PROMPT_DRV")"

# drv_call <events> <stderr> <idle> <grace> [env...] ⇒ stdout；rc 由调用方 $? 取
drv_call() {
  local ev="$1" err="$2" idle="$3" grace="$4"; shift 4
  env FAKE_DRV_MODE="${FAKE_DRV_MODE:-ok}" \
      FAKE_DRV_LOG="$(cygpath -w "${FAKE_DRV_LOG:-}" 2>/dev/null || echo "${FAKE_DRV_LOG:-}")" \
      FAKE_DRV_GC="$(cygpath -w "${FAKE_DRV_GC:-}" 2>/dev/null || echo "${FAKE_DRV_GC:-}")" \
      "$@" python "$DRVWIN" \
    --pi-bin "$FAKEPYW" --provider deepseek --model fake-rpc \
    --prompt-file "$PROMPT_DRVW" \
    --events "$(cygpath -w "$ev" 2>/dev/null || echo "$ev")" \
    --stderr "$(cygpath -w "$err" 2>/dev/null || echo "$err")" \
    --ready-wait 0.3 --idle-timeout "$idle" --abort-grace "$grace"
}

REPO="$TMP/repo"
mkdir -p "$REPO/.agents/tasks/t1"
REPO="$(cd "$REPO" && pwd -P)"     # 与 wfctl 内部的 pwd -P 对齐（锁名靠它哈希）
# ⚠️ 踩过的坑：run_ledger.py 是**原生 python**，`WF_LEDGER=/tmp/...` 会被当成 `C:\tmp\...`
# ⇒ 账本跑到另一个盘，测试读不到。必须传 Windows 路径。
LEDGER_WIN="$(cygpath -w "$TMP/ledger.jsonl" 2>/dev/null || echo "$TMP/ledger.jsonl")"

# ---------------------------------------------------------------- 任务书工厂
mkprompt() {   # $1=文件名 $2=body（不含实测事实行则自然缺）
  printf '%s\n' "$2" > "$TMP/$1"
  printf '%s' "$TMP/$1"
}
FACT='实测事实: 假执行端自测，仅验护栏逻辑（无外部 API 调用）'

P_BASE="$(mkprompt p_base.md "# 任务
$FACT
无 expect。")"
P_MISSING="$(mkprompt p_missing.md "# 任务
$FACT
expect: no/such/file.go, also/gone.py")"
P_EXIST="$(mkprompt p_exist.md "# 任务
$FACT
expect: artifacts/ok.txt")"
P_NOFACT="$(mkprompt p_nofact.md "# 任务
没有实测事实行，应被拒。")"
P_EXEMPT="$(mkprompt p_exempt.md "# 任务
实测事实: 不适用（内部重构）")"

run_deleg() {   # $1=promptfile  其余=额外参数；输出走 stdout
  local pf="$1"; shift
  PI_BIN="$FAKE" \
  WF_NO_LOOKUP=1 WF_NO_PREAMBLE=1 WF_TEST=1 \
  WF_LEDGER="$LEDGER_WIN" \
  FAKE_MODE="${FAKE_MODE:-ok}" FAKE_OUT="${FAKE_OUT:-}" \
  FAKE_ARGV="${FAKE_ARGV:-}" FAKE_GC_PID="${FAKE_GC_PID:-}" FAKE_GC_WINPID="${FAKE_GC_WINPID:-}" \
  FAKE_RPC_LOG="${FAKE_RPC_LOG:-}" FAKE_RAW="${FAKE_RAW:-}" \
  timeout 60 bash "$WF" deleg "$REPO" "$pf" "$@" 2>&1
}

echo "== wfctl deleg 护栏自证 =="

# ① 停滞看门狗 ------------------------------------------------------------
T0=$(date +%s)
OUT="$(FAKE_MODE=sleep run_deleg "$P_BASE" --stall-timeout 3)"; RC=$?
EL=$(( $(date +%s) - T0 ))
if [ "$RC" = 124 ] && [ "$EL" -le 13 ] && printf '%s' "$OUT" | grep -q 'STALLED after'; then
  ok "① 看门狗: rc=124, ${EL}s ≤13s, 打印 STALLED after"
else
  bad "① 看门狗" "rc=124 且 ≤13s 且含 STALLED after" "rc=$RC elapsed=${EL}s"
fi

# ② 预期产物 --------------------------------------------------------------
OUT="$(FAKE_MODE=ok run_deleg "$P_MISSING")"; RC=$?
if [ "$RC" = 3 ] && printf '%s' "$OUT" | grep -q 'MISSING: no/such/file.go' \
   && printf '%s' "$OUT" | grep -q 'MISSING: also/gone.py'; then
  ok "②a 产物缺失: rc=3 + 两行 MISSING"
else
  bad "②a 产物缺失" "rc=3 且含两行 MISSING" "rc=$RC"
fi
OUT="$(FAKE_MODE=write FAKE_OUT="$REPO/artifacts/ok.txt" run_deleg "$P_EXIST")"; RC=$?
if [ "$RC" = 0 ] && ! printf '%s' "$OUT" | grep -q 'MISSING:'; then
  ok "②b 产物齐备: rc 不变(0)"
else
  bad "②b 产物齐备" "rc=0 且无 MISSING" "rc=$RC"
fi

# ③ 单票锁 ----------------------------------------------------------------
HASH="$(printf '%s' "$REPO" | sha1sum 2>/dev/null | cut -c1-8)"
[ -n "$HASH" ] || HASH="$(printf '%s' "$REPO" | md5sum | cut -c1-8)"
LOCK="${TMPDIR:-/tmp}/wfctl-deleg-$HASH.lock"
( PI_BIN="$FAKE" WF_NO_LOOKUP=1 WF_NO_PREAMBLE=1 WF_TEST=1 WF_LEDGER="$LEDGER_WIN" \
  exec env FAKE_MODE=sleep timeout 60 bash "$WF" deleg "$REPO" "$P_BASE" --stall-timeout 30 >"$TMP/first.log" 2>&1 ) &
BG_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$LOCK" ] && break; sleep 1; done
OUT="$(FAKE_MODE=ok run_deleg "$P_BASE")"; RC=$?
if [ "$RC" = 4 ] && printf '%s' "$OUT" | grep -q 'another deleg is running (pid='; then
  ok "③ 单票锁: rc=4 + 打印持锁 pid"
else
  bad "③ 单票锁" "rc=4 且含 another deleg is running (pid=" "rc=$RC lock=$([ -f "$LOCK" ] && echo yes || echo no)"
fi
# 信号释放：kill 整个 timeout 进程组（timeout 会把 TERM 转发给 wfctl）
kill -TERM "$BG_PID" 2>/dev/null; sleep 2; kill -9 "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null
BG_PID=""
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$LOCK" ] || break; sleep 1; done
if [ ! -f "$LOCK" ]; then ok "③b 锁已释放（trap 生效）"; else rm -f "$LOCK"; bad "③b 锁已释放" "锁文件消失" "仍存在 ${LOCK}"; fi

# ④ 实测事实门禁 ----------------------------------------------------------
OUT="$(FAKE_MODE=ok run_deleg "$P_NOFACT")"; RC=$?
if [ "$RC" = 5 ] && printf '%s' "$OUT" | grep -q '实测事实'; then
  ok "④a 缺实测事实: rc=5"
else
  bad "④a 缺实测事实" "rc=5" "rc=$RC"
fi
OUT="$(FAKE_MODE=ok run_deleg "$P_EXEMPT")"; RC=$?
if [ "$RC" = 0 ]; then
  ok "④b 实测事实: 不适用（内部重构）⇒ 放行 rc=0"
else
  bad "④b 豁免放行" "rc=0" "rc=$RC"
fi

# ⑤ 正常任务 --------------------------------------------------------------
OUT="$(FAKE_MODE=ok run_deleg "$P_BASE")"; RC=$?
if [ "$RC" = 0 ]; then
  ok "⑤ 正常任务: rc=0"
else
  bad "⑤ 正常任务" "rc=0" "rc=$RC"
fi

# 账本字段抽查（stalled/missing 是否真的落账）
if [ -f "$TMP/ledger.jsonl" ] && grep -q '"stalled"' "$TMP/ledger.jsonl" \
   && grep -q '"missing"' "$TMP/ledger.jsonl"; then
  ok "⑥ ledger 记 stalled/missing"
else
  bad "⑥ ledger 字段" "含 stalled= 与 missing=" "账本缺字段"
fi

# ⑦ 密钥外泄防护 -----------------------------------------------------------
# 假执行端只打一行 No API key found 且 rc=0（复现桌面端重启后丢环境的形态）。
# 断言：a) deleg rc≠0  b) 无 sk-*/32 位以上长串  c) 有中文提示  d) 无 command not found
#       e) 消息里不得留命令替换片段 "$(" 或反引号（这就是旧版泄露 key 的根）。
OUT="$(FAKE_MODE=nokey run_deleg "$P_BASE")"; RC=$?
_p=""
[ "$RC" -ne 0 ] || _p="$_p rc=0(应为非0)"
printf '%s' "$OUT" | grep -Eq 'sk-[A-Za-z0-9]{8,}' && _p="$_p 含sk-样式密钥"
printf '%s' "$OUT" | grep -Eq '[A-Za-z0-9]{32,}' && _p="$_p 含32位以上长串"
printf '%s' "$OUT" | grep -q '没有 DeepSeek 凭据' || _p="$_p 缺中文提示'没有 DeepSeek 凭据'"
printf '%s' "$OUT" | grep -q 'command not found' && _p="$_p 出现command not found"
printf '%s' "$OUT" | grep -Eq '\$\(|`' && _p="$_p 含命令替换片段\$(或反引号"
if [ -z "$_p" ]; then
  ok "⑦ 密钥外泄防护: rc≠0 且无 sk-/长串/命令替换/command not found"
else
  bad "⑦ 密钥外泄防护" "rc≠0、无密钥痕迹、含中文提示" "$_p"
fi

# ⑧ 事件驱动：settled ⇒ rc=0，stdout 只有最终文本，事件已落盘 -----------------
EV="$TMP/deleg-events.jsonl"
rm -f "$EV"
OUT="$(FAKE_MODE=ok run_deleg "$P_BASE")"; RC=$?
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC(应为0)"
printf '%s' "$OUT" | grep -q '最终答复: fake ok' || _p="$_p 缺最终文本"
printf '%s' "$OUT" | grep -q '{"type":' && _p="$_p stdout 混入原始JSONL"
[ -f "$EV" ] || _p="$_p 事件文件未落盘"
grep -q '"agent_settled"' "$EV" 2>/dev/null || _p="$_p 事件文件缺 agent_settled"
if [ -z "$_p" ]; then
  ok "⑧ agent_settled ⇒ rc=0 + 仅最终文本 + 事件落盘"
else
  bad "⑧ 事件完成" "rc=0、stdout 仅文本、事件含 agent_settled" "$_p"
fi

# ⑨ stopReason=error ⇒ rc=6 并打印 stop_reason -----------------------------
OUT="$(FAKE_MODE=err run_deleg "$P_BASE")"; RC=$?
if [ "$RC" = 6 ] && printf '%s' "$OUT" | grep -q 'stop_reason=error'; then
  ok "⑨ stop_reason=error ⇒ rc=6 且打印 stop_reason"
else
  bad "⑨ 异常结束" "rc=6 且含 stop_reason=error" "rc=$RC"
fi

# ⑩ 无 agent_settled ⇒ rc=7 ----------------------------------------------
OUT="$(FAKE_MODE=nosettle run_deleg "$P_BASE")"; RC=$?
if [ "$RC" = 7 ] && printf '%s' "$OUT" | grep -q 'NO agent_settled'; then
  ok "⑩ 无 agent_settled ⇒ rc=7 + NO agent_settled"
else
  bad "⑩ 无 settled" "rc=7 且含 NO agent_settled" "rc=$RC"
fi

# ⑪ 发 1 条事件后静默超 stall ⇒ rc=124 -------------------------------------
T0=$(date +%s)
OUT="$(FAKE_MODE=quiet run_deleg "$P_BASE" --stall-timeout 3)"; RC=$?
EL=$(( $(date +%s) - T0 ))
if [ "$RC" = 124 ] && [ "$EL" -le 13 ] && printf '%s' "$OUT" | grep -q 'STALLED after'; then
  ok "⑪ 静默超时: rc=124, ${EL}s ≤13s"
else
  bad "⑪ 静默超时" "rc=124 且 ≤13s 且含 STALLED after" "rc=$RC elapsed=${EL}s"
fi

# ⑫–⑮ 白跑判定：settled==1 ⇒ 不算白跑；settled 缺失 ⇒ 保持旧判定 --------------
# ⚠️ 坑：Windows 上 `python3` 可能指向 Microsoft Store 的桩（跑起来 rc=49），优先用 python
PY_BIN="$(command -v python || command -v python3)"
RL="$SCRIPTS_DIR/run_ledger.py"
RL_WIN="$(cygpath -w "$RL" 2>/dev/null || echo "$RL")"
WH_LEDGER="$TMP/white.jsonl"
WH_LEDGER_WIN="$(cygpath -w "$WH_LEDGER" 2>/dev/null || echo "$WH_LEDGER")"

# white_probe: 清空临时账本 → 追加 1 票 → 打印该票被算作的白跑票数（0 或 1）
white_probe() {
  rm -f "$WH_LEDGER"
  WF_LEDGER="$WH_LEDGER_WIN" "$PY_BIN" "$RL_WIN" append --cmd deleg "$@" >/dev/null 2>&1
  WF_LEDGER="$WH_LEDGER_WIN" "$PY_BIN" "$RL_WIN" report --json --all 2>/dev/null \
    | grep -o '"白跑票数": [0-9]*' | head -1 | grep -o '[0-9]\+$'
}

# ⑫ rc=0 / 5s / 50B / settled=1 ⇒ 不计白跑
W="$(white_probe --rc 0 --dur 5 --out-bytes 50 settled=1)"
if [ "$W" = 0 ]; then
  ok "⑫ settled=1 ⇒ 5s/50B 不算白跑"
else
  bad "⑫ settled=1 不算白跑" "白跑票数=0" "白跑票数=${W:-<空>}"
fi

# ⑬ 同上但 settled=0 ⇒ 计白跑
W="$(white_probe --rc 0 --dur 5 --out-bytes 50 settled=0)"
if [ "$W" = 1 ]; then
  ok "⑬ settled=0 ⇒ 5s/50B 仍算白跑"
else
  bad "⑬ settled=0 仍算白跑" "白跑票数=1" "白跑票数=${W:-<空>}"
fi

# ⑭ 同上但无 settled 字段（wfctl v1.10.0 前的老票）⇒ 仍计白跑
W="$(white_probe --rc 0 --dur 5 --out-bytes 50)"
if [ "$W" = 1 ]; then
  ok "⑭ 无 settled 字段 ⇒ 仍算白跑（历史兼容）"
else
  bad "⑭ 无 settled 仍算白跑" "白跑票数=1" "白跑票数=${W:-<空>}"
fi

# ⑮ rc=0 / 120s / 5000B / settled=0 ⇒ 不计白跑（旧规则本来就不算）
W="$(white_probe --rc 0 --dur 120 --out-bytes 5000 settled=0)"
if [ "$W" = 0 ]; then
  ok "⑮ 120s/5000B ⇒ 不算白跑（旧规则亦如此）"
else
  bad "⑮ 长跑不算白跑" "白跑票数=0" "白跑票数=${W:-<空>}"
fi

# ⑯ 新写记录的 settled/missing 必须是 JSON 数字（int）
rm -f "$WH_LEDGER"
WF_LEDGER="$WH_LEDGER_WIN" "$PY_BIN" "$RL_WIN" append --cmd deleg --rc 0 --dur 5 --out-bytes 50 settled=1 missing=0 >/dev/null 2>&1
TYP="$(WF_LEDGER="$WH_LEDGER_WIN" "$PY_BIN" - "$WH_LEDGER_WIN" <<'PYEOF'
import json, sys
path = sys.argv[1]
rec = json.loads(open(path, encoding="utf-8").read().strip().splitlines()[-1])
s = rec.get("settled")
m = rec.get("missing")
print("ok" if (type(s) is int and s == 1 and type(m) is int and m == 0) else "bad settled=%r(%s) missing=%r(%s)" % (s, type(s).__name__, m, type(m).__name__))
PYEOF
)"
if [ "$TYP" = ok ]; then
  ok "⑯ 新写 settled/missing 为 JSON int"
else
  bad "⑯ 账本字段类型" "settled=1(int), missing=0(int)" "$TYP"
fi

# ⑰ 老记录 settled:"1"（字符串）仍按整数 1 处理：白跑判定须与整数版一致（=0）
rm -f "$WH_LEDGER"
"$PY_BIN" - "$WH_LEDGER_WIN" <<'PYEOF'
import json, sys
rec = {"ts": "2026-10-01T12:00:00+08:00", "source": "live", "cmd": "deleg",
       "rc": 0, "dur_s": 5, "out_bytes": 50, "settled": "1", "missing": "0"}
open(sys.argv[1], "a", encoding="utf-8", newline="\n").write(json.dumps(rec, ensure_ascii=False) + "\n")
PYEOF
W_OLD="$(WF_LEDGER="$WH_LEDGER_WIN" "$PY_BIN" "$RL_WIN" report --json --all 2>/dev/null \
  | grep -o '"白跑票数": [0-9]*' | head -1 | grep -o '[0-9]\+$')"
W_NEW="$(white_probe --rc 0 --dur 5 --out-bytes 50 settled=1 missing=0)"
if [ "$W_OLD" = "$W_NEW" ] && [ "$W_OLD" = 0 ]; then
  ok "⑰ 老记录 settled:\"1\" 与整数版白跑判定一致（=0）"
else
  bad "⑰ 老记录读取兼容" "字符串版与整数版同为 0" "old=${W_OLD:-<空>} new=${W_NEW:-<空>}"
fi

# ---------------------------------------------------------------- CR1 杀进程树
# 假执行端 spawn `sleep 300` 孙进程；wfctl 停滞杀树后孙进程必须消失。
# ⚠️ MSYS pid ≠ Win32 pid，且 tasklist 只认 Win32 pid ⇒ 假执行端自己把 winpid 也写下来。
_win_alive() {   # $1=winpid ⇒ 0=还活着
  [ -n "${1:-}" ] || return 1
  MSYS2_ARG_CONV_EXCL='*' tasklist /FI "PID eq $1" /NH 2>/dev/null | grep -qE "(^|[^0-9])$1([^0-9]|$)"
}

GC_PID="$TMP/gc.pid"; GC_WIN="$TMP/gc.gcwin"
rm -f "$GC_PID" "$GC_WIN"
T0=$(date +%s)
OUT="$(FAKE_MODE=grandchild FAKE_GC_PID="$GC_PID" FAKE_GC_WINPID="$GC_WIN" run_deleg "$P_BASE" --stall-timeout 3)"; RC=$?
EL=$(( $(date +%s) - T0 ))
GW="$(cat "$GC_WIN" 2>/dev/null || true)"
GC_ALIVE=1
if [ -n "$GW" ]; then
  for _ in 1 2 3 4 5; do
    _win_alive "$GW" || { GC_ALIVE=0; break; }
    sleep 1
  done
fi
if [ "$RC" = 124 ] && [ -n "$GW" ] && [ "$GC_ALIVE" = 0 ]; then
  ok "⑱ 杀进程树: rc=124, ${EL}s，孙进程(winpid=$GW)已不存在"
else
  bad "⑱ 杀进程树" "rc=124 且 5s 内孙进程消失" "rc=$RC elapsed=${EL}s gw=${GW:-<空>} alive=$GC_ALIVE"
fi

# ---------------------------------------------------------------- CR2 会话可续
ARGV_LOG="$TMP/argv.txt"; rm -f "$ARGV_LOG"
OUT="$(FAKE_MODE=argv FAKE_ARGV="$ARGV_LOG" run_deleg "$P_BASE")"; RC=$?
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC"
grep -q -- '--session' "$ARGV_LOG" 2>/dev/null || _p="$_p 参数无 --session"
grep -q 'pi-session' "$ARGV_LOG" 2>/dev/null || _p="$_p 参数无 pi-session 路径"
SESS="$(python - "$LEDGER_WIN" <<'PYEOF'
import json, sys
rec = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][-1]
print(rec.get("session", ""))
PYEOF
)"
case "$SESS" in *pi-session) ;; *) _p="$_p ledger session=${SESS:-<空>}" ;; esac
if [ -z "$_p" ]; then
  ok "⑲ 会话可续: 参数带 --session …/pi-session，ledger 记 session"
else
  bad "⑲ 会话可续" "参数带 --session …/pi-session 且 ledger 记 session" "$_p"
fi

OUT="$(FAKE_MODE=nosettle run_deleg "$P_BASE")"; RC=$?
if [ "$RC" = 7 ] && printf '%s' "$OUT" | grep -q '可续跑：wfctl.sh deleg' \
   && printf '%s' "$OUT" | grep -q -- '--continue'; then
  ok "⑳ 续跑提示: rc=7 打印「可续跑：… --continue」"
else
  bad "⑳ 续跑提示" "rc=7 且含「可续跑：… --continue」" "rc=$RC"
fi

# ---------------------------------------------------------------- CR3 成本记账
OUT="$(FAKE_MODE=usage run_deleg "$P_BASE")"; RC=$?
COST="$(python - "$LEDGER_WIN" <<'PYEOF'
import json, sys
rec = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][-1]
print(rec.get("in_tokens"), rec.get("out_tokens"), rec.get("cost_usd"), rec.get("model"))
PYEOF
)"
read -r IT OT CS MD <<< "${COST:-}"
TOT="$(WF_LEDGER="$LEDGER_WIN" "$PY_BIN" "$RL_WIN" report --json --all 2>/dev/null \
  | grep -o '"总花费_usd": [0-9.]*' | head -1 | grep -o '[0-9.]\+$')"
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC"
[ "$IT" = 1500 ] || _p="$_p in_tokens=${IT:-<空>}"
[ "$OT" = 250 ] || _p="$_p out_tokens=${OT:-<空>}"
[ "$(awk -v c="${CS:-0}" 'BEGIN{print (c+0>0)?1:0}')" = 1 ] || _p="$_p cost_usd=${CS:-<空>}"
[ "$(awk -v c="${TOT:-0}" 'BEGIN{print (c+0>0)?1:0}')" = 1 ] || _p="$_p baseline总花费=${TOT:-<空>}"
if [ -z "$_p" ]; then
  ok "㉑ 成本记账: tokens=${IT}/${OT} cost_usd=${CS} model=${MD}，baseline 总花费=${TOT}"
else
  bad "㉑ 成本记账" "in=1500 out=250 cost>0 且 baseline 有总花费" "$_p"
fi

OUT="$(FAKE_MODE=ok run_deleg "$P_BASE")"; RC=$?
NOUSAGE="$(python - "$LEDGER_WIN" <<'PYEOF'
import json, sys
rec = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][-1]
print("1" if ("in_tokens" in rec or "cost_usd" in rec) else "0")
PYEOF
)"
REP_OK=0
WF_LEDGER="$LEDGER_WIN" "$PY_BIN" "$RL_WIN" report --json --all >/dev/null 2>&1 && REP_OK=1
if [ "$RC" = 0 ] && [ "$NOUSAGE" = 0 ] && [ "$REP_OK" = 1 ]; then
  ok "㉒ 无 usage: 不写 tokens/cost，rc=0，baseline 不崩"
else
  bad "㉒ 无 usage" "rc=0、无 tokens/cost、report 正常" "rc=$RC 写了tokens/cost=$NOUSAGE report_ok=$REP_OK"
fi

# ---------------------------------------------------------------- CR4 RPC abort
RLOG="$TMP/rpc_ok.log"; EVR="$TMP/rpc-events.jsonl"; rm -f "$RLOG" "$EVR"
OUT="$(FAKE_MODE=rpcok FAKE_RPC_LOG="$RLOG" run_deleg "$P_BASE" --stop-mode rpc --events "$EVR")"; RC=$?
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC"
printf '%s' "$OUT" | grep -q 'rpc 最终答复' || _p="$_p 缺最终文本"
printf '%s' "$OUT" | grep -q '退化 kill' && _p="$_p 正常路径误退化 kill"
grep -q '"agent_settled"' "$EVR" 2>/dev/null || _p="$_p 事件流缺 agent_settled"
grep -q '^PROMPT ' "$RLOG" 2>/dev/null || _p="$_p 未收到 prompt 帧"
if [ -z "$_p" ]; then
  ok "㉓ RPC 正常: 发 prompt 帧 ⇒ 等 agent_settled ⇒ rc=0，事件落盘"
else
  bad "㉓ RPC 正常" "rc=0、最终文本、事件含 settled、未退化 kill" "$_p"
fi

RLOG2="$TMP/rpc_abort.log"; rm -f "$RLOG2"
T0=$(date +%s)
OUT="$(FAKE_MODE=rpchang FAKE_RPC_LOG="$RLOG2" run_deleg "$P_BASE" --stop-mode rpc --stall-timeout 3)"; RC=$?
EL=$(( $(date +%s) - T0 ))
_p=""
[ "$RC" = 124 ] || _p="$_p rc=$RC"
grep -q '"abort"' "$RLOG2" 2>/dev/null || _p="$_p 未发出 abort 帧"
printf '%s' "$OUT" | grep -q 'abort 生效' || _p="$_p 未打印 abort 生效"
[ "$EL" -le 16 ] || _p="$_p elapsed=${EL}s(>16s)"
if [ -z "$_p" ]; then
  ok "㉔ RPC abort: 停滞发 {\"type\":\"abort\"} 帧，≤10s 生效 ⇒ rc=124（${EL}s）"
else
  bad "㉔ RPC abort" "rc=124、收到 abort 帧、≤16s" "$_p"
fi

GC2_PID="$TMP/gc2.pid"; GC2_WIN="$TMP/gc2.gcwin"; rm -f "$GC2_PID" "$GC2_WIN"
RLOG3="$TMP/rpc_dead.log"; rm -f "$RLOG3"
T0=$(date +%s)
OUT="$(FAKE_MODE=rpcgc FAKE_GC_PID="$GC2_PID" FAKE_GC_WINPID="$GC2_WIN" FAKE_RPC_LOG="$RLOG3" \
       run_deleg "$P_BASE" --stop-mode rpc --stall-timeout 3)"; RC=$?
EL=$(( $(date +%s) - T0 ))
GW2="$(cat "$GC2_WIN" 2>/dev/null || true)"
GA2=1
if [ -n "$GW2" ]; then
  for _ in 1 2 3 4 5; do
    _win_alive "$GW2" || { GA2=0; break; }
    sleep 1
  done
fi
_p=""
[ "$RC" = 124 ] || _p="$_p rc=$RC"
printf '%s' "$OUT" | grep -q '退化 kill 进程树' || _p="$_p 未退化 kill"
[ "$EL" -le 25 ] || _p="$_p elapsed=${EL}s(>25s)"
[ -n "$GW2" ] && [ "$GA2" = 0 ] || _p="$_p 孙进程仍活(gw=${GW2:-<空>})"
if [ -z "$_p" ]; then
  ok "㉕ RPC 退化: abort 无响应 >10s ⇒ 杀进程树（含孙进程），rc=124（${EL}s）"
else
  bad "㉕ RPC 退化" "rc=124、退化 kill、孙进程消失、≤25s" "$_p"
fi

# ---------------------------------------------------------------- driver 直测
# 不经 wfctl，直接验 rpc_driver.py 的退出码/事件/abort/杀树。
EV26="$TMP/drv_ok.jsonl"; E26="$TMP/drv_ok.err"; LOG26="$TMP/drv_ok.fake"; rm -f "$EV26" "$E26" "$LOG26"
OUT="$(FAKE_DRV_MODE=ok FAKE_DRV_LOG="$LOG26" drv_call "$EV26" "$E26" 5 2 2>&1)"; RC=$?
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC"
printf '%s' "$OUT" | grep -q 'driver 最终答复' || _p="$_p 缺最终文本"
grep -q '"agent_settled"' "$EV26" 2>/dev/null || _p="$_p 事件缺 settled"
grep -q '^PROMPT ' "$LOG26" 2>/dev/null || _p="$_p 未收到 prompt 帧"
if [ -z "$_p" ]; then
  ok "㉖ driver 正常: prompt 帧 ⇒ agent_settled ⇒ rc=0，stdout=最终文本"
else
  bad "㉖ driver 正常" "rc=0、含 settled、有最终文本" "$_p"
fi

EV27="$TMP/drv_err.jsonl"; E27="$TMP/drv_err.err"; rm -f "$EV27" "$E27"
OUT="$(FAKE_DRV_MODE=error drv_call "$EV27" "$E27" 5 2 2>&1)"; RC=$?
if [ "$RC" = 6 ] && grep -q '"stopReason": "error"' "$EV27" 2>/dev/null; then
  ok "㉗ driver 异常: stopReason=error ⇒ rc=6"
else
  bad "㉗ driver 异常" "rc=6 且事件含 stopReason=error" "rc=$RC"
fi

EV28="$TMP/drv_nosettle.jsonl"; E28="$TMP/drv_nosettle.err"; rm -f "$EV28" "$E28"
OUT="$(FAKE_DRV_MODE=nosettle drv_call "$EV28" "$E28" 5 2 2>&1)"; RC=$?
if [ "$RC" = 7 ] && printf '%s' "$OUT" | grep -q '从未见 agent_settled'; then
  ok "㉘ driver 早退: 进程退出且无 settled ⇒ rc=7"
else
  bad "㉘ driver 早退" "rc=7 且打印从未见 agent_settled" "rc=$RC"
fi

# B+C：收 prompt 后不发事件；忽略 abort ⇒ abort 帧 + 宽限后杀树，孙进程必须消失。
EV29="$TMP/drv_abortdead.jsonl"; E29="$TMP/drv_abortdead.err"; LOG29="$TMP/drv_abortdead.fake"
GC29="$TMP/drv_gc.pid"; rm -f "$EV29" "$E29" "$LOG29" "$GC29"
T0=$(date +%s)
OUT="$(FAKE_DRV_MODE=abortdead FAKE_DRV_LOG="$LOG29" FAKE_DRV_GC="$(cygpath -w "$GC29" 2>/dev/null || echo "$GC29")" \
       drv_call "$EV29" "$E29" 2 2 2>&1)"; RC=$?
EL=$(( $(date +%s) - T0 ))
GCW29="$(cat "$GC29" 2>/dev/null || true)"
GA29=1
if [ -n "$GCW29" ]; then
  for _ in 1 2 3 4 5; do
    _win_alive "$GCW29" || { GA29=0; break; }
    sleep 1
  done
fi
_p=""
[ "$RC" = 124 ] || _p="$_p rc=$RC"
grep -q '"abort"' "$LOG29" 2>/dev/null || _p="$_p 未收到 abort 帧"
printf '%s' "$OUT" | grep -q '退化 kill 进程树' || _p="$_p 未退化 kill"
[ "$EL" -le 15 ] || _p="$_p elapsed=${EL}s(>15s)"
[ -n "$GCW29" ] && [ "$GA29" = 0 ] || _p="$_p 孙进程仍活(gw=${GCW29:-<空>})"
if [ -z "$_p" ]; then
  ok "㉙ driver abort 无响应: 收到 abort 帧、杀进程树（含孙进程 gw=$GCW29）、rc=124（${EL}s）"
else
  bad "㉙ driver abort 无响应" "rc=124、abort 帧、孙进程消失、≤15s" "$_p"
fi

# ---------------------------------------------------------------- ㉚/㉛ 工具执行中不误杀
# A 验收：假执行端发 tool_execution_start 后静默 8s（> stall=3）⇒ 不得判停滞；
# 收尾发 tool_execution_end + message_end + agent_settled ⇒ rc=0，总耗时 ≥8s。
T0=$(date +%s)
OUT="$(FAKE_MODE=toolhold run_deleg "$P_BASE" --stall-timeout 3)"; RC=$?
EL=$(( $(date +%s) - T0 ))
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC(应为0)"
[ "$EL" -ge 8 ] || _p="$_p elapsed=${EL}s(应≥8s，实际可能没真静默)"
printf '%s' "$OUT" | grep -q 'STALLED after' && _p="$_p 误判停滞"
printf '%s' "$OUT" | grep -q '工具跑完了' || _p="$_p 缺最终文本"
if [ -z "$_p" ]; then
  ok "㉚ json 工具执行中静默 8s → 不误杀（rc=0, ${EL}s）"
else
  bad "㉚ 工具中不误杀" "rc=0、无 STALLED、≥8s" "$_p"
fi

RLOGT="$TMP/rpc_tool.log"; rm -f "$RLOGT"
T0=$(date +%s)
OUT="$(FAKE_MODE=rpctool FAKE_RPC_LOG="$RLOGT" run_deleg "$P_BASE" --stop-mode rpc --stall-timeout 3)"; RC=$?
EL=$(( $(date +%s) - T0 ))
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC(应为0)"
[ "$EL" -ge 8 ] || _p="$_p elapsed=${EL}s(应≥8s)"
grep -q '"abort"' "$RLOGT" 2>/dev/null && _p="$_p 工具中误发 abort"
printf '%s' "$OUT" | grep -q 'rpc 工具跑完了' || _p="$_p 缺最终文本"
if [ -z "$_p" ]; then
  ok "㉛ rpc 工具执行中静默 8s → 不误杀（rc=0, ${EL}s，未发 abort）"
else
  bad "㉛ rpc 工具中不误杀" "rc=0、未发 abort、≥8s" "$_p"
fi

# ---------------------------------------------------------------- ㉜ 事件瘦身（C 验收）
RAW="$TMP/bulk_raw.jsonl"; EVB="$TMP/bulk_slim.jsonl"; rm -f "$RAW" "$EVB"
OUT="$(FAKE_MODE=bulk FAKE_RAW="$RAW" run_deleg "$P_BASE" --events "$EVB")"; RC=$?
# 解析口径与 wfctl _parse_events 一致：settled / 最后 stopReason / usage 合计 / 最后正文
parse_sig() {
  "$PY_BIN" - "$1" <<'PYSIG'
import json, sys
settled = 0; stops = []; intok = 0; outtok = 0; text = ""
try:
    fh = open(sys.argv[1], encoding="utf-8", errors="replace")
except OSError:
    print("NOFILE"); raise SystemExit(0)
for line in fh:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    t = d.get("type")
    if t == "agent_settled":
        settled = 1; continue
    m = d.get("message")
    if t == "message_end" and isinstance(m, dict):
        u = m.get("usage") or {}
        if isinstance(u, dict) and u:
            intok += int(u.get("input") or 0); outtok += int(u.get("output") or 0)
    if not isinstance(m, dict) or m.get("role") != "assistant":
        continue
    stops.append(m.get("stopReason") or m.get("stop_reason") or "")
    parts = [c.get("text", "") for c in (m.get("content") or [])
             if isinstance(c, dict) and c.get("type") == "text"]
    if any(parts):
        text = "\n".join(parts)
print("settled=%d stop=%s in=%d out=%d text=%s" % (settled, stops[-1] if stops else "none", intok, outtok, text))
PYSIG
}
SIG_RAW="$(parse_sig "$RAW")"; SIG_SLIM="$(parse_sig "$EVB")"
RAW_SZ=$(wc -c < "$RAW" 2>/dev/null | tr -d ' '); SLIM_SZ=$(wc -c < "$EVB" 2>/dev/null | tr -d ' ')
DROP=$("$PY_BIN" -c "print(round(100*(1-(${SLIM_SZ:-0})/(${RAW_SZ:-1})),1))")
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC"
[ "$SIG_RAW" = "$SIG_SLIM" ] || _p="$_p 判定不一致 raw[$SIG_RAW] slim[$SIG_SLIM]"
[ "${DROP%.*}" -ge 60 ] 2>/dev/null || _p="$_p 体积只降 ${DROP}%"
grep -q '"type":"message_update"' "$EVB" 2>/dev/null && _p="$_p 瘦身文件仍有 message_update"
grep -q '"agent_settled"' "$EVB" 2>/dev/null || _p="$_p 瘦身丢了 agent_settled"
grep -q '"type":"tool_execution_start"' "$EVB" 2>/dev/null || _p="$_p 瘦身丢了 tool_execution_start"
if [ -z "$_p" ]; then
  ok "㉜ 事件瘦身: ${RAW_SZ}B→${SLIM_SZ}B（-${DROP}%），settled/stop/tokens/文本逐项一致"
else
  bad "㉜ 事件瘦身" "降 ≥60% 且判定逐项一致" "$_p"
fi

# ---------------------------------------------------------------- ㉝-㉟ verify（D 验收）
VREPO="$TMP/vrepo"; VLEDGER="$TMP/vledger.jsonl"
VREPO_WIN="$(cygpath -w "$VREPO" 2>/dev/null || echo "$VREPO")"
VLEDGER_WIN="$(cygpath -w "$VLEDGER" 2>/dev/null || echo "$VLEDGER")"
rm -rf "$VREPO"; mkdir -p "$VREPO/internal/calc" "$VREPO/.agents"
printf 'module vrepo\n\ngo 1.21\n' > "$VREPO/go.mod"
printf 'package calc\n\nfunc Add(a, b int) int {\n\treturn a + b\n}\n' > "$VREPO/internal/calc/calc.go"
printf 'package calc\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) {\n\tif Add(1, 2) != 3 {\n\t\tt.Fatalf("Add(1,2)=%%d", Add(1, 2))\n\t}\n}\n' > "$VREPO/internal/calc/calc_test.go"
printf '# SPEC\n\n- [ ] CR1 加法可用\n' > "$VREPO/SPEC.md"
printf '# 收敛报告\n\n判定: Converged\n\nCR1 已实现。证据: internal/calc/calc.go:3\n' > "$VREPO/.agents/converge-2026-10-19.md"
WF_LEDGER="$VLEDGER_WIN" "$PY_BIN" "$RL_WIN" append --cmd deleg --dir "$VREPO_WIN" --rc 0 \
  --dur 42 --out-bytes 1000 in_tokens=100 out_tokens=20 model=deepseek-v4-flash >/dev/null 2>&1

OUT="$(WF_LEDGER="$VLEDGER_WIN" WF_TEST=1 timeout 180 bash "$WF" verify "$VREPO" 2>&1)"; RC=$?
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC(应为0)"
printf '%s' "$OUT" | grep -q 'verify 全绿' || _p="$_p 缺全绿汇总"
printf '%s' "$OUT" | grep -q 'go build ./...' || _p="$_p 缺 go build 项"
printf '%s' "$OUT" | grep -q 'go test ./internal/... -count=1' || _p="$_p 缺 go test 项"
printf '%s' "$OUT" | grep -q 'converge --strict' || _p="$_p 缺 converge 项"
printf '%s' "$OUT" | grep -Eq 'rc=0 cost_usd=.*in_tokens=100 out_tokens=20' || _p="$_p 账本未打印 rc/cost/tokens"
if [ -z "$_p" ]; then
  ok "㉝ verify 全绿: go build/vet/gofmt/test + converge --strict + 账本 ⇒ rc=0"
else
  bad "㉝ verify 全绿" "rc=0 且包含各项与账本" "$_p"
fi

# ㉞ 人为弄红一个测试 ⇒ rc=1 并指出 go test
printf 'package calc\n\nimport "testing"\n\nfunc TestBroken(t *testing.T) {\n\tif Add(1, 2) != 4 {\n\t\tt.Fatalf("故意弄红")\n\t}\n}\n' > "$VREPO/internal/calc/broken_test.go"
OUT="$(WF_LEDGER="$VLEDGER_WIN" WF_TEST=1 timeout 180 bash "$WF" verify "$VREPO" 2>&1)"; RC=$?
_p=""
[ "$RC" = 1 ] || _p="$_p rc=$RC(应为1)"
printf '%s' "$OUT" | grep -q 'go test ./internal/... -count=1' || _p="$_p 未指出 go test 项"
printf '%s' "$OUT" | grep -q '✗' || _p="$_p 未打印失败项列表"
rm -f "$VREPO/internal/calc/broken_test.go"
if [ -z "$_p" ]; then
  ok "㉞ verify 红: go test 失败 ⇒ rc=1 且指出是哪一项"
else
  bad "㉞ verify 红" "rc=1 且指出 go test" "$_p"
fi

# ㉟ 账本 rc≠0 ⇒ verify 红并打印本票账本（rc/cost/tokens）
WF_LEDGER="$VLEDGER_WIN" "$PY_BIN" "$RL_WIN" append --cmd deleg --dir "$VREPO_WIN" --rc 7 \
  --dur 42 --out-bytes 10 settled=0 model=deepseek-v4-flash >/dev/null 2>&1
OUT="$(WF_LEDGER="$VLEDGER_WIN" WF_TEST=1 timeout 180 bash "$WF" verify "$VREPO" 2>&1)"; RC=$?
_p=""
[ "$RC" = 1 ] || _p="$_p rc=$RC(应为1)"
printf '%s' "$OUT" | grep -q '本票账本 rc=7' || _p="$_p 未指出本票账本 rc=7"
printf '%s' "$OUT" | grep -q 'cost_usd=' || _p="$_p 账本未打印 cost"
if [ -z "$_p" ]; then
  ok "㉟ verify 账本: rc=7 ⇒ rc=1 且打印本票 rc/cost/tokens"
else
  bad "㉟ verify 账本" "rc=1 且打印本票账本" "$_p"
fi

# ---------------------------------------------------------------- ㊱-㊲ gofmt 换行无关（本票修复）
GREPO="$TMP/grepo"
rm -rf "$GREPO"; mkdir -p "$GREPO/internal/fmtx" "$GREPO/.agents"
printf 'module grepo\n\ngo 1.21\n' > "$GREPO/go.mod"
# 全 CRLF，但缩进/空行均正确 ⇒ 原始 gofmt -l 会命中，归一化后应已格式化
printf 'package fmtx\r\n\r\nfunc Add(a, b int) int {\r\n\treturn a + b\r\n}\r\n' > "$GREPO/internal/fmtx/crlf_ok.go"
printf '# SPEC\n\n- [ ] CR1 加法可用\n' > "$GREPO/SPEC.md"
printf '# 收敛报告\n\n判定: Converged\n\nCR1 已实现。证据: internal/fmtx/crlf_ok.go:3\n' > "$GREPO/.agents/converge-2026-10-19.md"
OUT="$(WF_LEDGER="$VLEDGER_WIN" WF_TEST=1 timeout 180 bash "$WF" verify "$GREPO" 2>&1)"; RC=$?
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC(应为0)"
printf '%s' "$OUT" | grep -q 'gofmt -l（无未格式化文件；1 个文件仅 CRLF 差异，已忽略' || _p="$_p 未识别为仅 CRLF 差异"
printf '%s' "$OUT" | grep -q '❌ gofmt' && _p="$_p CRLF 被误判为红"
if [ -z "$_p" ]; then
  ok "㊱ gofmt CRLF: 全 CRLF 仓库仅换行差异 ⇒ 不判红（rc=0）"
else
  bad "㊱ gofmt CRLF" "rc=0 且 gofmt 项绿" "$_p"
fi

# ㊲ CRLF + 缩进错乱（8 空格）⇒ 归一化后仍未格式化 ⇒ gofmt 项必须红并指出文件
printf 'package fmtx\r\n\r\nfunc Bad() int {\r\n        return 1\r\n}\r\n' > "$GREPO/internal/fmtx/bad_indent.go"
OUT="$(WF_LEDGER="$VLEDGER_WIN" WF_TEST=1 timeout 180 bash "$WF" verify "$GREPO" 2>&1)"; RC=$?
_p=""
[ "$RC" = 1 ] || _p="$_p rc=$RC(应为1)"
printf '%s' "$OUT" | grep -q '❌ gofmt -l' || _p="$_p gofmt 项未判红"
printf '%s' "$OUT" | grep -q 'internal/fmtx/bad_indent.go' || _p="$_p 未指出真实未格式化文件"
printf '%s' "$OUT" | grep -q '1 个文件未格式化' || _p="$_p 未给出未格式化计数"
if [ -z "$_p" ]; then
  ok "㊲ gofmt 真乱: CRLF+缩进错乱 ⇒ rc=1 且指出 bad_indent.go（真实红保留）"
else
  bad "㊲ gofmt 真乱" "rc=1 且指出 bad_indent.go" "$_p"
fi

# ---------------------------------------------------------------- ㊳-㊴ 账本来源分流（数据修正）
SRC_LEDGER="$TMP/srcledger.jsonl"
SRC_WIN="$(cygpath -w "$SRC_LEDGER" 2>/dev/null || echo "$SRC_LEDGER")"
rm -f "$SRC_LEDGER"
# a) 无 --source、无环境变量 ⇒ 默认 live；b) 环境变量 selftest ⇒ selftest；c) --source 优先级高于环境变量
env -u WFCTL_LEDGER_SOURCE WF_LEDGER="$SRC_WIN" "$PY_BIN" "$RL_WIN" append --cmd deleg --rc 0 --dur 60 --out-bytes 1000 >/dev/null 2>&1
WFCTL_LEDGER_SOURCE=selftest WF_LEDGER="$SRC_WIN" "$PY_BIN" "$RL_WIN" append --cmd deleg --rc 0 --dur 2 --out-bytes 10 >/dev/null 2>&1
WFCTL_LEDGER_SOURCE=selftest WF_LEDGER="$SRC_WIN" "$PY_BIN" "$RL_WIN" append --cmd deleg --rc 0 --dur 60 --out-bytes 1000 --source live >/dev/null 2>&1
SRCS="$("$PY_BIN" - "$SRC_WIN" <<'PYEOF'
import json, sys
print(",".join((json.loads(l).get("source") or "<missing>") for l in open(sys.argv[1], encoding="utf-8") if l.strip()))
PYEOF
)"
# wfctl 落账透传：先前所有 deleg/verify 票（临时账本）必须全是 selftest
DELEG_SRCS="$("$PY_BIN" - "$LEDGER_WIN" <<'PYEOF'
import json, sys
ss = {str((json.loads(l).get("source") or "<missing>")) for l in open(sys.argv[1], encoding="utf-8") if l.strip()}
print(",".join(sorted(ss)))
PYEOF
)"
if [ "$SRCS" = "live,selftest,live" ] && [ "$DELEG_SRCS" = "selftest" ]; then
  ok "㊳ 来源分流: 默认 live / 环境 selftest / --source 优先；wfctl 落账透传 source=selftest"
else
  bad "㊳ 来源分流" "live,selftest,live 且 wfctl 票全为 selftest" "append=[$SRCS] wfctl=[$DELEG_SRCS]"
fi

# ㊴ 追加 selftest 票 ⇒ baseline（默认 live）不变，--all 才 +3
BASE_CNT="$(WF_LEDGER="$SRC_WIN" "$PY_BIN" "$RL_WIN" report --json 2>/dev/null | grep -o '"委托票数": [0-9]*' | head -1 | grep -o '[0-9]\+$')"
ALL_BEFORE="$(WF_LEDGER="$SRC_WIN" "$PY_BIN" "$RL_WIN" report --json --all 2>/dev/null | grep -o '"委托票数": [0-9]*' | head -1 | grep -o '[0-9]\+$')"
for _i in 1 2 3; do
  WFCTL_LEDGER_SOURCE=selftest WF_LEDGER="$SRC_WIN" "$PY_BIN" "$RL_WIN" append --cmd deleg --rc 0 --dur 2 --out-bytes 10 >/dev/null 2>&1
done
AFTER_CNT="$(WF_LEDGER="$SRC_WIN" "$PY_BIN" "$RL_WIN" report --json 2>/dev/null | grep -o '"委托票数": [0-9]*' | head -1 | grep -o '[0-9]\+$')"
ALL_CNT="$(WF_LEDGER="$SRC_WIN" "$PY_BIN" "$RL_WIN" report --json --all 2>/dev/null | grep -o '"委托票数": [0-9]*' | head -1 | grep -o '[0-9]\+$')"
EXCL_LINE="$(WF_LEDGER="$SRC_WIN" "$PY_BIN" "$RL_WIN" report 2>/dev/null | grep '已排除' | head -1)"
_p=""
[ "${BASE_CNT:-x}" = "${AFTER_CNT:-y}" ] || _p="$_p 自测后票数变了 ${BASE_CNT}→${AFTER_CNT}"
[ "${ALL_CNT:-0}" = "$(( ${ALL_BEFORE:-0} + 3 ))" ] || _p="$_p --all 应为 $(( ${ALL_BEFORE:-0} + 3 )) 实为 ${ALL_CNT:-<空>}"
printf '%s' "$EXCL_LINE" | grep -q '已排除 [0-9]\+ 条非 live' || _p="$_p 未打印「已排除 N 条非 live」"
if [ -z "$_p" ]; then
  ok "㊴ 基线隔离: selftest +3 ⇒ baseline 仍 $AFTER_CNT 票，--all=$ALL_CNT，$(printf '%s' "$EXCL_LINE" | sed 's/^口径: //')"
else
  bad "㊴ 基线隔离" "默认票数不变、--all +3、打印已排除" "$_p"
fi

# ---------------------------------------------------------------- ㊵ converge 骨架证据位
CREPO="$TMP/crepo"
rm -rf "$CREPO"; mkdir -p "$CREPO/.agents/tasks/c1"
printf 'package calc\n\nfunc Add(a, b int) int {\n\treturn a + b\n}\n' > "$CREPO/calc.go"
printf '# SPEC\n\n- [ ] CR1 加法可用\n- [ ] CR2 边界\n' > "$CREPO/.agents/tasks/c1/SPEC.md"
CSPEC=".agents/tasks/c1/SPEC.md"
OUT="$(WF_LEDGER="$VLEDGER_WIN" WF_TEST=1 timeout 60 bash "$WF" converge "$CREPO" "$CSPEC" --init 2>&1)"; RC=$?
CONV="$(ls -t "$CREPO"/.agents/converge-*.md 2>/dev/null | head -1)"
CONV_WIN="$(cygpath -w "$CONV" 2>/dev/null || echo "$CONV")"
_p=""
[ "$RC" = 0 ] || _p="$_p rc=$RC"
grep -q '`文件.go:行号`' "$CONV" 2>/dev/null || _p="$_p 骨架无 `文件.go:行号` 占位"
grep -q '| CR2 |' "$CONV" 2>/dev/null || _p="$_p 骨架缺 CR2 行"
if [ -z "$_p" ]; then
  ok "㊵a converge --init 骨架带 文件:行 证据位（CR1/CR2）"
else
  bad "㊵a converge 骨架" "rc=0 且含 `文件.go:行号` 与 CR2 行" "$_p"
fi

# 按骨架填写（真实 file:line + 判定 Converged）⇒ --strict 必须 PASS
"$PY_BIN" - "$CONV_WIN" <<'PYEOF'
import re, sys
p = sys.argv[1]
b = open(p, encoding='utf-8', errors='replace').read()
b = b.replace('`文件.go:行号`', '`calc.go:3`')
b = re.sub(r'\*\*未收敛\*\*[^\n]*', '判定: Converged', b)
open(p, 'w', encoding='utf-8', newline='\n').write(b)
PYEOF
OUT="$(WF_LEDGER="$VLEDGER_WIN" WF_TEST=1 timeout 60 bash "$WF" converge "$CREPO" "$CSPEC" --strict 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'PASS'; then
  ok "㊵b 按骨架填写 → converge --strict PASS"
else
  bad "㊵b converge 填完 PASS" "rc=0 且含 PASS" "rc=$RC out=$(printf '%s' "$OUT" | tr '\n' ' ' | head -c 200)"
fi

# 删掉 file:line ⇒ FAIL 且明确提示「证据须为 文件:行」
"$PY_BIN" - "$CONV_WIN" <<'PYEOF'
import sys
p = sys.argv[1]
b = open(p, encoding='utf-8', errors='replace').read()
open(p, 'w', encoding='utf-8', newline='\n').write(b.replace('`calc.go:3`', '（已实现，测试通过）'))
PYEOF
OUT="$(WF_LEDGER="$VLEDGER_WIN" WF_TEST=1 timeout 60 bash "$WF" converge "$CREPO" "$CSPEC" --strict 2>&1)"; RC=$?
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q '证据须为 文件:行'; then
  ok "㊵c 删掉 file:line ⇒ FAIL(rc=$RC) 且提示「证据须为 文件:行」"
else
  bad "㊵c converge 缺证据" "rc≠0 且提示「证据须为 文件:行」" "rc=$RC"
fi

echo "== 汇总: PASS=$PASS FAIL=$FAILN =="
[ "$FAILN" -eq 0 ] || exit 1
exit 0
