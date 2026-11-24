#!/usr/bin/env bash
# =============================================================================
# wfctl.sh — 开发工作流控制脚本 (Workflow Control)
# 工程级可复用：环境搭建 → 委托 → 验证 → 审计 → 交接，一站式
# 用法: ./wfctl.sh <command> [options]
# 依赖: bash (Git Bash), pi (主力), opencode (备用), npx, git
# v1.15.1 (2026-11-25): 真项目首票暴露的两个缺口 ——
#                        ① diffcov 只测本票动过的文件（WF_DIFFCOV_PATHS / --paths），
#                           否则别人未提交的 WIP 会算进本票覆盖率；
#                        ② 测试项支持「既有红」基线 `.agents/pytest-baseline.txt`（wfctl testbaseline），
#                           只对新增失败发红（开工时项目就是红的：数据漂移/历史待修）。
# v1.15.0 (2026-11-25): verify 增加「改动行覆盖」门禁（diffcov.py，默认要求 100%）——
#                        测试跑过只证明"测试绿"，不证明"你改的那几行被执行过"；
#                        Go 走 coverprofile，Python 走 covrunner（settrace，零依赖），
#                        测不了就明确 SKIP（rc=4），不装绿。WF_DIFFCOV=0 可关。
# v1.14.0 (2026-11-25): converge 补第三向——每条 CR 必须带 `[test: 文件::用例]`，
#                        checker 会真跑那一条（pytest / go test -run / node --test），
#                        缺指针/用例不存在/跑不过 一律 rc=2；`[test: n/a: 理由]` 可豁免。
#                        逃生门：--allow-missing-tests（WARN 放行）· --no-run（只静态检查）。
#                        骨架模板与 --init 提示同步（新任务的 SPEC 自带指针占位）。
# v1.13.3 (2026-11-25): verify 三处实测缺口修复（机验测试发现）——
#                        ① 非 Go 项目也必须有测试项（此前 Python 仓库测试红了 verify 仍全绿）；
#                        ② SPEC 解析补 .agents/tasks/*/SPEC.md（此前任务在子目录时 converge 恒 rc=2）；
#                        ③ 账本目录匹配归一（posix /d/... 记录与 D:/... 永不相等 ⇒ 本票账本恒 MISSING）。
# v1.13.2 (2026-11-25): 凭据静默失效修复 —— DEEPSEEK_API_KEY 不在环境里时自动从 .env 读取并 export
#                        到当前进程（只报长度与来源，绝不打印值）：此前桌面端重启后 shell 丢 key，
#                        pi 报 No API key 却 rc=0，整票白跑。支持 WF_ENV_FILE 指定文件；
#                        envcheck / preflight 会显示加载来源。
# v1.13.1 (2026-10-19): gofmt 门禁换行无关 —— CRLF 仓库（core.autocrlf=true）不再恒假红：
#                        gofmt -l 命中的文件先 tr -d '\r' 到临时文件再判，只有归一化后仍
#                        未格式化才算真红；仅换行差异只计数（--verbose 时打印），实测真实仓库
#                        145 个假红清零。
# v1.13.0 (2026-10-19): 看门狗工具感知 + 事件瘦身 + verify 全绿门禁
#                        ①停滞判定：tool_execution_start → 工具执行中，tool_execution_end 清除；
#                          工具执行期间不计入停滞（实测误杀：长工具调用本就不产生事件）；
#                        ②事件写盘折叠 message_update（正文丢弃/只计数，实测占事件流 ~76%），
#                          判定只依赖 message_end/turn_end/agent_settled/usage，结果逐项不变；
#                        ③wfctl verify <dir>：go build/vet/gofmt/test + converge --strict + 本票账本，
#                          全绿 rc=0，任一红 rc=1 并列出失败项（原 setup 体检改叫 verify-setup）。
# v1.12.0 (2026-10-18): CR4 rpc 重写 —— bash 的 FIFO+fd3 在 Windows 原生 pi.exe 下拿不到 stdout
#                        （Pi 干完了活，事件流 0 字节，成功被报成失败）；rpc 分支改调
#                        scripts/rpc_driver.py（Python subprocess 直连 stdin/stdout；停滞发 abort，
#                        宽限后 taskkill /T /F 杀进程树）。kill 分支未动。
# v1.11.1 (2026-10-18): CR4 rpc 修正 —— ①stdin/stdout 重定向必须在**子进程**里做（给函数加重定向
#                        会在父 shell 里先 open FIFO 读端 ⇒ 永久挂住，实测 rc=124 且收不到 prompt 帧）；
#                        ②默认 --stall-timeout 180→600（长工具调用期间事件流本来就不增长，180s 会误杀）。
# v1.11.0 (2026-10-18): deleg 生命周期四件套 —— CR1 终止必杀**进程树**（Windows taskkill /T /F，
#                        POSIX 进程组；外部超时杀父不再留下孤儿 Pi）；CR2 每票固定 --session
#                        <promptdir>/pi-session（ledger 记 session，rc∈{6,7,124} 提示 --continue）；
#                        CR3 事件 usage ⇒ in/out tokens + cost_usd（内置价目表，baseline 出总花费）；
#                        CR4 新增 --stop-mode rpc（发 abort 帧等 ≤10s 再退化 kill 树；默认 kill）
# v1.10.0 (2026-10-18): deleg 升级为**事件驱动**：默认 --mode json，按事件判三态
#                        agent_settled⇒rc=0 / stop_reason∈{error,aborted,length}⇒rc=6 / 无 agent_settled⇒rc=7
#                        （停滞仍 rc=124）；原始事件落盘 deleg-events.jsonl（--events 可覆盖）；
#                        stdout 只打印 assistant 最终文本；--mode print / WF_DELEG_MODE=print 保持旧行为
# v1.9.0 (2026-10-18): deleg 四条护栏 —— 停滞看门狗(rc=124)/预期产物清单(rc=3)/单票锁(rc=4)/实测事实门禁(rc=5)
#                        + CR5「CR 缺可执行证据」只警告不拦；自证脚本 scripts/selftest_wfctl.sh
# v1.8.0 (2026-10-09): 新增 lookup（阶段 0「先查现成答案」）+ deleg 门禁（任务书没有检索记录 ⇒ 默认拒绝委托）
# v1.7.3 (2026-10-09): preflight 新增 Pi 连通性冒烟；deleg 支持 PI_PROXY/PI_NO_PROXY（系统代理失效 ⇒ Connection error）
# v1.7.2 (2026-10-09): deleg 轨迹模式新增“零工具调用⇒硬失败”（网络错误静默白跑）；trace-stats 支持 --final-error
# v1.7.1 (2026-10-08): deleg 支持 PI_PROVIDER（默认 deepseek）——成本路由标定用（本地 DGX qwen3.8-local）
# v1.7.0 (2026-10-08): 新增 worktree（隔离工作树——吸收官方 using-git-worktrees；并行改动不再靠复制仓库）
# v1.6.1 (2026-10-08): deleg 自动前置【执行环境优先级】（templates/task/preamble.txt；WF_NO_PREAMBLE=1 可关）
# v1.6.0 (2026-10-08): 新增 map（仓库地图生成）；deleg 支持 PI_TRACE=1（--mode json 轨迹 → 记工具调用/探索轮次）
# v1.5.0 (2026-10-08): 新增 baseline（时程基线）+ 全命令自动记账（trap 落 run_ledger.jsonl）
# v1.4.0 (2026-10-08): 新增 task（任务骨架）/ converge --init（收敛报告骨架）——固化本轮跑通的链路
# v1.3.1 (2026-10-08): harness 日志改落 harness/.logs（配 harness/.gitignore，不污染仓库根 ignore）
# v1.3.0 (2026-10-08): 新增 preflight（防整批白跑）与 harness（仓库自带验收器）
# v1.2.0 (2026-10-08): 新增 converge 门禁（收敛报告接进链路）；deleg 遇无凭据硬失败
# v1.1.0 (2026-10-08): 委托执行端对齐规范 v4.1 —— 默认 Pi，opencode 降为备用端
# =============================================================================
set -euo pipefail

VERSION="1.15.1"
SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 目录解析统一走这里：三件工具（converge_check / diffcov / ledger_stats）与账本、.env
# 在 Hermes 里默认住 ~/AppData/Local/hermes（Windows）或 ~/.hermes；自建环境用 HC_* 覆盖。
HC_HOME="${HC_HOME:-$HOME/AppData/Local/hermes}"
[ -d "$HC_HOME" ] || HC_HOME="$HOME/.hermes"
HC_SCRIPTS="${HC_SCRIPTS:-$HC_HOME/scripts}"
HC_LEDGER="${HC_LEDGER:-$HC_HOME/run_ledger.jsonl}"
SP_CACHE="${SP_CACHE:-$HOME/.cache/opencode/packages/superpowers@git+https_/github.com/jnMetaCode/superpowers-zh.git/node_modules/superpowers/skills}"

# ---------------------------------------------------------------- helpers
log()  { printf '\033[1;36m[wfctl]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[wfctl!]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[wfctl✗]\033[0m %s\n' "$*" >&2; exit 1; }
failrc() { local c="$1"; shift; printf '\033[1;31m[wfctl✗]\033[0m %s\n' "$*" >&2; exit "$c"; }

# 凭据自动加载（v1.13.2）：环境里没有 DEEPSEEK_API_KEY 时，从 .env 读一行 export 进当前进程。
# 🔴 只打印长度与来源文件名，绝不 echo 值（历史血课：把取 key 的命令贴进终端 ⇒ key 回显到屏幕/日志）。
# 顺序：$WF_ENV_FILE > $HC_HOME/.env > $HOME/.hermes/.env
_load_env_key() {
  [ -n "${DEEPSEEK_API_KEY:-}" ] && return 0
  local f line val
  for f in "${WF_ENV_FILE:-}" "$HC_HOME/.env" "$HOME/.hermes/.env"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    line="$(grep -m1 -E '^[[:space:]]*(export[[:space:]]+)?DEEPSEEK_API_KEY=' "$f" 2>/dev/null || true)"
    [ -n "$line" ] || continue
    val="${line#*=}"
    val="${val%$'\r'}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}";;
      \'*\') val="${val#\'}"; val="${val%\'}";;
    esac
    val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$val" ] || continue
    export DEEPSEEK_API_KEY="$val"
    log "DEEPSEEK_API_KEY: 已从 ${f#$HOME/} 自动加载 (len=${#val})"
    return 0
  done
  return 1
}

usage() {
  cat <<'EOF'
wfctl.sh — 开发工作流控制 (v1.8.0)

命令:
  setup <dir> <skills>        搭建隔离环境 (skills: superpowers|pocock|both)
  lookup <dir> "<问题一句话>" [--slug <slug>] [--error "<错误原文>"]
                              阶段 0「先查现成答案」: 生成 .agents/tasks/<slug>/lookup.md 骨架
                              （三组必查查询 + 检索记录表 + 结论段；deleg 前没有它会被拒）
                              --check 只做检查（rc=1 = 缺记录/结论为空）
  verify <dir> [--verbose]    全绿门禁: build/vet/gofmt/test（Go/pytest/npm）+ 改动行覆盖 + converge --strict
  diffcov <dir> [--min 1.0]   只跑改动行覆盖（改动行必须被执行过；测不了报 SKIP rc=4）
  stats [--dir D] [--since D] 账本派生指标（返工率/验收失败轮次/白跑率/成本）
                              gofmt 换行无关：仅 CRLF 差异不判红（--verbose 打印忽略计数）
                              + 本票账本(rc/cost/tokens)；全绿 rc=0，任一红 rc=1 并列出失败项
  verify-setup <dir> [testcmd]
                              旧版体检: editable污染检查 + 测试 + git审计
  audit <dir> [specfile]      功能完整性审计: spec 需求点 vs 代码
  handoff <dir> <msg>         交接点: 提交 + 打 tag + 生成 HANDOFF 提示
  rollback <dir> <ref>        回滚到指定 commit/tag
  deleg <dir> <promptfile> [agent] [--stall-timeout N] [--mode json|print] [--events <path>]
                             [--stop-mode kill|rpc] [--continue]
                              委托: 单会话执行 prompt 文件（agent 默认 pi；opencode = 备用端）
                              --session 固定为 <promptfile目录>/pi-session（同一票可续跑）
                              --stop-mode kill（默认）: 停滞/超时直接杀**进程树**（含孙进程）
                              --stop-mode rpc: --mode rpc 起执行端，停滞先发 {"type":"abort"}
                               等 ≤10s，仍不结束再退化杀进程树（事件流同样落盘）
                              --continue: 复用本票固定 session 续跑（失败提示里给的命令）
                              --stall-timeout N   停滞看门狗秒数（默认 600，0=关闭）：连续 N 秒
                              产物 mtime 与子进程事件/输出都无变化 ⇒ 杀子进程、rc=124
                              --mode json（默认，事件驱动）: agent_settled⇒rc=0；
                              stop_reason∈{error,aborted,length}⇒rc=6；无 agent_settled⇒rc=7
                              --mode print（或 WF_DELEG_MODE=print）: 旧行为逐字不变
                              --events <path>     事件流落盘路径（默认 <promptfile目录>/deleg-events.jsonl）
                              另: 任务书 `expect: a/b.go, c/d.go` 声明预期产物，缺则 rc=3；
                              同目录并发第二票 rc=4；任务书缺行首 `实测事实:` 行 rc=5
  task <dir> <slug> "<目标>"   生成任务骨架: .agents/tasks/<slug>/{SPEC.md,brief.md}
  map <dir> [--write|--out <path>]
                              仓库地图生成: 一页 AGENTS.md（技术栈/怎么跑/怎么验/环境坑）；
                              --write 只更新 map:auto 标记段，人工段原样保留
  converge <dir> [specfile] [--strict|--init]
                              收敛门禁: 校验 .agents/converge-*.md 是否完整可消费
                              （报告缺失/不完整→rc=2；--strict 下终判「未收敛」→rc=3；
                                --init 则生成 .agents/converge-<日期>.md 骨架并自动带入 CR 清单）
  preflight [dir]             委托前体检: 凭据/技能包身份/路径/仓库状态/harness 是否存在
                              （防“pi 无 key 就 rc=0 静默零产出”这类整批白跑）
  harness <dir> [--init]      跑仓库自带验收器 harness/verify_*.py（--init 从模板生成）
  envcheck                    全局环境体检 (RTK/pytest/pi/opencode)
  baseline [--cmd deleg] [--days N] [--json] [--all] [--source <值>]
                              时程基线: 单票耗时/白跑率/连续成功/按天趋势（数据源 run_ledger.jsonl）
                              默认只统计 source=live；--all 看全部（含自测/导入）
  worktree <repo> --list                    列出隔离工作树
  worktree <repo> <name> [--base <ref>]     新建隔离工作树（分支 wt/<name>，目录 .worktrees/<name>）
  worktree <repo> <name> --remove [--yes]   删除（不带 --yes 只列清单，不执行）
  help                        显示帮助

环境变量:
  WF_ENV_FILE   凭据文件（默认 $HC_HOME/.env，其次 $HOME/.hermes/.env）
  PI_BIN        pi 可执行文件路径（默认 $HOME/Downloads/pi-agent/pi.exe）
  PI_MODEL      模型（默认 deepseek-v4-flash）
  PI_THINKING   思考档 off|minimal|low|medium|high|xhigh|max（默认 low）
  WF_DELEG_MODE deleg 执行模式 json(默认，事件驱动)|print(旧行为)
  OC_MODEL      opencode 备用端模型（默认 deepseek/deepseek-flash——**必须显式给**：
                opencode 默认模型是本地 qwen3.8-27b，不通时整轮直接失败）

示例:
  ./wfctl.sh setup /d/wf-test/proj-x superpowers
  ./wfctl.sh verify /d/wf-test/proj-x                        # 全绿门禁（go/converge/账本）
  ./wfctl.sh verify-setup /d/wf-test/proj-x "PYTHONPATH=src python -m pytest tests/ -q"
  ./wfctl.sh deleg /d/wf-test/proj-x /path/to/prompt.txt          # Pi 主力
  ./wfctl.sh deleg /d/wf-test/proj-x /path/to/prompt.txt opencode # 备用端(MCP/插件任务)
  ./wfctl.sh deleg /d/wf-test/proj-x /path/to/prompt.txt --stop-mode rpc  # 先 abort 再杀
  ./wfctl.sh handoff /d/wf-test/proj-x "feat: 完成阶段1"
EOF
}

