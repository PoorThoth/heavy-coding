# 变更日志

[English](CHANGELOG.md) · **简体中文**

## 1.0.0-beta.1 — 2026-11-25

首个公开测试版。这套工作流本身已在日常开发中使用数月，这一版是第一次按「别人的机器」来打包。

**门禁（14 道）**：预检、先查现成、建票与任务书体检、工作区隔离、停滞看门狗、产物完整性、收敛、逐条 CR 真跑测试、测试与既有红基线、改动行覆盖、换行归一、运行账本、使用巡检。发布前每一道都用注入失败实跑过，注入 → 实际 rc 的对照表在 [`docs/GATES.zh-CN.md`](docs/GATES.zh-CN.md)。

**工具**
- `wfctl`（Bash）：`task` · `lookup` · `deleg` · `converge` · `verify` · `diffcov` · `stats` · `testbaseline` · `preflight` · `envcheck`
- `converge_check.py` v2.0：六项机械判据，逐条 CR 真跑 `[test: 文件::用例]`，不读报告自述
- `diffcov.py` + `covrunner.py`：改动行覆盖（Go `-coverprofile` / Python `sys.settrace`，零依赖）；Node 报 SKIP，绝不当通过
- `dispatch_verify.py`：产物哈希对真值（`--expect-count`、`--key-field`）
- `ledger_stats.py`：票数、返工率、白跑率、单票成本
- `gate_watch.py`：健康时静默，流程被绕开时报警

**可移植**
- 路径全部走 `HC_HOME` / `HC_SCRIPTS` / `HC_LEDGER` / `HC_ENV_FILE`
- 仓库 LF 归一（`.gitattributes`）、MIT、`install.sh`
- 全仓双语：每份文档都有英文基础版 + `*.zh-CN.md`；`WF_TEMPLATE_LANG=en` 会让 `wfctl task` 生成英文 SPEC / brief / 收敛报告

**已知限制**
- 主测 Windows + Git-Bash（MSYS）；Linux/macOS 预期可用但未实机验证
- Node / TypeScript 的改动行覆盖尚未测量（报 SKIP）
- 多 agent 协调未实现
- beta 期间命令名、参数名与退出码仍可能变化
