---
name: grill-then-implement
description: "重模式全链参考:质询→SPEC→委托→收敛→验收，每道门的判据与坑。"
version: 2.0.0
author: Heavy Coding
license: MIT
metadata:
  heavy-coding:
    tags: [workflow, delegation, spec, converge]
---

# grill-then-implement —— 重模式全链参考

> 日常只需要 `skills/code-gate/SKILL.md`（80 行 runbook）。这个文件回答「为什么这么设计、某道门到底卡什么」。
> 所有门的机器判据在 [`docs/GATES.md`](../../docs/GATES.md)，红基线流程在 [`docs/BASELINE.md`](../../docs/BASELINE.md)。

## 一、这一套解决什么

委托给 AI 执行器的真实代码改动，有四种"看起来成功"的静默失效：凭据缺失却 rc=0、测试压根没被收集、测试全绿但新代码不被调用、收敛报告里的 `文件:行` 根本不存在。四种都不能靠读执行器的自述发现，只能靠一个会**大声失败**的检查点。

因此每一道门都必须满足三件事：

1. 有自己的**退出码**，且非零有意义（`0` 只能由"机验事实成立"给出）；
2. 有**可复现的注入方式**——你知道怎么把它弄红，才知道它没坏；
3. 失败信息直接给**位置**（`文件:行`、`用例名`、`未覆盖行号`），而不是"请检查"。

## 二、链的形状

```
preflight → task(SPEC+brief) → lookup → deleg → converge → verify → ledger/stats
                                        ↘ dispatch_verify（产物完整性）
```

| 阶段 | 命令 | 卡什么 | 非零含义 |
|---|---|---|---|
| 0 就绪 | `wfctl preflight` | 执行器在不在、key 在不在、仓库脏不脏 | 1 = 缺前置 |
| 1 任务 | `wfctl task` | 没有 SPEC 就没有票 | — |
| 2 检索 | `wfctl lookup` | 先查现成，拒绝重复造轮子 | 1 = 缺记录 |
| 3 委托 | `wfctl deleg` | brief 缺 `实测事实:` / `expect:` | 5 = 缺实测行；3 = 预期产物没落地；4 = 并发锁；7 = 没 settle；124 = 停滞 |
| 4 产物 | `dispatch_verify.py` | 产物被改、越界、数量或真值不符 | 2/3/4/5 |
| 5 收敛 | `wfctl converge --strict` | 报告与 SPEC、代码、测试三向是否一致 | 2 = 报告/测试证据不成立；3 = 未收敛 |
| 6 验收 | `wfctl verify` | 测试（含既有红基线）+ 改动行覆盖 + 收敛 + 账本 | 任一项非零 |
| 7 观测 | `wfctl stats` / `gate_watch.py` | 返工率、白跑率、以及"流程是不是又没人用了" | 3 = 账本空 |

## 三、SPEC 怎么写才卡得住

- 一条 CR 一件事，判据写"能被命令证伪"的形态（`rc=0`、`文件:行` 出现、某函数返回某值），不写"代码质量良好"。
- 每条 CR 带 `[test: 文件::用例]`。收敛门禁会真跑那一条——不是读报告，是执行。
- 真的测不了（脚本顶层就调线上 API、codegen 产物）写 `[test: n/a: ≥8 字理由]`，并把文件列进 `.diffcovignore`。豁免会被打印出来。
- **边界要写死**：允许动哪些文件、禁止跑什么（真 API、真库、push）、仓库里已有的未提交改动一律不碰。

## 四、brief 怎么写才不幻觉

五段式：① 任务一句话 ② 现成答案检索结论 ③ 事实与资料（**已经侦察好的，不让执行器重新探索**）④ 步骤（assess / fix / test / 收口）⑤ 硬性约束。

外加两行机器读的：

- `实测事实: <今天真的跑过什么、输出是什么>` —— 没有这行 `deleg` 直接 rc=5；
- `expect: <必须产出的文件>` —— 缺了 `deleg` 报 rc=3。

一段"事实与资料"能省掉执行器一半的瞎逛；一段"硬性约束"能省掉一次事故。

## 五、验收阶段的三条硬规矩

1. **不信自述**：执行器说"测试通过"不算，宿主自己跑一遍，贴 rc。
2. **红基线先钉**：真项目开工就是红的（数据漂移、历史待修）。先 `testbaseline` 记录，之后只对**新增**失败发红。红基线文件是普通文本，进 diff 可复查。
3. **测度量要圈定范围**：`git diff HEAD` 会把别人未提交的 WIP 算成这一票的改动，覆盖率瞬间变成噪音。用 `WF_DIFFCOV_PATHS` 只测本票文件；真的测不了的用 `.diffcovignore` 显式豁免，**绝不偷偷降阈值**。

## 六、常见坑（都踩过）

| 坑 | 现象 | 修法 |
|---|---|---|
| 凭据静默缺失 | 执行器 rc=0、无输出 | `wfctl envcheck`；wfctl 自动从 `$HC_HOME/.env` 加载并只报长度 |
| 测试命令假红 | 本机 `python` 没有 pytest | 用 PATH 上能跑的 `pytest -q`，别硬编码 `python -m pytest` |
| 同日报告互相覆盖 | 一票把另一票的证据表冲掉 | 报告按 `<slug>-<date>` 命名，`--init` 永不回写已有报告 |
| 指针归属错 | 理由里提了"已被 CR1 覆盖"，指针算到 CR1 | 指针只归本行第一条 CR |
| 占位没填 | `<tests/x.py>::<case>` 骗过检查 | 检出 `<` 即判"占位没填" |
| 无 `internal/` 的 Go 仓跳过测试 | verify 假绿 | `go test ./...` |
| settrace 太慢 | 全套 300 例 6 分钟 | 按 code object 缓存归属文件 → 60 秒 |
| 文档字符串算未覆盖 | 改一句注释覆盖率归零 | `ast` 排除 docstring 行 |
| 空描述仍发注解属性 | 发了条空的 4191 | 空描述不发，由"补描述"解决 |

## 七、成本

一票真实改动（两个文件 + 5 条用例）在 DeepSeek 上约 **$0.013**、6–11 分钟、39k in / 26k out。门禁本身零 token（纯脚本），`gate_watch` 也零 token。真正花钱的只有 `deleg` 那一次。