# ---------------------------------------------------------------- envcheck
cmd_task() {
  local dir="$1" slug="$2" goal="${3:-<一句话目标>}"
  [ -d "$dir" ] || fail "目录不存在: $dir"
  [ -n "$slug" ] || fail "用法: wfctl.sh task <dir> <slug> \"<一句话目标>\""
  python "$(cygpath -w "$SKILL_ROOT/scripts/task_scaffold.py" 2>/dev/null || echo "$SKILL_ROOT/scripts/task_scaffold.py")" \
         spec "$(cygpath -w "$dir")" "$slug" "$goal"
}

cmd_converge() {
  local dir="$1" spec="${2:-SPEC.md}" mode="${3:-}"
  [ -d "$dir" ] || fail "目录不存在: $dir"
  if [ "$mode" = "--init" ]; then
    local slug; slug="$(basename "$(dirname "$spec")")"
    local _scaf _rc0
    _rc0=0
    _scaf="$(cygpath -w "$SKILL_ROOT/scripts/task_scaffold.py" 2>/dev/null || echo "$SKILL_ROOT/scripts/task_scaffold.py")"
    python "$_scaf" converge "$(cygpath -w "$dir")" "$slug" "$spec" || _rc0=$?
    # 🔴 2026-11-25：原来这里会用 python 回写"最新一份"报告的 CR 表 —— 实测把同一天
    # 另一个任务的证据表整段冲掉（probe 冲掉 shout）。现改为骨架直接按 slug 渲染两张表
    # （一、SPEC→代码 / 三、SPEC→测试），本函数不再改动任何已存在的报告。
    if [ "$_rc0" != 0 ]; then
      warn "收敛报告已存在（按 slug+日期命名，不覆盖）：.agents/converge-${slug}-$(date +%F).md"
    fi
    return "$_rc0"
  fi
  local checker_win
  checker_win="$(cygpath -w "$HC_SCRIPTS/converge_check.py" 2>/dev/null || echo "$HC_SCRIPTS/converge_check.py")"
  [ -f "$HC_SCRIPTS/converge_check.py" ] || fail "缺少收敛检查器: $HC_SCRIPTS/converge_check.py"
  log "收敛门禁 (G4c)…"
  # 🔴 Windows 路径坑（2026-10-18 实测）：检查器是**原生 python**，不认 MSYS 路径
  # ⇒ 传 posix 形式（`/d/repo`）时 glob 找不到 `.agents/converge-*.md`，误报「报告=（无）」并 FAIL。
  local dir_win; dir_win="$(cygpath -w "$dir" 2>/dev/null || echo "$dir")"
  local args=("$dir_win" "--spec" "$spec")
  [ "$mode" = "--strict" ] && args+=("--fail-on-unconverged")
  local _cout _crc
  _crc=0
  _cout="$(python "$checker_win" "${args[@]}" 2>&1)" || _crc=$?
  printf '%s\n' "$_cout"
  # 「缺证据」是最常见打回原因（骨架占位 `文件.go:行号` 没换成真行号）——把修法直接写进提示
  if [ "$_crc" -ne 0 ] && printf '%s' "$_cout" | grep -q 'has_code_evidence'; then
    printf '%s\n' "收敛门禁提示：缺代码证据 —— 证据须为 文件:行 形式（例 internal/calc/calc.go:3；后缀 .go/.py/.ts/.js/.vue/.sh/.sql）。只写「已实现/测试通过」不算证据。" >&2
  fi
  return "$_crc"
}

cmd_preflight() {
  local dir="${1:-.}" bad=0
  log "=== 委托前体检 (preflight) ==="
  # ① 执行端与凭据（实测：桌面端重启后 shell 丢 key ⇒ pi 报 No API key found 但 rc=0，整批白跑）
  local pi_bin="${PI_BIN:-$HOME/Downloads/pi-agent/pi.exe}"
  if [ -x "$pi_bin" ]; then log "pi: $("$pi_bin" --version 2>&1 | head -1)"; else warn "pi 不可执行: $pi_bin"; bad=1; fi
  if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    log "DEEPSEEK_API_KEY: 已设置 (len=${#DEEPSEEK_API_KEY})"
    # 连通性实测：Pi 能真的打得到 provider 吗？实测踩过：curl/node 直连正常、Pi 报 Connection error（走了失效的系统代理）
    if [ -n "${PREFLIGHT_SKIP_SMOKE:-}" ]; then
      log "Pi 连通性冒烟: 已跳过（PREFLIGHT_SKIP_SMOKE=1）"
    else
      local smoke
      smoke="$(printf 'ok\n' | timeout 60 "$pi_bin" --provider "${PI_PROVIDER:-deepseek}" \
        --model "${PI_MODEL:-deepseek-v4-flash}" -a -p --no-tools 2>&1 | tail -2 | tr -d '\r' || true)"
      if [ -n "$smoke" ] && ! printf '%s' "$smoke" | grep -qiE "connection error"; then
        log "Pi 连通性冒烟: OK（$smoke）"
      else
        warn "Pi 连通性冒烟失败：${smoke:-（无输出）} ⇒ 试 PI_PROXY=http://127.0.0.1:7890 或 PI_NO_PROXY=1 重跑"
        bad=1
      fi
    fi
  else
    warn "DEEPSEEK_API_KEY 未设置，且 .env 里也没读到 ⇒ pi 只打 No API key found 就以 rc=0 退出（静默零产出）"
    echo "     已查: ${WF_ENV_FILE:-\$HC_HOME/.env} 与 \$HOME/.hermes/.env（只读文件，不打印值）"
    echo "     修：把 DEEPSEEK_API_KEY=... 写进 \$HC_HOME/.env；或用 WF_ENV_FILE=<路径> 指定"
    bad=1
  fi
  # ② 技能包身份（换包 / A-B 时最容易搞错 —— 先拿生效证据）
  if [ -f "$SKILL_ROOT/scripts/pi_pkg_info.py" ]; then
    log "Pi 技能包（生效证据）:"
    python "$(cygpath -w "$SKILL_ROOT/scripts/pi_pkg_info.py" 2>/dev/null || echo "$SKILL_ROOT/scripts/pi_pkg_info.py")" 2>/dev/null | sed 's/^/     /'
  fi
  # ③ 路径转换能力（bash → native 程序的路径坑）
  command -v cygpath >/dev/null && log "cygpath: OK" || warn "无 cygpath：给 native 程序传 POSIX 路径会失败"
  # ④ 目标仓库
  if [ -d "$dir" ]; then
    if ( cd "$dir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ); then
      local dirty; dirty="$(cd "$dir" && git status --porcelain | wc -l)"
      [ "$dirty" -eq 0 ] && log "目标仓库: 干净" || warn "目标仓库有 $dirty 处未提交改动（跑批前先提交基线）"
      [ -d "$dir/harness" ] && log "harness/: 已存在" || warn "harness/: 不存在（验收判据只能现写 ⇒ wfctl harness $dir --init）"
    else
      warn "目标目录不是 git 仓库: $dir"
    fi
  else
    warn "目录不存在: $dir"
  fi
  if [ "$bad" -eq 0 ]; then log "preflight 通过——可以委托"; else warn "preflight 未通过（上面 ⚠ 项先修）"; return 1; fi
}

cmd_harness() {
  local dir="$1" mode="${2:-}"
  [ -d "$dir" ] || fail "目录不存在: $dir"
  local hdir="$dir/harness" tpl="$SKILL_ROOT/templates/harness"
  if [ "$mode" = "--init" ]; then
    mkdir -p "$hdir"
    [ -f "$hdir/README.md" ] || cp "$tpl/README.md" "$hdir/README.md"
    if [ ! -f "$hdir/verify_criteria.py" ]; then
      sed "s/<项目名>/$(basename "$dir")/g" "$tpl/verify_criteria.py.tpl" > "$hdir/verify_criteria.py"
    fi
    log "已初始化 $hdir（填判据后跑 wfctl harness $dir）"
    return 0
  fi
  [ -d "$hdir" ] || fail "没有 harness/ 目录（先 wfctl harness <dir> --init）"
  # 日志放在 harness/.logs（配 harness/.gitignore 自动忽略）——不要污染仓库根的 .gitignore
  mkdir -p "$hdir/.logs"
  # ⚠️ Windows 坑：PYTHONPATH 分隔符是 ';'（不是 ':'），且路径必须是 Windows 形式 ——
  #    用 POSIX 路径 + ':' 拼接会让 python 完全找不到模块（实测 ModuleNotFoundError: harness_kit）。
  local hdir_w scripts_w
  hdir_w="$(cygpath -w "$hdir" 2>/dev/null || echo "$hdir")"
  scripts_w="$(cygpath -w "$SKILL_ROOT/scripts" 2>/dev/null || echo "$SKILL_ROOT/scripts")"
  local pass=0 failn=0 f name
  for f in "$hdir"/verify_*.py; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    if PYTHONPATH="$hdir_w;$scripts_w" python "$(cygpath -w "$f" 2>/dev/null || echo "$f")" > "$hdir/.logs/$name.log" 2>&1; then
      log "PASS $name"
      pass=$((pass+1))
    else
      warn "FAIL $name（详见 harness/.logs/$name.log）"
      tail -6 "$hdir/.logs/$name.log" | sed 's/^/      /'
      failn=$((failn+1))
    fi
  done
  if [ $((pass+failn)) -eq 0 ]; then warn "harness/ 里没有 verify_*.py"; return 1; fi
  log "harness 汇总: PASS=$pass FAIL=$failn"
  [ "$failn" -eq 0 ] || return 2
}

cmd_envcheck() {
  log "=== 环境体检 ==="

  # 执行端：Pi（主力）
  local pi_bin="${PI_BIN:-$HOME/Downloads/pi-agent/pi.exe}"
  if [ -x "$pi_bin" ]; then
    log "pi(主力): $("$pi_bin" --version 2>&1 | head -1) @ $pi_bin"
  else
    warn "pi 未找到: $pi_bin（用 PI_BIN 指定；或走 opencode 备用端）"
  fi

  # 执行端：opencode（备用）
  command -v opencode >/dev/null && log "opencode(备用): $(opencode --version 2>&1 | head -1)" || warn "opencode 未安装（备用端不可用）"

  command -v npx >/dev/null && log "npx: OK" || warn "npx 未安装"
  command -v pytest >/dev/null && log "pytest: $(pytest --version 2>&1 | head -1)" || warn "pytest 不在 PATH (用 python -m pytest)"
  command -v go >/dev/null && log "go: $(go version 2>&1 | head -1)" || warn "go 不在 PATH"

  # Pi 需要 DEEPSEEK_API_KEY 在环境里（auth.json 未存 key 时）——只报有无，绝不打印值
  if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    log "DEEPSEEK_API_KEY: 已设置 (len=${#DEEPSEEK_API_KEY})"
  elif [ -s "$HOME/.pi/agent/auth.json" ] && [ "$(cat "$HOME/.pi/agent/auth.json" 2>/dev/null | tr -d '[:space:]')" != "{}" ]; then
    log "DEEPSEEK_API_KEY: 未设，但 ~/.pi/agent/auth.json 有内容（可能已存 key）"
  else
    warn "DEEPSEEK_API_KEY: 环境与 .env 里都没有 ⇒ pi 会报 'No API key found for deepseek'（rc=0 静默白跑）；把该行写进 \$HC_HOME/.env，或用 WF_ENV_FILE=<路径> 指定"
  fi

  # RTK 检查（只影响 opencode 备用端）
  if env | grep -qi rtk; then
    warn "检测到 RTK 环境变量 — 仅 opencode 端受影响，需 --pure；Pi 端不受影响"
  fi
  log "=== 完成 ==="
}

# ---------------------------------------------------------------- setup
cmd_setup() {
  local dir="$1" skills="${2:-both}"
  [ -d "$dir" ] || fail "目录不存在: $dir"
  cd "$dir" || fail "无法进入 $dir"
  [ -d .git ] || { git init -q && log "git 已初始化"; }

  mkdir -p .agents
  case "$skills" in
    superpowers)
      [ -d "$SP_CACHE" ] || fail "superpowers skills 缓存不存在: $SP_CACHE"
      cp -r "$SP_CACHE" .agents/skills
      log "superpowers skills: $(ls .agents/skills | wc -l) 个"
      ;;
    pocock)
      npx -y skills@latest add mattpocock/skills -a opencode -y >/dev/null 2>&1
      log "pocock skills: $(ls .agents/skills 2>/dev/null | wc -l) 个"
      ;;
    both)
      [ -d "$SP_CACHE" ] || fail "superpowers skills 缓存不存在"
      cp -r "$SP_CACHE" .agents/skills
      npx -y skills@latest add mattpocock/skills -a opencode -y >/dev/null 2>&1
      log "both skills: $(ls .agents/skills | wc -l) 个"
      ;;
    *) fail "未知 skills 类型: $skills (superpowers|pocock|both)" ;;
  esac
  log "setup 完成: $dir"
}

