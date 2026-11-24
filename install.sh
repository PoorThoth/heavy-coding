#!/usr/bin/env bash
# install.sh —— 把 Heavy Coding 装进 HC_HOME（默认 ~/AppData/Local/hermes，其次 ~/.hermes）
#   ./install.sh              安装技能 + 脚本
#   HC_HOME=/opt/hc ./install.sh
set -eu
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HC_HOME="${HC_HOME:-$HOME/AppData/Local/hermes}"
[ -d "$HC_HOME" ] || HC_HOME="$HOME/.hermes"

echo "目标 HC_HOME=$HC_HOME"
mkdir -p "$HC_HOME/skills/software-development" "$HC_HOME/scripts"
cp -r "$SRC/skills/code-gate" "$HC_HOME/skills/software-development/"
cp -r "$SRC/skills/grill-then-implement" "$HC_HOME/skills/software-development/"
cp -r "$SRC/skills/subagent-dispatch" "$HC_HOME/skills/software-development/" 2>/dev/null || true
cp "$SRC"/scripts/*.py "$HC_HOME/scripts/"

cat <<EOF

装好了。把下面三行加进你的 shell 配置（或每次会话前 export）：

  export HC_HOME="$HC_HOME"
  export HC_SCRIPTS="\$HC_HOME/scripts"
  export HC_LEDGER="\$HC_HOME/run_ledger.jsonl"

凭据（可选，只有 deleg 需要）：把 DEEPSEEK_API_KEY=... 写进 $HC_HOME/.env
自检：  bash $HC_HOME/skills/software-development/grill-then-implement/scripts/wfctl.sh envcheck
EOF
