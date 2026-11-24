# Heavy Coding（中文说明）

**给 AI 执行器上十四道闸的代码工作流——每道闸只认退出码，不认自述。**

[English README](README.md) · 门禁清单：[docs/GATES.md](docs/GATES.md) · 红基线流程：[docs/BASELINE.md](docs/BASELINE.md)

## 一句话

AI 执行器说"做完了、测试全绿、已修复"，而仓库里根本不是这么回事。这套东西把一次委托包进十四道检查点，每道只能被一个机器可验的事实放行：真跑过的那条用例、被执行过的那行 diff、与规格收敛的那份报告。

纯 Bash + Python，无框架、无服务、无厂商 SDK。

## 装

```bash
git clone https://github.com/<you>/heavy-coding.git
cd heavy-coding && ./install.sh
export HC_HOME="$HOME/AppData/Local/hermes"   # 或 ~/.hermes
export HC_SCRIPTS="$HC_HOME/scripts"
bash $HC_HOME/skills/software-development/grill-then-implement/scripts/wfctl.sh envcheck
```

只有 `deleg`（委托那一步）需要 `DEEPSEEK_API_KEY`，写进 `$HC_HOME/.env`；其余门禁全部离线可用。

## 五条命令跑一票

```bash
WF=$HC_HOME/skills/software-development/grill-then-implement/scripts/wfctl.sh
bash $WF task . my-ticket "给 fetch_user 加一次重试"          # ① 生成 SPEC + brief
$EDITOR .agents/tasks/my-ticket/SPEC.md                      # ② 每条 CR 带 [test: 文件::用例]
bash $WF lookup . "有没有现成做法" --slug my-ticket --search   # ③ 先查现成，记录留档
bash $WF deleg . .agents/tasks/my-ticket/brief.md            # ④ 委托，读 rc
bash $WF converge . .agents/tasks/my-ticket/SPEC.md --strict  # ⑤ 报告与代码是否真一致
bash $WF verify .                                            # ⑥ 测试 + 改动行覆盖 + 收敛 + 账本
```

真项目第一票之前多做两步：

```bash
bash $WF testbaseline . "pytest -q"                        # 钉既有红基线，之后只报新增失败
export WF_DIFFCOV_PATHS=src/mod.py,tests/test_mod.py       # 只测本票动过的文件
```

## 十四道闸（一句话版）

| # | 闸 | 它不信什么 |
|---|---|---|
| 1 | `envcheck` | 不信执行器有凭据（缺 key 时它会 rc=0 白跑） |
| 2 | `lookup` | 不信这活是从零开始的（先查现成） |
| 3 | `task` | 不信"没有 SPEC 也能委托" |
| 4 | brief lint | 不信任务描述是完整的（五段式 + 实测事实 + expect） |
| 5 | `worktree` | 不信两票能共用一个工作区 |
| 6 | 停滞看门狗 | 不信"还在思考"是进展 |
| 7 | `dispatch_verify` | 不信执行器没动它不该动的东西 |
| 8 | `converge --strict` | 不信收敛报告自己的说法 |
| 9 | CR 测试指针 | 不信"整套测试绿了所以这条覆盖了" |
| 10 | 测试 + 既有红基线 | 不信红灯都是本票造成的（也不信绿灯真跑过测试） |
| 11 | 改动行覆盖 | 不信"测试跑过了"等于"你改的行跑过了" |
| 12 | 换行归一 | 不信 CRLF 噪音是格式问题 |
| 13 | 运行账本 | 不信一票结束了（rc / 成本 / `agent_settled`） |
| 14 | `gate_watch` | 不信这套流程还有人用 |

## 五条设计原则

1. **自述不算数**：执行器的输出只有在某条命令对某个机器可验的产物返回 rc=0 时才算证据。
2. **红基线是数据，不是失败**：真项目开工就是红的。先记录，再只对**新增**失败发红；否则门禁变成噪音，一周内就没人看。
3. **豁免必须显式、进版本库**：测不了的文件写进 `.diffcovignore` 并写理由——在 diff 里看得见。绝不偷偷降阈值。
4. **改门禁必须在沙盒里验证**：改检查器不能用它自己自证。注入一个已知失败，看它红；修好，看它绿。
5. **度量范围要圈到本票**：`git diff HEAD` 会带上别人未提交的 WIP，量出来的数字毫无意义。

## 许可

MIT © 2026 Ling Guiqian