# ---------------------------------------------------------------- verify（全绿门禁）
# wfctl verify <dir>：一条命令汇总本票的“能不能收”：
#   go build ./... / go vet ./... / gofmt -l / go test ./internal/... -count=1（无 Go 或无 go.mod 则跳过）
#   + converge --strict（收敛报告门禁）
#   + 本票账本（最近一条该目录的 deleg 记录：rc / cost / tokens）
# 全绿 rc=0；任一红 rc=1 并**逐项**打印失败项（D 验收：故意弄红一个测试必须指出是哪一项）。
cmd_verify() {
  local dir="$1" verbose="${2:-}"
  [ -d "$dir" ] || fail "目录不存在: $dir"
  cd "$dir" || fail "无法进入 $dir"
  local -a fails=() skips=() greens=()
  local _out="" _rc=0 _f
  _v_ok()  { greens+=("$1"); log "✅ $1"; }
  _v_bad() { fails+=("$1"); warn "❌ $1"; }
  _v_skip(){ skips+=("$1"); warn "⏭️  跳过 $1"; }

  log "=== verify: $dir ==="

  # ---- 1) Go 工程（无 go.mod / 无 go 则跳过，不算红）
  if [ ! -f go.mod ]; then
    _v_skip "go（无 go.mod）"
  elif ! command -v go >/dev/null 2>&1; then
    _v_skip "go（PATH 里没有 go）"
  else
    _rc=0; _out="$(go build ./... 2>&1)" || _rc=$?
    if [ "$_rc" = 0 ]; then _v_ok "go build ./..."; else
      _v_bad "go build ./...（rc=$_rc）"; printf '%s\n' "$_out" | head -20 >&2
    fi

    _rc=0; _out="$(go vet ./... 2>&1)" || _rc=$?
    if [ "$_rc" = 0 ]; then _v_ok "go vet ./..."; else
      _v_bad "go vet ./...（rc=$_rc）"; printf '%s\n' "$_out" | head -20 >&2
    fi

    # gofmt -l：只扫仓库里的 .go（跳过 vendor/.git）。
    # 换行无关（2026-10-19 修）：CRLF 仓库（core.autocrlf=true）上 gofmt -l 会把所有文件报成
    # “未格式化”，但 gofmt -d 只是 -\r 与 + 的纯换行差异 ⇒ 恒假红（实测：145 个文件）。
    # 因此对 gofmt -l 命中的每个文件，先 tr -d '\r' 到临时文件再判：归一化后仍被 gofmt -l 命中
    # 才算真红（缩进/空行错乱）；仅换行差异只计数，不判红。
    local _gofmt_raw="" _gofmt_real="" _gofmt_n=0 _gofmt_crlf=0 _gofmt_tmp="" _gf _gn _gw _gout _grc
    _gofmt_raw="$(find . -name '*.go' -type f -not -path './vendor/*' -not -path './.git/*' 2>/dev/null | \
                  xargs -r gofmt -l 2>/dev/null || true)"
    _gofmt_tmp="$(mktemp -d 2>/dev/null || mktemp -d -t wfgofmt)"
    while IFS= read -r _gf; do
      [ -n "$_gf" ] || continue
      _gofmt_n=$((_gofmt_n + 1))
      _gn="$_gofmt_tmp/norm.$_gofmt_n.go"
      if ! tr -d '\r' < "$_gf" > "$_gn" 2>/dev/null; then
        _gofmt_real="${_gofmt_real}${_gofmt_real:+$'\n'}$_gf"; continue
      fi
      # Windows 原生 gofmt.exe 不认 MSYS 路径（/tmp/...）⇒ 转成 Windows 路径再传
      _gw="$_gn"
      if command -v cygpath >/dev/null 2>&1; then
        _gw="$(cygpath -w "$_gn" 2>/dev/null || printf '%s' "$_gn")"
      fi
      _gout="$(gofmt -l "$_gw" 2>/dev/null)"; _grc=$?
      if [ "$_grc" -ne 0 ] || [ -n "$_gout" ]; then
        _gofmt_real="${_gofmt_real}${_gofmt_real:+$'\n'}$_gf"
      else
        _gofmt_crlf=$((_gofmt_crlf + 1))
      fi
    done <<< "$_gofmt_raw"
    rm -rf "$_gofmt_tmp"
    if [ -z "$_gofmt_real" ]; then
      if [ "$_gofmt_crlf" -gt 0 ]; then
        _v_ok "gofmt -l（无未格式化文件；$_gofmt_crlf 个文件仅 CRLF 差异，已忽略）"
      else
        _v_ok "gofmt -l（无未格式化文件）"
      fi
    else
      if [ "$_gofmt_crlf" -gt 0 ]; then
        _v_bad "gofmt -l（$(printf '%s\n' "$_gofmt_real" | sed '/^$/d' | wc -l | tr -d ' ') 个文件未格式化；另 $_gofmt_crlf 个仅 CRLF 差异已忽略）"
      else
        _v_bad "gofmt -l（$(printf '%s\n' "$_gofmt_real" | sed '/^$/d' | wc -l | tr -d ' ') 个文件未格式化）"
      fi
      printf '%s\n' "$_gofmt_real" | head -10 >&2
    fi
    if [ "$_gofmt_crlf" -gt 0 ] && [ "$verbose" = "--verbose" ]; then
      log "gofmt: $_gofmt_crlf 个文件仅 CRLF 差异，已忽略"
    fi

    if [ -d internal ]; then
      _rc=0; _out="$(go test ./internal/... -count=1 2>&1)" || _rc=$?
      if [ "$_rc" = 0 ]; then _v_ok "go test ./internal/... -count=1"; else
        _v_bad "go test ./internal/... -count=1（rc=$_rc）"
        printf '%s\n' "$_out" | grep -E '^(---|FAIL|ok|\?)' | head -20 >&2 || printf '%s\n' "$_out" | tail -20 >&2
      fi
    elif [ -d internal ]; then
      _v_skip "go test ./internal/...（无 internal 目录）"
    else
      # 实测(2026-11-25)：仓库没有 internal/ 时整块被跳过 ⇒ 测试根本不会跑（又一个假绿口子）
      local _gto="" _gtrc=0
      _gto="$(go test ./... -count=1 2>&1)" || _gtrc=$?
      if [ "$_gtrc" = 0 ]; then _v_ok "go test ./..."; else
        _v_bad "go test ./...（rc=$_gtrc）"; printf '%s\n' "$_gto" | tail -12 >&2
      fi
    fi
  fi

  # ---- 1b) 非 Go 项目必须有测试项（v1.13.3 补；实测 2026-11-25：Python 仓库测试红了 verify 仍全绿）
  # 识别顺序：WF_TEST_CMD > pytest 迹象 > package.json 的 test 脚本；都没有则明确跳过（不静默放过）
  local _tc="${WF_TEST_CMD:-}"
  if [ -z "$_tc" ] && [ ! -f go.mod ]; then
    if [ -f pytest.ini ] || [ -f pyproject.toml ] || [ -f setup.cfg ] || [ -f tox.ini ] \
       || ls tests/test_*.py test_*.py >/dev/null 2>&1; then
      # 🔴 实测(2026-11-25)：Hermes 自带 python 无 pytest，硬编码 python -m pytest 会假红 ——
      # 优先用 PATH 上的 pytest，没有才退回 python -m pytest。
      if command -v pytest >/dev/null 2>&1; then _tc="pytest -q"; else _tc="python -m pytest -q"; fi
    elif [ -f package.json ] && grep -q '"test"[[:space:]]*:' package.json; then
      _tc="npm test --silent"
    fi
  fi
  if [ -n "$_tc" ]; then
    local _tout="" _trc=0
    _tout="$(eval "$_tc" 2>&1)" || _trc=$?
    # 既有红基线（v1.15.1）：真项目开工时测试就是红的（数据漂移/别人待修），
    # 全红即失败会让门禁变噪音。`.agents/pytest-baseline.txt` 记录开工时的 FAILED 清单，
    # 这里只对**新增**失败发红；清单本身用 `wfctl testbaseline <repo>` 生成，可复查可删。
    local _base=".agents/pytest-baseline.txt"
    if [ "$_trc" != 0 ] && [ -f "$_base" ]; then
      local _fails _new
      _fails="$(printf '%s\n' "$_tout" | grep -oE '^FAILED [^ ]+' | sed 's/^FAILED //' | sort -u)"
      _new="$(comm -23 <(printf '%s\n' "$_fails") <(sed 's/[[:space:]]*$//' "$_base" | grep -v '^#' | sort -u) 2>/dev/null || true)"
      if [ -z "$(printf '%s' "$_new" | tr -d '[:space:]')" ]; then
        _v_ok "测试: $_tc（rc=$_trc，均为既有红 $(printf '%s\n' "$_fails" | grep -c . ) 条，见 $_base）"
        _trc=0
      else
        _v_bad "测试: $_tc（rc=$_trc，新增失败 $(printf '%s\n' "$_new" | grep -c . ) 条）"
        printf '%s\n' "$_new" | sed 's/^/  NEW-FAIL /' >&2
      fi
    elif [ "$_trc" = 0 ]; then _v_ok "测试: $_tc"
    else
      _v_bad "测试: $_tc（rc=$_trc）"
      printf '%s\n' "$_tout" | tail -12 >&2
    fi
  elif [ ! -f go.mod ]; then
    _v_skip "测试（未识别框架；用 WF_TEST_CMD=\"...\" 指定）"
  fi

  # ---- 1c) 改动行覆盖（v1.15.0）：测试跑过 ≠ 你改的那几行被执行过
  local _dcf; _dcf="$(cygpath -w "$HC_SCRIPTS/diffcov.py" 2>/dev/null || echo "$HC_SCRIPTS/diffcov.py")"
  if [ "${WF_DIFFCOV:-1}" = "0" ]; then
    _v_skip "改动行覆盖（WF_DIFFCOV=0 已关）"
  elif [ -f "$HC_SCRIPTS/diffcov.py" ] && [ -d .git ]; then
    local _do="" _drc=0
    local _drepo; _drepo="$(cygpath -w "$(pwd -P)" 2>/dev/null || pwd -P)"
    _do="$(python "$_dcf" "$_drepo" --base "${WF_DIFFCOV_BASE:-HEAD}" --min "${WF_DIFFCOV_MIN:-1.0}" 2>&1)" || _drc=$?
    case "$_drc" in
      0)  _v_ok "改动行覆盖（$(printf '%s' "$_do" | head -1 | sed 's/^改动行覆盖: //')）" ;;
      4)  _v_skip "改动行覆盖（无法测量：$(printf '%s' "$_do" | head -1)）" ;;
      *)  _v_bad "改动行覆盖（rc=$_drc）"
          printf '%s\n' "$_do" | sed -n '1,6p' >&2 ;;
    esac
  else
    _v_skip "改动行覆盖（无 .git 或缺 diffcov.py）"
  fi

  # ---- 2) converge --strict（收敛报告门禁）
  local _spec="SPEC.md"
  if [ ! -f "$_spec" ]; then
    _spec="$(ls -1t .agents/*SPEC*.md .agents/tasks/*/SPEC.md 2>/dev/null | head -1 || true)"
  fi
  _rc=0
  ( cmd_converge "$(pwd -P)" "${_spec:-SPEC.md}" --strict ) >/dev/null 2>&1 || _rc=$?
  if [ "$_rc" = 0 ]; then _v_ok "converge --strict"; else
    _v_bad "converge --strict（rc=$_rc）"
    ( cmd_converge "$(pwd -P)" "${_spec:-SPEC.md}" --strict ) 2>&1 | tail -10 >&2 || true
  fi

  # ---- 3) 本票账本（rc / cost / tokens）——缺记录只告警（未委托过的仓也能验）
  local _lpy _led
  _lpy="$(command -v python || command -v python3 || true)"
  if [ -z "$_lpy" ]; then
    _v_skip "本票账本（无 python）"
  else
    _led="$("$_lpy" - "$(cygpath -w "$(pwd -P)" 2>/dev/null || pwd -P)" <<'PYLED' 2>/dev/null
import json, os, re, sys
repo = os.path.normcase(os.path.abspath(sys.argv[1]))
led = os.environ.get("WF_LEDGER") or os.path.join(
    os.path.expanduser("~"), "AppData", "Local", "hermes", "run_ledger.jsonl")
if not os.path.exists(led):
    print("MISSING")
    raise SystemExit(0)
rec = None
for line in open(led, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        r = json.loads(line)
    except Exception:
        continue
    if r.get("cmd") != "deleg" or r.get("kind") in ("test", "exp"):
        continue
    d = r.get("dir") or ""
    if not d:
        continue
    def _norm(x):
        # /d/work/x 与 D:/work/x 视为同一目录（实测：posix 记录恒判 MISSING）
        if re.match(r"^/[A-Za-z]/", x):
            x = x[1].upper() + ":" + x[2:]
        return os.path.normcase(os.path.abspath(x))
    try:
        same = _norm(d) == repo
    except Exception:
        same = False
    if same:
        rec = r            # 只追加落盘 ⇒ 最后一条即最新
if rec is None:
    print("MISSING")
    raise SystemExit(0)
print("rc=%s cost_usd=%s in_tokens=%s out_tokens=%s settled=%s" % (
    rec.get("rc"), rec.get("cost_usd", "-"), rec.get("in_tokens", "-"),
    rec.get("out_tokens", "-"), rec.get("settled", "-")))
PYLED
)"
    case "$_led" in
      MISSING|'') _v_skip "本票账本（该目录无 deleg 记录）" ;;
      *"rc=0 "*)   _v_ok  "本票账本 $_led" ;;
      *)           _v_bad "本票账本 $_led（rc≠0）" ;;
    esac
  fi

  # ---- 汇总
  if [ "${#fails[@]}" -eq 0 ]; then
    log "=== verify 全绿: ${#greens[@]} 项通过, ${#skips[@]} 项跳过 ==="
    return 0
  fi
  warn "=== verify 失败: ${#fails[@]} 项（通过 ${#greens[@]}，跳过 ${#skips[@]}）==="
  for _f in ${fails[@]+"${fails[@]}"}; do warn "  ✗ $_f"; done
  return 1
}

