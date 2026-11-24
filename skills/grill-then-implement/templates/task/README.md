# 任务骨架（一次生成 SPEC / 任务书 / 收敛报告）

> 出处：2026-10-08 情侣网站 `/api/setup` 加固那一轮跑通后固化。

## 一条命令

```bash
wfctl map <dir> --write                               # 仓库地图 → AGENTS.md（地图写好再写任务书，任务书变薄）
wfctl task <dir> <slug> "<一句话目标>"
wfctl lookup <dir> "<问题一句话>" --error "<报错原文>" --slug <slug>   # 阶段 0：先查现成答案是唯一的真源
```

生成：

```
<dir>/.agents/tasks/<slug>/SPEC.md      验收判据（CR1..）+ 边界
<dir>/.agents/tasks/<slug>/brief.md     五段式任务书（委托用）
<dir>/.agents/tasks/<slug>/lookup.md    阶段 0 检索记录（三组查询 + 论据 + 结论；不填 ⇒ deleg 拒）
```

判据填完再委托：

```bash
wfctl preflight <dir>                                  # 凭据/包身份/仓库状态
wfctl lookup <dir> --slug <slug> --check               # 可选：单独核检索记录（缺 ⇒ rc=1）
wfctl deleg <dir> .agents/tasks/<slug>/brief.md        # 单会话委托（执行端产出 assess/fix/test）
# —— Hermes 独立验收：跑 harness/verify_*.py + tsc + 反例，不采信自述 ——
wfctl converge <dir> .agents/tasks/<slug>/SPEC.md --init   # 生成 .agents/converge-<日期>.md 骨架（自动带 CR 清单）
# 填完三向表与判定后：
wfctl converge <dir> .agents/tasks/<slug>/SPEC.md --strict # rc=0 收敛 / 2 报告不全 / 3 未收敛

wfctl baseline --cmd deleg                            # 时程基线：单票耗时/白跑率/连续成功（每条命令自动记账）
```

## 约定

- 执行端产出固定落 `.agents/tasks/<slug>/{assess.md, fix.md, test.md}`；
- 收敛报告固定落 `.agents/converge-<日期>.md`（`--init` 生成骨架，判据清单自动带入）；
- **判定必须单独成行显式写**（`Converged` / `未收敛`）——门禁先认这一行，避免正文短语被误读；
- 新增风险要**固化成 harness 判据**（`harness/verify_*.py`），并在沙箱植入反例证明它会 FAIL。

## 为什么长这样（三条来自实测）

1. **判据先行**：没有 CR 清单就没法判定"做完了没有"；写判据比写代码更接近验收本身。
2. **证据留痕**：任务书第 3/4 步强制"命令 + 输出原文"和"反例证明"，把"应该没问题"挡在门外。
3. **独立复核**：验收由 Hermes 亲自跑（含亲跑执行端写的测试），执行端自述不作为结论。
