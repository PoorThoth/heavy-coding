# Changelog

English · [简体中文](CHANGELOG.zh-CN.md)

## 1.0.0-beta.1 — 2026-11-25

First public beta. The workflow itself has been in daily use for months; this is the
first release shaped for someone else's machine.

**Gates**
- 14 checkpoints: preflight, prior-art lookup, ticket + brief lint, worktree isolation,
  stall watchdog, artifact integrity, convergence, per-CR test execution, tests with a
  known-red baseline, patch coverage, line-ending normalization, run ledger, usage watchdog.
- Every gate was exercised with an injected failure before release; the "injected failure →
  actual rc" matrix is in `docs/GATES.md`.

**Tooling**
- `wfctl` (Bash): `task` · `lookup` · `deleg` · `converge` · `verify` · `diffcov` · `stats` ·
  `testbaseline` · `preflight` · `envcheck`.
- `converge_check.py` v2.0: six mechanical criteria; runs each CR's `[test: file::case]` rather
  than reading the report.
- `diffcov.py` + `covrunner.py`: patch coverage for Go (`-coverprofile`) and Python
  (`sys.settrace`, zero dependencies). Node reports SKIP and never passes.
- `dispatch_verify.py`: artifact hashes against a truth file (`--expect-count`, `--key-field`).
- `ledger_stats.py`: tickets, rework rate, wasted runs, cost per ticket.
- `gate_watch.py`: silent when healthy; alerts when the workflow is bypassed.

**Portability**
- All paths resolve through `HC_HOME` / `HC_SCRIPTS` / `HC_LEDGER` / `HC_ENV_FILE`.
- LF-normalized repo (`.gitattributes`); MIT license; `install.sh`.
- Bilingual throughout: every document has an English base and a `*.zh-CN.md` twin, and
  `WF_TEMPLATE_LANG=en` makes `wfctl task` scaffold English SPEC / brief / convergence reports.

**Known limits**
- Tested primarily on Windows + Git-Bash (MSYS). Linux and macOS are expected to work but are
  not verified on real hardware yet.
- Node/TypeScript patch coverage is not measured (reported as SKIP).
- Multi-agent coordination is not implemented.
- Command names, flag names and rc codes may still change during the beta.

---

## 1.0.0-beta.1 — 2026-11-25（中文）

首个公开测试版。这套工作流本身已在日常开发中使用数月，这一版是第一次按「别人的机器」来打包。

**门禁**：14 个检查点（预检、先查现成、建票与任务书体检、工作区隔离、停滞看门狗、产物完整性、收敛、逐条 CR 真跑测试、测试与既有红基线、改动行覆盖、换行归一、运行账本、使用巡检）。发布前每一道都用注入失败实跑过，对照表在 `docs/GATES.md`。

**工具**：`wfctl`（task/lookup/deleg/converge/verify/diffcov/stats/testbaseline/preflight/envcheck）、`converge_check.py` v2.0、`diffcov.py` + `covrunner.py`、`dispatch_verify.py`、`ledger_stats.py`、`gate_watch.py`。

**可移植**：所有路径走 `HC_*` 环境变量；仓库 LF 归一；MIT；`install.sh`；全仓双语，且 `WF_TEMPLATE_LANG=en` 会让 `wfctl task` 生成英文 SPEC/brief/收敛报告。

**已知限制**：主测 Windows + Git-Bash，Linux/macOS 未实机验证；Node 改动行覆盖尚未测量（报 SKIP）；多 agent 协调未实现；beta 期间命令名、参数名与退出码仍可能变。