# ---------------------------------------------------------------- verify-setup（旧版体检，保留兼容）
cmd_verify_setup() {
  local dir="$1" testcmd="${2:-}"
  [ -d "$dir" ] || fail "目录不存在: $dir"
  cd "$dir" || fail "无法进入 $dir"

  log "=== 1/4 editable 污染检查 ==="
  local pkg
  for pkg in $(ls src/*/__init__.py 2>/dev/null | sed 's|src/||;s|/__init__.py||' | head -5); do
    if pip show "$pkg" 2>/dev/null | grep -q Editable; then
      warn "⚠️ $pkg 有 editable 安装: $(pip show "$pkg" | grep Editable)"
      warn "   → pip uninstall $pkg 或统一 PYTHONPATH=src 运行"
    fi
  done
  [ -n "$testcmd" ] && pip show $(basename "$dir") 2>/dev/null | grep -q Editable && warn "项目自身 editable 安装注意"

  log "=== 2/4 测试验证 (亲自跑) ==="
  if [ -n "$testcmd" ]; then
    set +e
    eval "$testcmd"
    local rc=$?
    set -e
    echo "RC=$rc"
    [ "$rc" -eq 0 ] || fail "❌ 测试失败(RC=$rc): $testcmd"
    log "✅ 测试通过"
  else
    # 自动探测
    if [ -f go.mod ]; then
      go build ./... && log "✅ go build 通过" || warn "go build 未通过"
      go test ./... && log "✅ go test 通过" || warn "go test 未通过，手动验证"
    elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then
      PYTHONPATH=src python -m pytest tests/ -q 2>/dev/null && log "✅ pytest 通过" || warn "pytest 未通过或不存在，手动验证"
    else
      warn "未探测到测试框架，跳过自动测试"
    fi
  fi

  log "=== 3/4 git 审计 ==="
  local ncommits
  ncommits=$(git log --oneline 2>/dev/null | wc -l)
  log "commit 数: $ncommits"
  [ "$ncommits" -gt 1 ] && log "✅ 多 commit (TDD 痕迹)" || warn "⚠️ 只有 1 个 commit — 流程可能被绕过"
  git log --oneline 2>/dev/null | grep -q "fix:" && log "✅ 有 fix: commit (审查修复痕迹)" || warn "无 fix: commit (或审查未发现问题)"
  local untracked
  untracked=$(git status --short 2>/dev/null | grep -v "^?? .agents" | wc -l)
  [ "$untracked" -eq 0 ] && log "✅ 无未提交文件" || warn "⚠️ 有 $untracked 个未提交文件: $(git status --short | head -3)"

  log "=== 4/4 真实运行抽查 ==="
  log "(手动执行关键路径，见 acceptance-checklist.md)"

  log "=== verify 完成 ==="
}

# ---------------------------------------------------------------- audit
cmd_audit() {
  local dir="$1" spec="${2:-SPEC.md}"
  [ -d "$dir" ] || fail "目录不存在: $dir"
  cd "$dir" || fail "无法进入 $dir"
  [ -f "$spec" ] || { warn "无 spec 文件: $spec — 跳过功能完整性审计"; return; }

  log "=== 功能完整性审计: $spec ==="
  # 提取 spec 中的关键需求点（User Stories / 字段 / 接口）
  grep -oE "(/api/[a-z-]+|--[a-z-]+|by_[a-z_]+|[a-z_]+\\.py|[a-z_]+\\.go)" "$spec" 2>/dev/null | sort -u | while read -r item; do
    # 用 -e 防止 --xxx 被 grep 当作选项参数
    if grep -rq -e "$item" . --exclude-dir=.git --exclude-dir=.agents 2>/dev/null; then
      log "  ✅ $item → 已实现"
    else
      warn "  ⚠️ $item → 未在 src/ 找到 (可能命名不同或缺失)"
    fi
  done
  log "=== audit 完成 (人工复核 ⚠️ 项) ==="
}

# ---------------------------------------------------------------- handoff
cmd_handoff() {
  local dir="$1" msg="$2"
  [ -d "$dir" ] || fail "目录不存在: $dir"
  cd "$dir" || fail "无法进入 $dir"
  # 确保 .agents 不提交（技能文件不该入库）
  if [ -d .agents ] && ! grep -q "^.agents" .gitignore 2>/dev/null; then
    echo ".agents/" >> .gitignore
    log ".gitignore 已追加 .agents/ (技能文件不入库)"
  fi
  git add -A
  git commit -m "$msg" 2>/dev/null && log "已提交: $msg" || warn "无改动可提交"
  local tag
  tag="handoff-$(date +%Y%m%d-%H%M%S)"
  git tag "$tag" && log "已打 tag: $tag (回滚锚点)"
  log "回滚命令: ./wfctl.sh rollback $dir $tag"
}

# ---------------------------------------------------------------- rollback
cmd_rollback() {
  local dir="$1" ref="$2"
  [ -d "$dir" ] || fail "目录不存在: $dir"
  cd "$dir" || fail "无法进入 $dir"
  git reset --hard "$ref" && log "已回滚到 $ref"
  git log --oneline -3
}

# ---------------------------------------------------------------- lookup（阶段 0：先查现成答案）
# 动机（血课 2026-10-09）：遇到"库/框架/工具的报错或行为"先自己摸索，失败多轮才去搜社区 —— 纯浪费。
# 机制：① `lookup` 把"三组必查查询 + 检索记录表 + 结论段"落到任务目录；
#       ② `deleg` 默认**拒绝**没有检索记录的任务书（可用任务书里的显式豁免或 WF_NO_LOOKUP=1 放行）。
_lookup_taskdir() {   # $1=dir  $2=slug(可空)
  local dir="$1" slug="${2:-}"
  if [ -n "$slug" ]; then printf '%s' "$dir/.agents/tasks/$slug"; return; fi
  local d
  d="$(ls -1dt "$dir"/.agents/tasks/*/ 2>/dev/null | head -1 || true)"
  printf '%s' "${d%/}"
}

_lookup_gate() {      # $1=taskdir ⇒ rc=0 通过；rc=1 缺记录/结论空
  local td="$1"
  [ -n "$td" ] || return 1
  # ① 任务书里显式豁免（"不适用 / 已查"）
  if grep -qE '现成答案检索[:：][[:space:]]*(不适用|已查|无现成|N/A|n/a)' "$td/brief.md" 2>/dev/null; then return 0; fi
  # ② lookup.md 存在，且 §4 有**已填的结论行**：以「- 采用…」或「- 结论…」开头 且 该行不含尖括号占位。
  #    （只要求"非空且无 <"会被模板里的说明行蒙过去 —— 所以必须认行首关键词）
  [ -f "$td/lookup.md" ] || return 1
  awk '/^## 4\./{f=1;next} /^## /{f=0} f && $0 ~ /^[-*[:space:]]*(采用|结论)/ && $0 !~ /</ {ok=1} END{exit ok?0:1}' "$td/lookup.md"
}

cmd_lookup() {
  local dir="" question="" slug="" errtext="" check=0 do_search=0 s_count=5
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug)  slug="${2:-}"; shift 2;;
      --error) errtext="${2:-}"; shift 2;;
      --check) check=1; shift;;
      --search) do_search=1; shift;;
      --count) s_count="${2:-5}"; shift 2;;
      *) if [ -z "$dir" ]; then dir="$1"; elif [ -z "$question" ]; then question="$1"; fi; shift;;
    esac
  done
  [ -n "$dir" ] || fail "用法: wfctl.sh lookup <dir> \"<问题一句话>\" [--slug <slug>] [--error \"<错误原文>\"] [--check]"
  [ -d "$dir" ] || fail "目录不存在: $dir"
  local td; td="$(_lookup_taskdir "$dir" "$slug")"
  [ -n "$td" ] || fail "找不到任务目录 —— 先跑: wfctl.sh task <dir> <slug> \"<目标>\"，或用 --slug 指定"

  if [ "$check" = 1 ]; then
    if _lookup_gate "$td"; then log "检索记录齐备: ${td#"$dir"/}/lookup.md"; return 0; fi
    fail "缺检索记录（${td#"$dir"/}/lookup.md 缺失或 §4 结论为空）—— 或在该目录 brief.md 写 '现成答案检索: 不适用（原因…）'"
  fi

  mkdir -p "$td"
  if [ -f "$td/lookup.md" ]; then
    log "已存在（不覆盖）: ${td#"$dir"/}/lookup.md"
  else
    local tpl="$SKILL_ROOT/templates/task/lookup.md.tpl"
    [ -f "$tpl" ] || fail "缺模板: $tpl"
    {
      printf '# 现成答案检索（阶段 0 · 动手前必做）\n\n'
      printf -- '- **问题**：%s\n' "${question:-（未填，补一句）}"
      printf -- '- **生成时间**：%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
      printf -- '- **本文件由** `wfctl lookup` **生成**；填完 §1–§4 后 `wfctl deleg` 才放行。\n\n---\n\n'
      cat "$tpl"
    } > "$td/lookup.md"
    log "已生成: ${td#"$dir"/}/lookup.md"
  fi

  # 官方 Search API 直接取证（DeepSeek /v1/tools/search；结构化 rerank/authority/date/summary）
  if [ "${do_search:-0}" = 1 ] && [ -n "${question:-}" ]; then
    local ds="$SKILL_ROOT/scripts/ds_search.py"
    if [ -f "$ds" ]; then
      log "官方 Search API 检索中…（count=${s_count}）"
      local md rc=0
      md="$(python "$(cygpath -w "$ds" 2>/dev/null || echo "$ds")" "$question" --count "$s_count" --md 2>&1)" || rc=$?
      {
        printf '\n## 2.1 官方 Search 结果（%s｜count=%s｜rc=%s）\n\n' "$(date '+%Y-%m-%d %H:%M')" "$s_count" "$rc"
        if [ "$rc" = 0 ]; then printf '%s\n' "$md"; else printf '自动检索失败（rc=%s）：\n```\n%s\n```\n（手工检索后把结果填进 §2 表）\n' "$rc" "$md"; fi
      } >> "$td/lookup.md"
      if [ "$rc" = 0 ]; then printf '%s\n' "$md"; else warn "自动检索失败 rc=$rc（已写入 lookup.md，可手工补）"; fi
    else
      warn "缺 ds_search.py，跳过自动检索: $ds"
    fi
  fi

  cat <<EOF

现在去查（时间盒 10 分钟 / 最多 3 组查询），把结果填回上面这个文件：
  ① 报错原文加引号（命中率最高）: "${errtext:-<把报错逐字粘这里，别改写>}"
  ② 库 + 版本 + 症状: <lib> <版本，从 package.json / go.mod / --version 抄> <symptom>
  ③ 官方文档 / 社区: site:<docs 域名> <API 或概念>  ｜  site:github.com <lib> <关键字> issue
渠道优先级：官方文档 > CHANGELOG > GitHub issue > 博客；**记下版本与日期**（同一 API 换版本行为会变）。
查到 ⇒ 照抄/改造，停手别再摸；查不到 ⇒ 把"已查 3 条无答案"写进 §4 再自研。
提示：问题一句话 = ${question:-（未填）}
EOF
}

# ---------------------------------------------------------------- deleg
# 委托执行（单会话、无状态）——默认 Pi 主力端；opencode 为备用端（MCP/插件依赖任务）
#
# 【护栏（v1.9.0，全部来自 2026-10-18 实测，不是推测）】
#   CR1 停滞看门狗  19:19 那票 537s：产物全写完但进程不退出、IMPL.md 未写 ⇒ 只能人工 kill。
#   CR2 预期产物    同一票产物落到 plugins/.agents/ 而非任务目录 ⇒ 落点必须机械校验。
#   CR3 单票锁      同目录并发两票会互相覆盖产物/账本。
#   CR4 实测事实    任务书缺「实测事实:」⇒ deepseek-native 首版 7 用例全绿但真跑全废。

# ---------------------------------------------------------------- CR1 进程树终止
# 实测(2026-10-18)：外层 shell 420s 超时被杀后，Pi 子进程又跑了 4 分钟 —— 杀父不杀子。
# 所以终止执行端**必须杀整棵树**；Windows 与 POSIX 两条路径。
_is_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0;; esac; return 1; }

# ⚠️ 实测：MSYS 的 shell PID ≠ Win32 PID（例：msys=1642 / winpid=49252），taskkill 只认后者。
_winpid() {   # $1=shell pid ⇒ Win32 pid（无 /proc 时原样回退）
  local p="$1" w=""
  [ -r "/proc/$p/winpid" ] && w="$(tr -dc '0-9' < "/proc/$p/winpid" 2>/dev/null || true)"
  printf '%s' "${w:-$p}"
}

# 终止进程树。Windows: taskkill /T /F /PID <winpid>；POSIX: 先 TERM 整个进程组再 KILL。
# ⚠️ MSYS 会把 `/T` 当路径改写（实测报 "无效参数 '//T'"）⇒ 必须 MSYS2_ARG_CONV_EXCL='*'。
# 取进程组 id。POSIX 用 `ps -o pgid=`；MSYS 的 ps 不认 -o（实测 unknown option -- o），
# 但默认输出第 3 列就是 PGID（PID PPID PGID WINPID …）⇒ 回退到列解析。
_pgid_of() {
  local p="$1" g=""
  g="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' \r\n' || true)"
  if [ -z "$g" ] && _is_windows; then
    g="$(ps 2>/dev/null | awk -v p="$p" '$1==p {print $3; exit}' || true)"
  fi
  printf '%s' "$g"
}

