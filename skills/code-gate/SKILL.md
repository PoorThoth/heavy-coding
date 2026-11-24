---
name: code-gate
description: "Use when 改代码/修bug/交付:先定轻或重模式，只认退出码证据。"
version: 1.0.2
author: Heavy Coding
license: MIT
triggers:
  - 改代码
  - 写代码
  - 修bug
  - 提交
  - 重构
  - 交付代码
metadata:
  heavy-coding:
    tags: [workflow, gate, exit-code, delegation]
    related: [grill-then-implement, docs/GATES.md]
---

# 代码改动入口（runbook）· 30 秒定模式 → 给退出码；完整门禁见 docs/GATES.md

## When to Use

改仓库文件 / 加功能 / 修 bug / 批量改数据 / 交付代码 —— 任何一次改动之前。定模式不许跳过。

## 第 0 步：定模式

| 条件（全满足） | 模式 |
|---|---|
| 单文件或单模块 · 不动库表 · 不动钱 · 不部署 · 一票跑完 | **轻** |
| 跨 ≥3 模块 / 动数据库 / 动钱 / 动生产 / 一票跑不完 | **重** |

说不清 → 按重走。回复里先写一行「模式：轻/重」，用户能当场打断。

**改门禁/检查器/模板本身 ⇒ 一律按重走**（它影响后续每一票，不是「只改一行」）；这类改动不能用自己的门禁自证，必须去沙盒用红证据双向验证（红→修→红转绿），并给「注入 → 实际 rc」对照表。

## 轻模式

```bash
cd <repo> && git status --porcelain          # ① 基线：干净才动手
<改代码>                                      # ② 一次只做一件事
go test ./... -count=1 > /tmp/t.log 2>&1; echo RC=$?   # ③ 测试（Python 用 pytest -q、Node 用 npm test，别串管道）
git add -A && git commit -m "<改了什么，为什么>"
```

- **测试绿 ≠ 接线通**：回读目标行（`文件:行`）确认调用方真调到；rc 要直给（`cmd > log 2>&1; echo $?`，别用 `| tail` 取管道末端 rc）。

## 重模式（7 条命令）· 双轨 = 规格轴 `converge --strict` ∥ 标准轴 独立 reviewer（只跑一条不算双轨）

```bash
WF=$HC_HOME/skills/software-development/grill-then-implement/scripts/wfctl.sh
bash $WF preflight <repo>                     # ① 执行端就绪（执行器 / key / 仓库干净）
bash $WF task <repo> <slug> "<目标>"           # ② 生成 .agents/tasks/<slug>/{SPEC.md,brief.md}
# ③ 写 SPEC：每条判据 `- **CRn**` + **`[test: 文件::用例]`**（converge 会真跑那一条，缺指针 rc=2；纯文档写 `[test: n/a: ≥8字理由]`）；write brief：五段式 + `实测事实:` + `expect:`
bash $WF lookup <repo> "<问题>" --slug <slug>  # ④ 检索记录（缺则委托被拒）
bash $WF deleg <repo> .agents/tasks/<slug>/brief.md   # ⑤ 委托，看 rc
bash $WF converge <repo> .agents/tasks/<slug>/SPEC.md --strict   # ⑥ 收敛
bash $WF verify <repo>    # ⑦ 收口：测试(Go/pytest/npm) + **改动行覆盖** + converge + 账本
bash $WF diffcov <repo> · stats --since <日期>   # 改动行覆盖（默认 100%，测不了 SKIP rc=4）· 账本派生指标
```

**真项目首票先做两件事**：`bash $WF testbaseline <repo> "pytest -q"` 钉**既有红基线**（之后只对新增失败发红，报告写“rc=1，均为既有红 N 条”）；`export WF_DIFFCOV_PATHS=<本票文件>` 只测本票改动（`git diff HEAD` 会把别人未提交的 WIP 算进来，覆盖率被稀释成噪音）。判据与语言坑（Go 模块路径 / Python 解释器与 settrace 性能 / 豁免清单）见 `docs/BASELINE.md`。

| rc | 含义 | 处置 |
|---|---|---|
| 0 | 完成且收敛 | 才能说“做完了” |
| 3 | 预期产物缺失 | 查落点，先看现场再重跑 |
| 4 | 同目录并发第二票 | 等锁或删陈旧锁 |
| 5 | 任务书缺行首 `实测事实:` | 补实测行 |
| 6 / 7 / 124 | stop_reason 异常 / 无 `agent_settled` / 停滞看门狗 | 读错误定级；`--continue` 续；产物可能半写，先看现场 |
| converge 2 / 3 | 报告缺失 / 未收敛 / **CR 的测试证据不成立** | 补 `文件:行` 与 `[test: 文件::用例]`，不改测试迁就实现 |
| diffcov 5 | 改动的行没被执行过 | 补测到那几行；纯声明/错误分支要么测要么拆 |

## 两个静默失效前置

1. **`DEEPSEEK_API_KEY` 缺失** ⇒ 执行器报 No API key 却 `rc=0` 白跑。wfctl 会自动从 `$HC_HOME/.env` 加载（`WF_ENV_FILE=` 可改；只报长度）；仍失败就跑 `wfctl envcheck` 看来源。
2. **仓库无 `.agents`** ⇒ 先 `wfctl task` 建骨架；**CRLF 仓库 gofmt 恒假红** ⇒ 只认归一化差异（`wfctl verify` 已处理，别手改换行）。

**收尾必报三件**：模式（轻/重） · 验证命令与真实 rc · 归档路径。
