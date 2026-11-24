# 验收清单（DoD — Definition of Done）

> 每个任务完成声明前，逐项检查。全部 ✅ 才算完成。

## A. 环境检查（开始前 30 秒）

- [ ] `pip show <pkg> | grep -E "Editable"` 无污染（或确认 PYTHONPATH=src 运行）
- [ ] 项目目录干净：无 pyc/egg-info 入库，.gitignore 正确
- [ ] git 状态清晰：当前分支正确，有可回退点

## B. 测试验证（信任但验证）

- [ ] Hermes **亲自**跑测试命令，全部通过（不信 agent 自报——实测 agent 自报 81/81 实际 2 failed）
- [ ] 原有测试零回归
- [ ] 测试输出无隐藏错误（No tests collected / ImportError / 跳过）

## C. 功能完整性（防"测试和实现一起漏"）

- [ ] spec 每个需求点 → 代码/输出逐项核验
- [ ] 新功能的输出字段/接口与需求一致（实测变体 B 漏 by_symbol/by_direction 但测试全过）
- [ ] 边界条件有测试（空输入/零值/异常输入）

## D. 真实运行

- [ ] CLI/API 实际执行成功（非仅单测）
- [ ] 关键路径输出正确（抽查一个真实输入的结果）

## E. 提交审计

- [ ] `git log --oneline | wc -l` 符合预期（TDD 应有多个 commit；1 个 commit = 流程被绕过）
- [ ] 有 `fix:` commit（如代码审查发现问题）或审查确认无问题
- [ ] 无未提交文件（`git status` 干净，除 .agents 等忽略项）
- [ ] commit message 清晰描述改动

## F. 文档匹配

- [ ] README/HANDOFF（如有）与实际实现一致
- [ ] 交接场景：HANDOFF.md 的"已完成/未完成"与实际相符

---

## 失败恢复参考（测试/实现失败时）

| 级别 | 触发 | 动作 |
|------|------|------|
| L1 | 环境问题（editable/RTK/依赖） | 修环境 → 同 prompt 重跑 |
| L2 | 任务漂移/实现失败 | 诊断根因 → 修正 prompt（加"不是 XXX"否定词）→ 全新会话重跑 |
| L3 | 反复失败（2+轮） | 拆小任务 → 分模块实现 → 每模块验证 |
| L4 | 彻底失败 | git reset 到绿 commit → 换方案 |
| L5 | 3+次失败 | 停止自动流程 → 报告用户 → 用户决策 |

**关键原则：2+ 次失败后禁止盲目重试，必须停下来诊断。**