# 终止进程树。Windows: taskkill /T /F /PID <winpid>（原生子树）+ MSYS 进程组（补 MSYS 孙进程）；
# POSIX: 先 TERM 整个进程组再 KILL。
# ⚠️ 坑1：MSYS 会把 `/T` 当路径改写（实测报 "无效参数 '//T'"）⇒ 必须 MSYS2_ARG_CONV_EXCL='*'。
# ⚠️ 坑2：MSYS2 的 fork 会让孙进程的 Win32 ParentProcessId 指向已退出的壳，taskkill /T **抓不到**
#        （实测 sleep.exe 的父 pid 既不是 bash 的 winpid）；必须靠 MSYS 进程组补杀。
_kill_tree() {   # $1=子进程 pid
  local pid="$1" w pg
  [ -n "$pid" ] || return 0
  pg="$(_pgid_of "$pid")"          # 先取 pgid（leader 被杀后 /proc 会消失）
  [ -n "${WF_DEBUG_KILL:-}" ] && warn "kill_tree: pid=$pid winpid=$(_winpid "$pid") pgid=$pg"
  if _is_windows; then
    w="$(_winpid "$pid")"
    MSYS2_ARG_CONV_EXCL='*' taskkill /T /F /PID "$w" >/dev/null 2>&1 || true
  fi
  # 进程组：**仅当子进程自己是组长**时才组杀（否则会误杀 wfctl 自己那条组）
  if [ -n "$pg" ] && [ "$pg" = "$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$pid" 2>/dev/null || true
  fi
  return 0
}

# 启动执行端（stdin/stdout/stderr 由调用方重定向）。POSIX 用 setsid 建独立进程组，否则组杀会打到 wfctl 自己。
_spawn_exec() {   # $@=命令行 ⇒ 设置 DELEG_CHILD
  set -m      # 开作业控制：后台任务自成进程组（组杀才能连带孙进程；POSIX 下另有 setsid）
  if ! _is_windows && command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
  else
    "$@" &
  fi
  DELEG_CHILD=$!
}

# rpc 专用启动：重定向在**子 shell 里**执行。
# 🔴 实测血课(2026-10-18)：`_spawn_exec cmd < fifo > ev` 的重定向由**父 shell**执行 ——
#    父 shell 先 open(FIFO, O_RDONLY) 就永久阻塞（写端还没人开，因为 spawn 还没返回）⇒
#    整票挂死、执行端根本收不到 prompt 帧、事件流 0 字节（自测 ㉓㉔㉕ 全红就是这么来的）。
# 修法：用 `( exec cmd < fifo > ev 2> err ) &`，open 发生在 fork 出来的子进程里，父 shell 不阻塞。
# $1=stdin 路径  $2=stdout 路径  $3=stderr 路径  其余=命令行
_spawn_exec_redir() {
  local fin="$1" fout="$2" ferr="$3"; shift 3
  set -m
  if ! _is_windows && command -v setsid >/dev/null 2>&1; then
    ( exec setsid "$@" < "$fin" > "$fout" 2> "$ferr" ) &
  else
    ( exec "$@" < "$fin" > "$fout" 2> "$ferr" ) &
  fi
  DELEG_CHILD=$!
}

# json 模式专用：执行端 stdout → slim_events.py（折叠 message_update）→ 事件文件。
# 为什么要管道：事件流 ~76% 的字节是 message_update 增量正文（实测 10.3MB/17.3MB 两张票），
# settled/stop_reason/tokens/最终文本只依赖 message_end/turn_end/agent_settled/usage ⇒ 增量帧纯占盘。
# 重定向必须在**子 shell 里**做（同 _spawn_exec_redir 的 FIFO 血课）；子进程是进程组 leader，
# _kill_tree 能连带杀执行端与 slimmer。
# $1=执行端 stdin 文件  $2=事件文件(Windows 路径)  $3=stderr 文件  $4=slim 脚本(Windows 路径)  其余=命令行
_spawn_exec_slim() {
  local fin="$1" fout="$2" ferr="$3" slim="$4"; shift 4
  set -m
  ( "$@" < "$fin" 2> "$ferr" | "${WF_PYTHON:-python}" "$slim" --out "$fout" ) &
  DELEG_CHILD=$!
}

# 事后就地瘦身（rpc 路径：事件由 rpc_driver.py 直接写盘，插不进管道）。
# 判定只读 message_end/turn_end/agent_settled/usage ⇒ 折叠 message_update 对结果无影响。
# $1=事件文件
_slim_events_in_place() {
  local ev="$1" py slim
  [ -s "$ev" ] || return 0
  slim="$SKILL_ROOT/scripts/slim_events.py"
  [ -f "$slim" ] || { warn "缺少瘦身器: $slim ⇒ 跳过事件瘦身"; return 0; }
  py="$(command -v python || command -v python3 || true)"
  [ -n "$py" ] || { warn "无 python ⇒ 跳过事件瘦身"; return 0; }
  "$py" "$(cygpath -w "$slim" 2>/dev/null || echo "$slim")" \
        --in-place "$(cygpath -w "$ev" 2>/dev/null || echo "$ev")" \
    || warn "事件瘦身失败（保留原文件）"
  return 0
}

# 收到 INT/TERM（含外层 timeout 杀 wfctl）时，连带杀掉执行端整棵树。
_deleg_on_signal() {
  local sig="$1"
  warn "收到 $sig ⇒ 终止执行端进程树（含孙进程）"
  [ -n "${DELEG_CHILD:-}" ] && _kill_tree "$DELEG_CHILD"
  [ -n "${DELEG_LOCK:-}" ] && rm -f "$DELEG_LOCK" 2>/dev/null || true
  case "$sig" in INT) exit 130;; *) exit 143;; esac
}

_dir_hash() {   # $1=绝对路径 ⇒ 前8位哈希（sha1sum 缺失时降级 md5sum/cksum）
  local s="$1" h=""
  if command -v sha1sum >/dev/null 2>&1; then h="$(printf '%s' "$s" | sha1sum 2>/dev/null | cut -c1-8)"
  elif command -v shasum >/dev/null 2>&1; then h="$(printf '%s' "$s" | shasum 2>/dev/null | cut -c1-8)"
  elif command -v md5sum >/dev/null 2>&1; then h="$(printf '%s' "$s" | md5sum 2>/dev/null | cut -c1-8)"
  else h="$(printf '%s' "$s" | cksum 2>/dev/null | tr -dc '0-9' | cut -c1-8)"; fi
  printf '%s' "${h:-00000000}"
}

# 活动指纹：产物目录「文件数 + 最新 mtime」+ 子进程输出字节数。三者任一变化即视为“在干活”。
# 目录采样限 maxdepth 4 并剪掉 .git/node_modules（大仓每 5s 全量 find 不划算）。
_activity_sig() {   # $1=产物根  $2=输出/事件日志  [$3=额外日志，如 stderr]
  local d="$1" f="$2" sz="0" n=0 mx=0 out="" extra="0"
  sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ' || true)"; [ -n "$sz" ] || sz=0
  if [ -n "${3:-}" ]; then
    extra="$(wc -c < "$3" 2>/dev/null | tr -d ' ' || true)"; [ -n "$extra" ] || extra=0
    sz=$((sz + extra))
  fi
  out="$(find "$d" -maxdepth 4 \( -name .git -o -name node_modules -o -name .venv -o -name __pycache__ \) -prune \
          -o -type f -printf '%T@\n' 2>/dev/null || true)"
  if [ -n "$out" ]; then
    n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    mx="$(printf '%s\n' "$out" | sort -n | tail -1)"
  fi
  printf '%s|%s|%s' "$sz" "$n" "${mx%%.*}"
}

_expect_paths() {   # $1=任务书 ⇒ 逐行输出 expect 清单（可多行、逗号分隔）
  grep -E '^[[:space:]]*expect[[:space:]]*[:：]' "$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*expect[[:space:]]*[:：][[:space:]]*//' \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' || true
}

# CR5（只警告不拦，防误伤）：SPEC 里 **CRn** 行既无反引号、也无测试名 ⇒ 打印 WARN，不改 rc
_cr_evidence_warn() {   # $1=任务书 $2=仓库根
  local pf="$1" dir="$2" spec="" line cr
  [ -f "$(dirname "$pf")/SPEC.md" ] && spec="$(dirname "$pf")/SPEC.md"
  if [ -z "$spec" ]; then
    local cand
    cand="$(grep -oE '([A-Za-z]:)?[^[:space:]"`]+SPEC\.md' "$pf" 2>/dev/null | head -1 || true)"
    [ -n "$cand" ] && spec="$cand"
  fi
  [ -n "$spec" ] || return 0
  if [ ! -f "$spec" ] && [ -f "$dir/$spec" ]; then spec="$dir/$spec"; fi
  [ -f "$spec" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cr="$(printf '%s' "$line" | grep -oE 'CR[0-9]+' | head -1 || true)"
    [ -n "$cr" ] || continue
    printf '%s' "$line" | grep -q '`' && continue
    printf '%s' "$line" | grep -qE 'Test[A-Za-z0-9_]+|[A-Za-z0-9_]+_test' && continue
    warn "WARN $cr 缺可执行证据（无反引号命令/无测试名）"
  done < <(grep -E '\*\*CR[0-9]+' "$spec" 2>/dev/null || true)
  return 0
}

_acquire_deleg_lock() {   # $1=绝对路径目录 ⇒ 设置 DELEG_LOCK；活锁则 rc=4
  local h lf p
  h="$(_dir_hash "$1")"
  lf="${TMPDIR:-/tmp}/wfctl-deleg-$h.lock"
  if [ -f "$lf" ]; then
    p="$(tr -dc '0-9' < "$lf" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      failrc 4 "another deleg is running (pid=$p) —— 锁文件: $lf
  等它跑完；确认进程已死后可删: rm -f \"$lf\""
    fi
    warn "发现陈旧锁（pid=${p:-?} 已不存在）⇒ 自动接管: $lf"
  fi
  printf '%s\n' "$$" > "$lf"
  DELEG_LOCK="$lf"
}
_fail_no_key() {   # 统一的无凭据硬失败（print / json 两条路径共用；消息必须是纯字面文本，不得含命令替换）
  # ⚠️ 安全(2026-10-18)：这条消息必须是**纯字面文本**——不得出现命令替换（美元+左括号）、
  # 反斜杠转义或反引号，也不得放可取密钥的命令行。原因：该消息一旦被任何路径执行，
  # 会 grep 出真实 key 并回显到终端（密钥外泄）。只给“怎么做”，不给可粘贴的取 key 命令。
  fail "Pi 没有 DeepSeek 凭据（No API key found）—— 本轮委托什么都没做！
    修复：把 DEEPSEEK_API_KEY=你的密钥 写进 HC_HOME 下的 .env（默认 AppData/Local/hermes/.env
    或 ~/.hermes/.env），或用 WF_ENV_FILE=<路径> 指定文件 —— wfctl 会自动读取并 export（只报长度）。
    仍报此错 = 文件里没有该行或文件不可读。**不要把取密钥的命令行贴进终端**（会把 key 回显到屏幕/日志）。
    或先跑 wfctl envcheck 确认凭据是否已就绪。"
}

# 事件流里的「工具执行中」状态：tool_execution_start 置位，tool_execution_end 清除。
# 为什么需要（实测 2026-10-19）：一张票在**长工具调用**期间事件流本来就静止（无任何帧），
# 旧看门狗只看“有没有新字节”⇒ 把正常干活判成停滞并杀掉。工具执行期间不得计入停滞。
# 只在“将要判停滞”时调用（不是每次轮询），17MB 事件文件 grep 两次也只有几十毫秒。
_event_in_tool() {   # $1=事件文件；返回 0=工具执行中
  local ev="$1" ns ne
  [ -f "$ev" ] || return 1
  ns="$(grep -c 'tool_execution_start' "$ev" 2>/dev/null || true)"
  ne="$(grep -c 'tool_execution_end' "$ev" 2>/dev/null || true)"
  ns="${ns:-0}"; ne="${ne:-0}"
  [ "$ns" -gt "$ne" ] 2>/dev/null || return 1
  return 0
}

# 停滞看门狗：连续 $5 秒「产物 mtime + 输出/事件日志字节数」无变化 ⇒ 杀子进程，置 _stalled=1
# 例外：事件流显示工具正在执行（tool_execution_start 已到、end 未到）⇒ 不计入停滞，阈值顺延。
# $1=子进程 pid  $2=产物根  $3=输出/事件日志  $4=额外日志(可空)  $5=stall 秒（0=关闭）
_deleg_watch() {
  local child="$1" root="$2" outlog="$3" extra="${4:-}" stall="$5"
  _stalled=0
  if ! [ "$stall" -gt 0 ] 2>/dev/null; then return 0; fi
  local _prev _last _now _sig _tick=0
  _prev="$(_activity_sig "$root" "$outlog" "$extra")"
  _last=$(date +%s)
  while kill -0 "$child" 2>/dev/null; do
    sleep 0.25                                  # 轮询要快（否则每票白加 1s），采样才按 5s
    _tick=$((_tick+1))
    kill -0 "$child" 2>/dev/null || break
    if [ $((_tick % 20)) -eq 0 ]; then          # 每 5s 采样一次（不是每 0.25s 跑 find）
      _sig="$(_activity_sig "$root" "$outlog" "$extra")"
      if [ "$_sig" != "$_prev" ]; then _prev="$_sig"; _last=$(date +%s); fi
    fi
    _now=$(date +%s)
    if [ $((_now - _last)) -ge "$stall" ]; then
      if _event_in_tool "$outlog"; then
        _last=$_now                          # 工具执行中：不计入停滞（本来就不产生事件）
      else
        warn "STALLED after $((_now - _last))s（无事件且不在工具执行中，阈值 ${stall}s）⇒ 终止执行端进程树"
        _kill_tree "$child"
        _stalled=1
        break
      fi
    fi
  done
}

# ---------------------------------------------------------------- CR4 RPC abort
# rpc 模式：事件流同样落盘到 evfile，另开 fd3 给执行端 stdin 写帧。
_rpc_send() { printf '%s\n' "$1" >&3 2>/dev/null; }

_rpc_settled_now() { tail -c 4096 "$1" 2>/dev/null | grep -q '"type":"agent_settled"'; }

# RPC 看门狗：正常等到 agent_settled；停滞/超时先发 abort，≤10s 不结束才退化杀进程树。
# $1=子进程 pid  $2=产物根  $3=事件文件  $4=stderr 日志  $5=stall 秒（0=关闭）
_deleg_watch_rpc() {
  local child="$1" root="$2" ev="$3" extra="${4:-}" stall="$5"
  _stalled=0; _rpc_settled=0; _rpc_aborted=0
  local _prev="" _last _now _sig _tick=0 i
  _last=$(date +%s)
  [ "$stall" -gt 0 ] 2>/dev/null && _prev="$(_activity_sig "$root" "$ev" "$extra")"
  while kill -0 "$child" 2>/dev/null; do
    sleep 0.25
    _tick=$((_tick+1))
    if _rpc_settled_now "$ev"; then _rpc_settled=1; break; fi
    kill -0 "$child" 2>/dev/null || break
    if [ "$stall" -gt 0 ] 2>/dev/null && [ $((_tick % 20)) -eq 0 ]; then
      _sig="$(_activity_sig "$root" "$ev" "$extra")"
      if [ "$_sig" != "$_prev" ]; then _prev="$_sig"; _last=$(date +%s); fi
    fi
    _now=$(date +%s)
    if [ "$stall" -gt 0 ] 2>/dev/null && [ $((_now - _last)) -ge "$stall" ]; then
      if _event_in_tool "$ev"; then
        _last=$_now                          # 工具执行中：不计入停滞
        continue
      fi
      warn "STALLED after $((_now - _last))s（RPC 侧无事件且不在工具执行中，阈值 ${stall}s）⇒ 发 abort 帧"
      _rpc_send '{"type":"abort"}' || true
      for i in $(seq 1 40); do            # ≤10s
        if _rpc_settled_now "$ev" || ! kill -0 "$child" 2>/dev/null; then _rpc_aborted=1; break; fi
        sleep 0.25
      done
      if [ "$_rpc_aborted" = 1 ]; then
        warn "abort 生效（≤10s）——未退化 kill"
      else
        warn "abort 无响应（>10s）⇒ 退化 kill 进程树"
        _kill_tree "$child"
      fi
      _stalled=1
      break
    fi
  done
}

# 事件流 → 三态元信息 + usage tokens（json / rpc 两条路径共用）。
# 写入调用方（动态作用域）的局部变量：
#   _settled _stop _badstops _nokey _errmsg _in_tok _out_tok
# $1=事件文件  $2=最终文本输出文件
_parse_events() {
  local evw txtw meta _k _v _usage_seen=0
  evw="$(cygpath -w "$1" 2>/dev/null || echo "$1")"
  txtw="$(cygpath -w "$2" 2>/dev/null || echo "$2")"
  meta="$(python - "$evw" "$txtw" <<'PYEV' 2>/dev/null
import json, sys
# 事件流 → (最终 assistant 文本, 三态元信息, usage tokens)。只做保守解析：坏行跳过，缺字段不报错。
ev, outp = sys.argv[1], sys.argv[2]
settled = 0
text = ""
n_asst = 0
stops = []
errmsg = ""
nokey = 0
in_tok = 0
out_tok = 0
usage_seen = 0
try:
    fh = open(ev, encoding="utf-8", errors="replace")
except OSError:
    fh = []
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
        settled = 1
        continue
    if t == "compaction_end":
        r = d.get("result") or {}
        u = (r.get("usage") if isinstance(r, dict) else None) or {}
        if isinstance(u, dict) and u:
            usage_seen += 1
            in_tok += int(u.get("input") or 0)
            out_tok += int(u.get("output") or 0)
        continue
    m = None
    if t in ("message_end", "turn_end"):
        m = d.get("message")
    elif t == "agent_end":
        # 保守分支：没有 message_end 事件时，从 agent_end 的消息快照里取最后一条 assistant 文本
        for cand in reversed(d.get("messages") or []):
            if isinstance(cand, dict) and cand.get("role") == "assistant":
                parts = [c.get("text", "") for c in (cand.get("content") or [])
                         if isinstance(c, dict) and c.get("type") == "text"]
                if any(parts) and not text:
                    text = "\n".join(parts)
                break
        continue
    if not isinstance(m, dict):
        continue
    # usage 只认 message_end：turn_end 与 message_end 会对同一条消息重复计
    if t == "message_end":
        u = m.get("usage") or {}
        if isinstance(u, dict) and u:
            usage_seen += 1
            in_tok += int(u.get("input") or 0)
            out_tok += int(u.get("output") or 0)
    if m.get("role") != "assistant":
        continue
    n_asst += 1
    sr = m.get("stopReason") or m.get("stop_reason") or ""
    stops.append(sr)
    em = m.get("errorMessage") or m.get("error_message") or ""
    if em:
        errmsg = str(em).replace("\n", " ")[:300]
        if "no api key found" in errmsg.lower():
            nokey = 1
    parts = [c.get("text", "") for c in (m.get("content") or [])
             if isinstance(c, dict) and c.get("type") == "text"]
    if any(parts):
        text = "\n".join(parts)
last = stops[-1] if stops else "none"
bad = sum(1 for s in stops if s in ("error", "aborted", "length"))
try:
    with open(outp, "w", encoding="utf-8", newline="\n") as f:
        if text:
            f.write(text + "\n")
except OSError:
    pass
print("settled=%d" % settled)
print("stop_reason=%s" % (last or "none"))
print("bad_stops=%d" % bad)
print("nokey=%d" % nokey)
print("msgs=%d" % n_asst)
print("errmsg=%s" % (errmsg or "none"))
print("usage_seen=%d" % usage_seen)
print("in_tokens=%d" % in_tok)
print("out_tokens=%d" % out_tok)
PYEV
)" || meta=""
  meta="$(printf '%s' "$meta" | tr -d '\r')"        # 原生 python 在 Windows 上输出 CRLF，必须剔除
  while IFS='=' read -r _k _v; do
    case "$_k" in
      settled) _settled="$_v" ;;
      stop_reason) _stop="$_v" ;;
      bad_stops) _badstops="$_v" ;;
      nokey) _nokey="$_v" ;;
      errmsg) _errmsg="$_v" ;;
      usage_seen) _usage_seen="$_v" ;;
      in_tokens) _in_tok="$_v" ;;
      out_tokens) _out_tok="$_v" ;;
    esac
  done <<< "$meta"
  # 没有 usage（provider 不报/老事件流）⇒ 置空，不写 tokens/cost（不报错也不算 0 成本）
  if [ "${_usage_seen:-0}" = 0 ]; then _in_tok=""; _out_tok=""; fi
}

cmd_deleg() {
  # 默认停滞阈值 600s（原 180s）：实测长工具调用（pytest/构建/大范围 grep）期间事件流与产物 mtime
  # 都可能长时间不动，180s 会把正常干活的一票误杀成 rc=124；600s 只兜真正卡死的票。
  local dir="" promptfile="" agent="pi" stall=600 stall_set=0
  local _mode="" _events="" _stop_mode="kill" resume=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --stall-timeout) stall="${2:-600}"; stall_set=1; shift 2;;
      --stall-timeout=*) stall="${1#*=}"; stall_set=1; shift;;
      --mode) _mode="${2:-}"; shift 2;;
      --mode=*) _mode="${1#*=}"; shift;;
      --events) _events="${2:-}"; shift 2;;
      --events=*) _events="${1#*=}"; shift;;
      --stop-mode) _stop_mode="${2:-kill}"; shift 2;;
      --stop-mode=*) _stop_mode="${1#*=}"; shift;;
      --continue|-c) resume=1; shift;;
      -*) fail "未知参数: $1（可用: --stall-timeout N --mode json|print --events <path> --stop-mode kill|rpc --continue）";;
      *) if [ -z "$dir" ]; then dir="$1"
         elif [ -z "$promptfile" ]; then promptfile="$1"
         else agent="$1"; fi
         shift;;
    esac
  done
  [ -n "$dir" ] && [ -n "$promptfile" ] || fail "用法: wfctl.sh deleg <dir> <promptfile> [pi|opencode] [--stall-timeout N] [--mode json|print] [--events <path>] [--stop-mode kill|rpc] [--continue]"
  case "$stall" in ''|*[!0-9]*) fail "--stall-timeout 需要非负整数秒: $stall";; esac
  # 模式优先级：--mode > WF_DELEG_MODE > 默认 json（事件驱动）
  [ -n "$_mode" ] || _mode="${WF_DELEG_MODE:-json}"
  case "$_mode" in
    json|print) ;;
    *) fail "--mode 只接受 json|print: $_mode";;
  esac
  case "$_stop_mode" in
    kill|rpc) ;;
    *) fail "--stop-mode 只接受 kill|rpc: $_stop_mode";;
  esac
  if [ "$_stop_mode" = "rpc" ] && [ "$_mode" = "print" ]; then
    warn "--stop-mode rpc 需要事件流 ⇒ 与 --mode print 冲突，按 kill 执行"
    _stop_mode="kill"
  fi
  [ -d "$dir" ] || fail "目录不存在: $dir"
  # promptfile 允许写相对 $dir 的路径（`wfctl task` 打印的下一步就是相对路径，实测踩过：相对路径会按 cwd 解析）
  if [ ! -f "$promptfile" ] && [ -f "$dir/$promptfile" ]; then promptfile="$dir/$promptfile"; fi
  [ -f "$promptfile" ] || fail "prompt 文件不存在: $promptfile"
  cd "$dir" || fail "无法进入 $dir"
  local run_rc=0 _stalled=0 _expect_miss=0 root
  local in_tok="" out_tok="" led_model="${PI_MODEL:-deepseek-v4-flash}"
  root="$(pwd -P)"

  # 【阶段 0 门禁】任务书必须带"现成答案检索"记录 —— 防"先自己摸索、失败多轮才去搜社区"（血课 2026-10-09）。
  # _td 取绝对路径：CR2 的固定 session（<promptdir>/pi-session）不能随 cwd 飘。
  local _td; _td="$(cd "$(dirname "$promptfile")" 2>/dev/null && pwd -P)" || _td="$(dirname "$promptfile")"
  if [ -z "${WF_NO_LOOKUP:-}" ]; then
    if ! _lookup_gate "$_td"; then
      fail "委托被拒：$(basename "$_td") 没有'现成答案检索'记录
  → 先查:  wfctl.sh lookup $dir \"<问题一句话>\" --slug $(basename "$_td")
           把三组查询结果填进 .agents/tasks/$(basename "$_td")/lookup.md 的 §4 结论
  → 属仓库内部结构问题（自读源码更快）: 在 brief.md 里写  '现成答案检索: 不适用（原因…）'
  → 确实要临时跳过: WF_NO_LOOKUP=1 bash wfctl.sh deleg ..."
    fi
    log "阶段 0 检索记录: .agents/tasks/$(basename "$_td")/lookup.md ✓"
  else
    warn "阶段 0 门禁已跳过（WF_NO_LOOKUP=1）"
  fi

  # 【CR4 实测事实门禁】血课 2026-10-18：deepseek-native 首版 7 个离线用例全绿，真跑全废 ——
  # 根因是任务书里没有一行“实测事实”（执行端只能猜）。把实测写进任务书后一次就过。
  if ! grep -qE '^实测事实[:：]' "$promptfile" 2>/dev/null; then
    failrc 5 "委托被拒：任务书缺行首「实测事实:」行（rc=5）
  为什么拦：只写推测/设计意图的票，执行端会把“合理”当成“正确”（实测：7 用例全绿、真跑全废）。
  写法（任选一个，必须行首）:
    实测事实: 今天 deleg 6 票，4 票真跑 rc=0（264/537/331/113s），2 票 rc=1 是 lookup 门禁拒
    实测事实: 不适用（纯内部重构，无外部行为变化）
  → 文件: $promptfile"
  fi
  if grep -qE '^实测事实[:：][[:space:]]*不适用' "$promptfile" 2>/dev/null; then
    log "实测事实门禁: 豁免（不适用）✓"
  else
    log "实测事实门禁: 已声明 ✓"
  fi

  # 【CR5】只警告不拦：SPEC 里 CRn 行没有任何可执行证据
  _cr_evidence_warn "$promptfile" "$(pwd -P)"

  # 【CR3 单票锁】同目录同时只允许一票 deleg（产物/账本互相覆盖）。
  _acquire_deleg_lock "$(pwd -P)"
  # CR1：INT/TERM（含外层 timeout 杀 wfctl）时必须连带杀掉执行端进程树，否则留下孤儿 Pi
  trap '_deleg_on_signal INT' INT
  trap '_deleg_on_signal TERM' TERM
  [ "$stall_set" = 1 ] && log "停滞看门狗: ${stall}s（0=关闭）"
  [ "$_stop_mode" = "rpc" ] && log "终止策略: rpc（先发 abort 等 ≤10s，再退化杀进程树）"

  # 【执行环境优先级】：任务书 > 任何技能（superpowers 等）的默认流程。实测(2026-10-08)：Pi 挂着官方 6.4.2 后，
  # brainstorming 要审批门、writing-plans 往 docs/superpowers/ 写、using-git-worktrees 会停下来问 —— 无人值守会因此断链。
  local pre=""
  local _pre_f="$SKILL_ROOT/templates/task/preamble.txt"
  if [ -n "${WF_TEMPLATE_LANG:-}" ] && [ -f "$SKILL_ROOT/templates/task/preamble.${WF_TEMPLATE_LANG}.txt" ]; then
    _pre_f="$SKILL_ROOT/templates/task/preamble.${WF_TEMPLATE_LANG}.txt"
  fi
  if [ -z "${WF_NO_PREAMBLE:-}" ] && [ -f "$_pre_f" ]; then
    pre="$(cat "$_pre_f")"
  fi
  case "$agent" in
    pi)
      local pi_bin="${PI_BIN:-$HOME/Downloads/pi-agent/pi.exe}"
      [ -x "$pi_bin" ] || fail "pi 不可执行: $pi_bin（用 PI_BIN 指定，或 --agent opencode 走备用端）"
      # 任务书走 stdin（长文本不受命令行长度限制）。⚠️ 实测(2026-10-08)：管道**只在不给消息参数时**被读入
      # ——必须裸用 `-p`；写成 `-p "文字"` 会把管道内容丢掉。
      # thinking 后缀：PI_THINKING="" 可显式去掉（本地模型不支持 reasoning effort，加了会报错）
      # 代理：本机实测(2026-10-09)——Pi 默认会走 Windows 系统代理（Clash），该路径失效时报 Connection error；
      # 显式给 PI_PROXY（如 http://127.0.0.1:7890）或 PI_NO_PROXY=1 都能通。
      if [ -n "${PI_PROXY:-}" ]; then export HTTPS_PROXY="$PI_PROXY" HTTP_PROXY="$PI_PROXY"; log "代理: $PI_PROXY"; fi
      if [ -n "${PI_NO_PROXY:-}" ]; then export NO_PROXY='*' no_proxy='*'; log "代理: 已显式禁用（NO_PROXY=*）"; fi
      local pi_model="${PI_MODEL:-deepseek-v4-flash}"
      [ -n "${PI_THINKING-low}" ] && pi_model="$pi_model:${PI_THINKING-low}"
      # 【CR2 会话可续】每票固定 session 文件 <promptdir>/pi-session：同一票重跑/--continue 都接在上文。
      # ⚠️ 实测(2026-10-18)：Pi 是原生程序，`--session /d/x/pi-session` 会被当成 `C:\d\x\...`（落错盘）
      # ⇒ 必须传 Windows 路径；ledger 里记 POSIX 形式（人看得懂）。
      local pi_session pi_session_arg
      pi_session="$_td/pi-session"; pi_session_arg="$pi_session"
      if _is_windows; then pi_session_arg="$(cygpath -w "$pi_session" 2>/dev/null || echo "$pi_session")"; fi
      local pi_common=(--provider "${PI_PROVIDER:-deepseek}" --model "$pi_model" --session "$pi_session_arg")
      [ "$resume" = 1 ] && pi_common+=(--continue)
      local pi_args=("${pi_common[@]}" -a -p)
      LEDGER_SESSION="$pi_session"
      [ "$resume" = 1 ] && log "续跑: 复用固定 session（$pi_session）"
      local trace=""
      if [ -n "${PI_PROVIDER:-}" ]; then log "执行端 provider=$PI_PROVIDER model=${PI_MODEL:-deepseek-v4-flash}"; fi
      local pi_out outlog errlog infile child
      _stalled=0
      infile="$(mktemp "${TMPDIR:-/tmp}/wfctl-deleg-in.XXXXXX")"
      { printf '【任务书——请按此完整执行】\n'; [ -n "$pre" ] && printf '%s\n\n' "$pre"; cat "$promptfile"; printf '\n【任务书结束——现在开始自主执行，不要中途停下等待批准】\n'; } > "$infile"
      LEDGER_NOTE="$(basename "$(dirname "$promptfile")")"

      if [ "$_mode" = "print" ]; then
        # ================= print 模式（旧路径，行为与升级前逐字一致）=================
        log "委托执行 (Pi 主力 · 无头 print 模式 · 单会话无状态)..."
        if [ -n "${PI_TRACE:-}" ]; then
          trace="$dir/.agents/tasks/$(basename "$(dirname "$promptfile")")/pi-trace.jsonl"
          mkdir -p "$(dirname "$trace")"
          pi_args+=(--mode json)
          log "轨迹模式 (PI_TRACE=1)：工具调用/探索轮次计入时程基线；原始事件流 → ${trace#"$dir"/}"
        fi
        outlog="$(mktemp "${TMPDIR:-/tmp}/wfctl-deleg-out.XXXXXX")"
        # 后台跑子进程 + 看门狗采样：子进程输出只能写文件（原命令替换行为完全一致，末尾统一打印）
        _spawn_exec "$pi_bin" "${pi_args[@]}" < "$infile" > "$outlog" 2>&1
        child="$DELEG_CHILD"
        rm -f "$infile"
        _deleg_watch "$child" "$root" "$outlog" "" "$stall"
        if [ "$_stalled" = 1 ]; then run_rc=124; else wait "$child" 2>/dev/null || run_rc=$?; fi
        pi_out="$(cat "$outlog" 2>/dev/null || true)"
        rm -f "$outlog"
        if [ -n "${PI_TRACE:-}" ]; then
          printf '%s\n' "$pi_out" > "$trace"
          local lpy; lpy="$(cygpath -w "$SKILL_ROOT/scripts/run_ledger.py" 2>/dev/null || echo "$SKILL_ROOT/scripts/run_ledger.py")"
          local tw; tw="$(cygpath -w "$trace")"
          LEDGER_EXTRA="$(python "$lpy" trace-stats "$tw" --stats)"
          printf '%s\n' "$LEDGER_EXTRA"
          pi_out="$(python "$lpy" trace-stats "$tw" | tail -n +2)"
          printf '%s\n' "$pi_out"
          # ⚠️ 实测(2026-10-09)：网络/模型连接错误时 pi 会 auto_retry 3 次后放弃，rc=0、零输出、**零工具调用**
          # ——表面“委托完成”，实际什么都没做（又一个白跑形态）。这里硬失败，并把 trace 里的真实错误带出来。
          if ! printf '%s' "$LEDGER_EXTRA" | grep -q 'tool_calls=[1-9]'; then
            local ferr; ferr="$(python "$lpy" trace-stats "$tw" --final-error 2>/dev/null | head -1 || true)"
            fail "本轮**零工具调用**——Pi 什么都没做（rc=0 但零产出）！
    轨迹里的错误：$ferr
    常见原因：网络/代理不通、模型不可用、provider 配置错。
    本机实测(2026-10-09)：若错误是 Connection error ☞ 加 PI_PROXY=http://127.0.0.1:7890 或 PI_NO_PROXY=1 重跑
    （Pi 默认走 Windows 系统代理，该路径可能失效；curl/node 直连正常但 Pi 报 Connection error 就是它）。
    轨迹见 ${trace#"$dir"/}。"
          fi
        else
          printf '%s\n' "$pi_out"
        fi
        LEDGER_OUT_BYTES="${#pi_out}"                # 时程基线：零产出检测靠它（配合 rc 判"白跑"）
        # CR7：print 模式没有事件流，settled 按退出码保守推定（0 视为本轮正常结束），stop_reason 记 none
        local _p_settled=0
        if [ "$run_rc" -eq 0 ]; then _p_settled=1; fi
        LEDGER_EXTRA="mode=print settled=$_p_settled stop_reason=none ${LEDGER_EXTRA:-}"
        # ⚠️ 实测(2026-10-08)：桌面端重启后 shell 环境丢失 ⇒ pi 报 "No API key found" 却 **rc=0**、
        # 什么都没做（一轮白跑且看起来“成功”）——必须在这里硬失败，否则静默零产出。
        # 🔴 只认「以错误行开头」的 No API key found（2026-10-18 实测假阳性：任务输出里引用这句话时，
        #    旧的全串 grep 会把正常完成的一票误判成"没凭据"，rc=1）。
        if printf '%s\n' "$pi_out" | grep -qiE '^[[:space:]]*(error[: ]+)?no api key found' \
           || { [ -n "${trace:-}" ] && grep -qiE '^[[:space:]]*(error[: ]+)?no api key found' "$trace" 2>/dev/null; }; then
          _fail_no_key
        fi
      else
        # ================= 事件驱动（json 默认 / rpc 可选）=================
        # 官方语义（本机 0.85.1 实测 12 条事件）：agent_end 之后仍可能有重试/压缩/排队，
        # **agent_settled 才是“本轮自动工作真正结束”**；且 JSON 模式下失败/中止**不体现在退出码**
        # ⇒ 必须解析事件流才能判三态（rc=0/6/7），旧版靠 grep 输出已出现过假阳性。
        local evfile="${_events:-$(dirname "$promptfile")/deleg-events.jsonl}"
        mkdir -p "$(dirname "$evfile")" 2>/dev/null || true
        : > "$evfile" 2>/dev/null || fail "无法写入事件文件: $evfile"
        errlog="$(mktemp "${TMPDIR:-/tmp}/wfctl-deleg-err.XXXXXX")"
        local _txt _settled=0 _stop=none _badstops=0 _nokey=0 _errmsg="" _in_tok=0 _out_tok=0 _mlabel="json"
        _txt="$(mktemp "${TMPDIR:-/tmp}/wfctl-deleg-txt.XXXXXX")"
        if [ "$_stop_mode" = "rpc" ]; then
          # ===== CR4 rpc 模式（v1.12.0）：交给 Python 驱动器直连 stdin/stdout =====
          # 🔴 实测血课(2026-10-18)：bash 的 FIFO + fd3 + 重定向在 Windows 原生 pi.exe 下
          #    拿不到 stdout —— Pi 干完了活，事件流却 0 字节，成功被报成失败（假绿）。
          #    改用 scripts/rpc_driver.py 的 subprocess 管道，一次跑通。
          # 语义不变：正常等 agent_settled(0)；停滞发 abort，宽限后仍无 settled ⇒ 杀树(124)。
          _mlabel="rpc"
          log "委托执行 (Pi 主力 · --mode rpc · Python 驱动器 · 固定 session)..."
          log "事件流落盘 → $evfile"
          local drv drvw inw evw errw drc=0
          drv="$SKILL_ROOT/scripts/rpc_driver.py"
          [ -f "$drv" ] || fail "缺少 RPC 驱动器: $drv"
          drvw="$(cygpath -w "$drv" 2>/dev/null || echo "$drv")"
          inw="$(cygpath -w "$infile" 2>/dev/null || echo "$infile")"
          evw="$(cygpath -w "$evfile" 2>/dev/null || echo "$evfile")"
          errw="$(cygpath -w "$errlog" 2>/dev/null || echo "$errlog")"
          local dargs=(--pi-bin "$pi_bin" --provider "${PI_PROVIDER:-deepseek}" --model "$pi_model"
                       --prompt-file "$inw" --events "$evw" --stderr "$errw"
                       --idle-timeout "$stall" --abort-grace 10)
          [ -n "$pi_session_arg" ] && dargs+=(--session "$pi_session_arg")
          [ "$resume" = 1 ] && dargs+=(--continue)
          python "$drvw" "${dargs[@]}" > "$_txt" 2>> "$errlog" || drc=$?
          rm -f "$infile"
          run_rc="$drc"
          [ "$drc" = 124 ] && _stalled=1
        else
          # ===== json 模式（默认；旧路径只多了一条 --session + 事件瘦身）=====
          log "委托执行 (Pi 主力 · --mode json · 事件驱动 · 固定 session)..."
          log "事件流落盘 → $evfile（message_update 折叠）"
          local slim_py
          slim_py="$SKILL_ROOT/scripts/slim_events.py"
          if [ -f "$slim_py" ] && { command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; }; then
            # 事件瘦身（流式）：stdout 经 slim_events.py 折叠 message_update 后落盘。
            _spawn_exec_slim "$infile" \
              "$(cygpath -w "$evfile" 2>/dev/null || echo "$evfile")" \
              "$(cygpath -w "$errlog" 2>/dev/null || echo "$errlog")" \
              "$(cygpath -w "$slim_py" 2>/dev/null || echo "$slim_py")" \
              "$pi_bin" "${pi_args[@]}" --mode json
          else
            warn "缺少 slim_events.py 或 python ⇒ 不做事件瘦身（原始事件直接落盘）"
            _spawn_exec "$pi_bin" "${pi_args[@]}" --mode json < "$infile" > "$evfile" 2> "$errlog"
          fi
          child="$DELEG_CHILD"
          rm -f "$infile"
          _deleg_watch "$child" "$root" "$evfile" "$errlog" "$stall"
          if [ "$_stalled" = 1 ]; then run_rc=124; else wait "$child" 2>/dev/null || run_rc=$?; fi
          # 管道退出码取的是最后一个命令（slimmer）—— 真正的三态下面看事件流；
          # 但只要事件流里有 settled/坏 stop，就以事件为准（与升级前一致）。
          [ -f "$evfile" ] || warn "事件文件未落盘: $evfile"
        fi
        if [ -s "$errlog" ]; then cat "$errlog" >&2; fi     # stderr 原样转发（不混进 stdout）
        rm -f "$errlog"
        # rpc 路径：driver 直接把事件写盘（插不进管道）⇒ 跑完就地折叠 message_update。
        # 判定只读 message_end/turn_end/agent_settled/usage ⇒ 瘦身前后的 settled/stop_reason/
        # tokens/最终文本逐项一致（C 验收实测）。
        if [ "$_mlabel" = "rpc" ]; then _slim_events_in_place "$evfile"; fi

        _parse_events "$evfile" "$_txt"
        if [ "$_errmsg" = "none" ]; then _errmsg=""; fi
        in_tok="$_in_tok"; out_tok="$_out_tok"

        # 三态判定（顺序：停滞 124 > 异常 stop_reason 6 > settled 0 > 无 settled 7）
        # rpc 模式以 Python 驱动器的退出码为准（它逐事件判定，且 abort 后仍为 124）。
        if [ "$_stalled" != 1 ] && [ "$_mlabel" != "rpc" ]; then
          case "$_stop" in
            error|aborted|length) run_rc=6 ;;
            *) if [ "$_settled" = 1 ]; then run_rc=0; else run_rc=7; fi ;;
          esac
        fi

        # stdout 只打印 assistant 最终文本（绝不混入原始 JSONL）
        pi_out=""
        if [ -s "$_txt" ]; then
          pi_out="$(cat "$_txt")"
          printf '%s\n' "$pi_out"
        fi
        rm -f "$_txt"

        log "事件判定: mode=$_mlabel settled=$_settled stop_reason=$_stop${in_tok:+ tokens=${in_tok}/${out_tok}}"
        case "$_stop" in
          error|aborted|length)
            warn "执行端异常结束: stop_reason=$_stop（rc=6）${_errmsg:+ —— $_errmsg}" ;;
        esac
        if [ "$_stalled" != 1 ] && [ "$_settled" != 1 ]; then
          warn "NO agent_settled —— 进程已退出，但事件流里没有『本轮自动工作结束』标记 ⇒ rc=7"
        fi
        if [ "$_stalled" != 1 ] && [ "$_settled" = 1 ] && [ "$_badstops" != 0 ] && [ "$_stop" != "error" ] \
           && [ "$_stop" != "aborted" ] && [ "$_stop" != "length" ]; then
          warn "事件流里出现过 $_badstops 次异常 stop_reason，但最终 settled（视为自动重试后恢复，rc=0）"
        fi

        LEDGER_OUT_BYTES="${#pi_out}"
        LEDGER_EXTRA="mode=$_mlabel settled=$_settled stop_reason=$_stop"
        [ -n "$in_tok" ] && LEDGER_EXTRA="$LEDGER_EXTRA in_tokens=$in_tok out_tokens=$out_tok model=$led_model"
        if [ -n "${PI_TRACE:-}" ]; then
          trace="$dir/.agents/tasks/$(basename "$(dirname "$promptfile")")/pi-trace.jsonl"
          mkdir -p "$(dirname "$trace")"
          cp "$evfile" "$trace" 2>/dev/null || true
          local lpy2; lpy2="$(cygpath -w "$SKILL_ROOT/scripts/run_ledger.py" 2>/dev/null || echo "$SKILL_ROOT/scripts/run_ledger.py")"
          local tw2; tw2="$(cygpath -w "$trace")"
          LEDGER_EXTRA="$LEDGER_EXTRA $(python "$lpy2" trace-stats "$tw2" --stats 2>/dev/null || true)"
          log "轨迹已另存 → ${trace#"$dir"/}（PI_TRACE=1）"
        fi
        # 凭据：只认 assistant 消息的 errorMessage（任务书正文里引用这句话不算）
        if [ "$_nokey" = 1 ]; then _fail_no_key; fi
      fi
      ;;
    opencode)
      [ "$_mode" = "json" ] && warn "opencode 无 json 事件流 ⇒ 按 print 旧路径执行"
      log "委托执行 (opencode 备用端 · --pure · 单会话)..."
      LEDGER_EXTRA="mode=print"
      # ⚠️ 实测(2026-10-08)：opencode 的默认模型是本地 qwen3.8-27b（DGX:8001）——不通时整轮直接失败，
      # 必须显式指定模型（OC_MODEL 可覆盖）。
      opencode run -m "${OC_MODEL:-deepseek/deepseek-flash}" "${pre:+$pre

}$(cat "$promptfile")" --pure 2>&1
      ;;
    *)
      fail "未知执行端: $agent (pi|opencode)" ;;
  esac

  # 【CR2 预期产物清单】任务书 `expect: a/b.go, c/d.go`（相对仓库根）—— 落点错了必须报。
  local _p
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    if [ -e "$root/$_p" ] || [ -e "$_p" ]; then
      :
    else
      printf 'MISSING: %s\n' "$_p"
      _expect_miss=$((_expect_miss + 1))
    fi
  done < <(_expect_paths "$promptfile")
  LEDGER_EXTRA="${LEDGER_EXTRA:+$LEDGER_EXTRA }stalled=$_stalled missing=$_expect_miss"
  if [ "$_expect_miss" -gt 0 ]; then
    warn "预期产物缺失 $_expect_miss 个（rc=${run_rc}，空则置 3）"
    [ "$run_rc" -eq 0 ] && run_rc=3
  fi
  if [ "$run_rc" -eq 0 ]; then
    log "委托完成 — 记得跑 verify（不信 agent 自述）"
  elif [ "$run_rc" -eq 124 ]; then
    warn "本轮判为停滞（rc=124）——产物可能只写了一半，先人工看现场再重跑"
  else
    warn "委托未正常完成（rc=$run_rc）"
  fi
  # 【CR2 会话可续】异常结束（6=stop_reason 异常 / 7=无 settled / 124=停滞）⇒ 给可续跑命令。
  # 同一票固定 session 已落盘，重跑即接上文（--continue 显式声明复用）。
  case "$run_rc" in
    6|7|124)
      printf '可续跑：wfctl.sh deleg %s %s --continue\n' "$dir" "$promptfile" ;;
  esac
  exit "$run_rc"
}

cmd_testbaseline() {
  local dir="${1:-.}" cmd="${2:-}"
  [ -d "$dir/.agents" ] || fail "先 wfctl task 建 .agents/：$dir"
  [ -n "$cmd" ] || cmd="pytest -q"
  log "记录既有失败基线（$cmd）…"
  local out; out="$(cd "$dir" && eval "$cmd" 2>&1)" || true
  local n; n="$(printf '%s\n' "$out" | grep -oE '^FAILED [^ ]+' | sed 's/^FAILED //' | sort -u | tee "$dir/.agents/pytest-baseline.txt" | grep -c .)"
  log "已写入 $dir/.agents/pytest-baseline.txt（$n 条既有失败）"
  log "以后 verify 只对**新增**失败发红；要更新基线就重跑本命令"
}

cmd_diffcov() {
  local dir="${1:-.}"; shift || true
  local py; py="$(cygpath -w "$HC_SCRIPTS/diffcov.py" 2>/dev/null || echo "$HC_SCRIPTS/diffcov.py")"
  [ -f "$py" ] || fail "缺少 diffcov.py: $py"
  python "$py" "$(cygpath -w "$dir" 2>/dev/null || echo "$dir")" "$@"
}

cmd_map() {
  local dir="$1"; shift || true
  [ -d "$dir" ] || fail "目录不存在: $dir"
  local py; py="$(cygpath -w "$SKILL_ROOT/scripts/repo_map.py" 2>/dev/null || echo "$SKILL_ROOT/scripts/repo_map.py")"
  python "$py" "$(cygpath -w "$dir")" "$@"
}

cmd_worktree() {
  local repo="$1"; shift || true
  [ -d "$repo" ] || fail "目录不存在: $repo"
  local name="" mode="create" base="HEAD" yes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --list) mode="list";;
      --remove) mode="remove";;
      --base) shift; base="${1:-HEAD}";;
      --yes) yes=1;;
      -*) fail "未知参数: $1";;
      *) name="$1";;
    esac
    shift || true
  done

  if [ "$mode" = "list" ]; then
    ( cd "$repo" && git worktree list ) || fail "不是 git 仓库: $repo"
    return 0
  fi
  [ -n "$name" ] || fail "用法: wfctl.sh worktree <repo> <name> [--base <ref>] | <repo> --list | <repo> <name> --remove [--yes]"
  local wt="$repo/.worktrees/$name" br="wt/$name"

  if [ "$mode" = "remove" ]; then
    if [ -z "$yes" ]; then
      warn "将执行以下**破坏性**操作（未执行；确认后加 --yes）："
      warn "  1) 先摘掉工作树里的目录联接（node_modules 等）——`cmd /c rmdir` 只删链接，不碰真实依赖"
      warn "  2) git worktree remove --force $wt   # 丢弃该工作树内未提交改动"
      warn "  3) git branch -D $br                   # 丢弃该分支（若未合并）"
      log "确认请重跑：wfctl.sh worktree $repo $name --remove --yes"
      return 1
    fi
    # ⚠️ 实测(2026-10-08)：工作树里若有目录联接，直接 rm/git remove 可能**穿过联接删掉真实依赖**。
    #    先摘链接：`cmd /c rmdir` 对联接只删链接，对非空真实目录会拒绝执行 —— 天然安全。
    for j in node_modules .next .venv venv; do
      if [ -e "$wt/$j" ]; then
        if cmd /c rmdir "$(cygpath -w "$wt/$j" 2>/dev/null || echo "$wt/$j")" >/dev/null 2>&1; then
          log "已摘除目录联接: $j（真实依赖未被触碰）"
        fi
      fi
    done
    ( cd "$repo" && git worktree remove --force "$wt" ) && log "已移除工作树: $wt" || warn "工作树移除失败（可能已被删）"
    ( cd "$repo" && git branch -D "$br" ) >/dev/null 2>&1 && log "已删除分支: $br" || true
    ( cd "$repo" && git worktree prune ) >/dev/null 2>&1 || true
    return 0
  fi

  # create：先检测是否已在链式工作树里（官方 Step 0；子模块不算）
  local gd gc
  gd="$(cd "$repo" && git rev-parse --git-dir 2>/dev/null)" || fail "不是 git 仓库: $repo"
  gc="$(cd "$repo" && git rev-parse --git-common-dir 2>/dev/null)"
  if [ "$gd" != "$gc" ]; then
    warn "当前目录已是链式工作树（git-dir ≠ common-dir）——不重复创建"
    ( cd "$repo" && git worktree list )
    return 0
  fi
  [ -e "$wt" ] && fail "工作树已存在: $wt（清理：wfctl.sh worktree $repo $name --remove --yes）"
  mkdir -p "$repo/.worktrees"
  # 忽略 .worktrees：走本地私有 .git/info/exclude（不污染受版本控制的 .gitignore）
  local excl="$repo/.git/info/exclude"
  if [ -f "$excl" ]; then
    grep -qxF '.worktrees/' "$excl" || printf '\n.worktrees/\n' >> "$excl"
  fi
  ( cd "$repo" && git check-ignore -q .worktrees ) \
    || warn ".worktrees 未被忽略（.gitignore 里可能有例外规则）——提交前必须确认，否则会把工作树内容提交进仓库"
  ( cd "$repo" && git worktree add "$wt" -b "$br" "$base" ) || fail "git worktree add 失败（沙箱/权限？）"
  log "工作树就绪: $wt（分支 $br，基线 $base）"
  if [ -f "$repo/package.json" ] && [ -d "$repo/node_modules" ] && [ ! -e "$wt/node_modules" ]; then
    log "提示：Node 依赖不共享。推荐目录联接（秒级、不占额外空间）："
    log "  powershell -NoProfile -Command \"New-Item -ItemType Junction -Path '$(cygpath -w "$wt" 2>/dev/null || echo "$wt")\\node_modules' -Target '$(cygpath -w "$repo" 2>/dev/null || echo "$repo")\\node_modules'\""
    log "  ⚠️ 别用 `cmd //c mklink /J`：本机 MSYS 会把 //c 弄坏（实测：只弹 cmd 横幅、啥也不做）"
    log "  ⚠️ 删工作树前必须先摘联接（wfctl worktree ... --remove 已自动处理）"
  fi
  log "下一步：wfctl map $wt --write ｜ wfctl harness $wt（先验基线）｜ wfctl deleg $wt .agents/tasks/<slug>/brief.md"
}

cmd_baseline() {
  local py; py="$(cygpath -w "$SKILL_ROOT/scripts/run_ledger.py" 2>/dev/null || echo "$SKILL_ROOT/scripts/run_ledger.py")"
  python "$py" report "$@"
}

# 自动记账：任何命令结束（含 fail 退出）都落一条到时程基线账本；记账失败绝不影响主流程。
_ledger_flush() {
  local rc=$?
  # CR3：任何退出路径（正常/失败/信号）都要释放单票锁（陈旧锁会在下次自动接管）
  if [ -n "${DELEG_LOCK:-}" ] && [ -f "$DELEG_LOCK" ]; then
    if [ "$(cat "$DELEG_LOCK" 2>/dev/null || true)" = "$$" ]; then rm -f "$DELEG_LOCK" 2>/dev/null || true; fi
  fi
  case "${LEDGER_CMD:-}" in help|-h|--help|usage|baseline|"") return 0;; esac
  local py; py="$(cygpath -w "$SKILL_ROOT/scripts/run_ledger.py" 2>/dev/null || echo "$SKILL_ROOT/scripts/run_ledger.py")"
  local -a a=(append --cmd "$LEDGER_CMD" --dir "${LEDGER_DIR:-}" --rc "$rc" --dur "$(( $(date +%s) - ${LEDGER_T0:-$(date +%s)} ))" --source "${WFCTL_LEDGER_SOURCE:-live}")
  [ -n "${LEDGER_AGENT:-}" ] && a+=(--agent "$LEDGER_AGENT")
  [ -n "${LEDGER_NOTE:-}" ] && a+=(--note "$LEDGER_NOTE")
  [ -n "${LEDGER_OUT_BYTES:-}" ] && a+=(--out-bytes "$LEDGER_OUT_BYTES")
  [ -n "${LEDGER_SESSION:-}" ] && a+=(--session "$LEDGER_SESSION")
  if [ -n "${LEDGER_EXTRA:-}" ]; then read -ra _x <<< "$LEDGER_EXTRA"; a+=("${_x[@]}"); fi
  [ -n "${WF_TEST:-}" ] && a+=(--test)          # 管道/冒烟测试的票，不计入真实基线
  [ -n "${WF_EXP:-}" ] && a+=(--kind exp)       # 对照实验的票，单独看
  python "$py" "${a[@]}" >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------- main
[ $# -lt 1 ] && { usage; exit 0; }
LEDGER_CMD="$1"; LEDGER_DIR="${2:-}"; LEDGER_AGENT=""; LEDGER_NOTE=""; LEDGER_OUT_BYTES=""; LEDGER_EXTRA=""; LEDGER_SESSION=""
if [ "$1" = "deleg" ]; then              # 只有 deleg 的第 4 参可能是执行端；也可能是新 flag
  case "${4:-}" in -*) ;; *) LEDGER_AGENT="${4:-}";; esac
fi
# 代理桥接（实测 2026-10-09）：Pi/curl 默认会走 Windows 系统代理（Clash），该路径失效时 Pi 报 “Connection error.”
# 而 node/curl 直连正常 ⇒ 用 PI_PROXY 指到活着的端口，或 PI_NO_PROXY=1 显式绕过。对全部子命令生效（含 preflight 冲烟）。
if [ -n "${PI_PROXY:-}" ]; then export HTTPS_PROXY="$PI_PROXY" HTTP_PROXY="$PI_PROXY"; fi
if [ -n "${PI_NO_PROXY:-}" ]; then export NO_PROXY='*' no_proxy='*'; fi
# 凭据自动加载：先于任何子命令（deleg/preflight/envcheck 都吃这个 export）
_load_env_key || true
LEDGER_T0=$(date +%s)
trap _ledger_flush EXIT
case "$1" in
  setup)     [ $# -ge 3 ] && cmd_setup "$2" "$3" || cmd_setup "$2" "both";;
  verify)    cmd_verify "${2:-.}" "${3:-}";;
  verify-setup) [ $# -ge 3 ] && cmd_verify_setup "$2" "$3" || cmd_verify_setup "${2:-.}" "";;
  audit)     [ $# -ge 3 ] && cmd_audit "$2" "$3" || cmd_audit "$2";;
  handoff)   [ $# -ge 3 ] && cmd_handoff "$2" "$3" || fail "用法: wfctl.sh handoff <dir> <msg>";;
  rollback)  [ $# -ge 3 ] && cmd_rollback "$2" "$3" || fail "用法: wfctl.sh rollback <dir> <ref>";;
  deleg)     [ $# -ge 3 ] && cmd_deleg "${@:2}" || fail "用法: wfctl.sh deleg <dir> <promptfile> [pi|opencode] [--stall-timeout N]";;
  converge)  if [ $# -ge 2 ]; then cmd_converge "$2" "${3:-SPEC.md}" "${4:-}"; else fail "用法: wfctl.sh converge <dir> [specfile] [--strict|--init]"; fi;;
  task)      if [ $# -ge 3 ]; then cmd_task "$2" "$3" "${4:-<一句话目标>}"; else fail "用法: wfctl.sh task <dir> <slug> \"<一句话目标>\""; fi;;
  lookup)    cmd_lookup "${@:2}";;
  preflight) cmd_preflight "${2:-.}";;
  harness)   if [ $# -ge 2 ]; then cmd_harness "$2" "${3:-}"; else fail "用法: wfctl.sh harness <dir> [--init]"; fi;;
  envcheck)  cmd_envcheck;;
  baseline)  shift; cmd_baseline "$@";;
  map)       if [ $# -ge 2 ]; then cmd_map "$2" "${@:3}"; else fail "用法: wfctl.sh map <dir> [--write|--out <path>]"; fi;;
  diffcov)   if [ $# -ge 2 ]; then cmd_diffcov "${@:2}"; else cmd_diffcov "."; fi;;
  testbaseline) cmd_testbaseline "${2:-.}" "${3:-}";;
  stats)     python "$(cygpath -w "$HC_SCRIPTS/ledger_stats.py" 2>/dev/null || echo "$HC_SCRIPTS/ledger_stats.py")" "${@:2}";;
  worktree|wt) if [ $# -ge 2 ]; then cmd_worktree "$2" "${@:3}"; else fail "用法: wfctl.sh worktree <repo> <name> | --list | <name> --remove [--yes]"; fi;;
  help|-h|--help) usage;;
  *) fail "未知命令: $1 (见 help)";;
esac
