# 十四道门

[English](GATES.md) · **简体中文**

下面每一道门都返回一个退出码。这里没有一处要求你相信任何总结。

```
        ┌─ preflight ─┐   ┌─ scaffold ─┐   ┌─ lookup ─┐   ┌─ delegate ─┐
repo ──▶│ envcheck    │──▶│ task+lint  │──▶│  recorded │──▶│ worktree   │──▶ executor
        └─────────────┘   └────────────┘   └───────────┘   │ + watchdog │
                                                            └─────┬──────┘
                                                                  │ artifacts
        ┌─ accept ────────────────────────────────────────────────▼─────────┐
        │ dispatch_verify → converge --strict → verify(tests · patch-cov)   │
        └──────────────────────────┬────────────────────────────────────────┘
                                   ▼
                            ledger → stats → gate_watch
```

## 1. `wfctl envcheck` —— 执行器到底能不能跑？

缺 `DEEPSEEK_API_KEY` 时，执行器会打印 `No API key found for deepseek` 然后**退出 0**。这就是本仓库存在理由的原型。

```
rc=0  key 在（只打印 len=N，绝不打印值）
rc=1  key 缺失，并列出查过的每一个文件路径
```

顺带检查执行器二进制和仓库的 git 状态。

## 2. `wfctl lookup <repo> "<问题>" --slug <slug>` —— 这活是不是从零开始？

用一次真检索写出 `.agents/tasks/<slug>/lookup.md`（来源 + 别人怎么做 + 我们差在哪）。缺这份记录，`deleg` 直接拒绝执行——因为"agent 会自己想明白"就是重复造轮子的开端。

```
rc=0  记录在、§4 结论非空、没有 <占位符>
rc=1  缺失 / 占位 / 没有来源（逃生门：WF_NO_LOOKUP=1）
```

## 3. `wfctl task` —— 没有 SPEC 就没有票

生成 `.agents/tasks/<slug>/{SPEC.md,brief.md}`。SPEC 是一串 `**CR1**…**CRn**` 需求，每条都带一个可机验的验收判据和一个测试指针：

```markdown
- **CR1** merge_specs 从 specs 构造属性，字典值查询以回调注入。
  [test: tests/test_attrs.py::test_merge_plain_and_dict]
- **CR3** 发布脚本里的胶水代码（不可 import，没有测试挂点）。
  [test: n/a: 顶层脚本会调线上 API，已在 .diffcovignore 里显式豁免]
```

测不了的东西必须在 SPEC 里说清，理由至少 8 个字符。门禁接受豁免时**会把豁免打印出来**——豁免是可见的，不是静默的。

## 4. 任务书体检 —— 任务描述完整吗？

缺下列任一项，`deleg` 直接拒绝：五段式（事实 / 步骤 / 约束 / 交付物 / 自检）、`实测事实:` 行、`expect:`（必须产出的文件）。

```
rc=5  没有以 实测事实: 开头的行
```

要"实测事实"这一行的原因：一份全是假设的任务书，是 agent 最廉价产生幻觉的地方。"跑一下，把输出贴上来"成本只有一行。

## 5. `wfctl worktree` —— 一票一个工作区

同目录并发第二票：`rc=4`（锁文件）。隔离不是讲究，两个 agent 在一个工作区会互删改动。

## 6. 停滞看门狗

N 秒没有新事件 → `rc=124`，进程被杀、票被标记为停滞。一个挂死的执行器不能看起来像在运行。

## 7. `dispatch_verify.py` —— 执行器有没有越界？

重新哈希执行器声明的产物，与真值文件比对内容和数量，并检查关键字段。

```
rc=0  每个声明的产物都对得上
rc=2  产物被改 / 越出沙盒
rc=3  内容与真值不符（按 --key-field 比对）
rc=4  数量不符（--expect-count N）
rc=5  参数错误，或真值文件不存在
```

## 8. `converge --strict` —— 报告在描述代码吗？

六项检查，全部机械：

1. 这张票有收敛报告；
2. 报告里有终判行；
3. SPEC 里的每个 `CRn` 都被提到；
4. 至少一处 `path:line` 证据——是引用，不是转述；
5. 判为未收敛时，有带复现步骤的缺口清单；
6. **每条 CR 的测试指针真跑且通过**（见第 9 道）。

```
rc=0  已收敛
rc=2  报告缺失，或某条 CR 的测试证据不成立
rc=3  未收敛（应有缺口清单）
```

## 9. CR 测试指针 —— "整套绿了"不等于覆盖

每个 `[test: file::case]` 被查三次：文件在、用例名出现在文件里、**并且真的执行那一条**（`pytest file::case`、`go test -run Name`、`node --test`）。点名的用例跑不过，这条需求就是没覆盖——无论套件其余部分多绿。

`[test: n/a: 理由]` 是唯一的豁免，且会被打印。

## 10. 测试 + 既有红基线

按仓库实际情况跑：`WF_TEST_CMD` → pytest 迹象（`pytest.ini`、`pyproject.toml`、`setup.cfg`、`tox.ini`、`tests/test_*.py`）→ `package.json` 的 test 脚本 → `go test ./...`。

然后把失败集合与 `.agents/pytest-baseline.txt`（由 `wfctl testbaseline` 写出）比对。真实仓库在你接手时就是红的：数据漂移、长期存在的坏测试、别人的半成品。因为它们而失败会让门禁变成噪音，所以：

- 失败集合 ⊆ 基线 → **通过**，并打印条数；
- 出现基线之外的失败 → **失败**，且只列出新的那几条。

详见 [`BASELINE.zh-CN.md`](BASELINE.zh-CN.md)。

## 11. 改动行覆盖 —— 测试真的跑到你改的行了吗？

`diffcov.py` 取改动集合，筛出新增的可执行行（空行、注释、文档字符串排除——它们不产生 line 事件），跑测试，再看其中哪些行真被执行过。

```
rc=0  ≥ 阈值（默认 100%）被执行的
rc=4  无法测量（无 git、无改动、语言不支持）→ 报 SKIP，绝不当作通过
rc=5  低于阈值，并给出未覆盖的准确行号
```

Go 用 `go test -coverprofile`；Python 用 `covrunner.py`（`sys.settrace`，行级，零第三方依赖）；Node 目前是 SKIP。

范围很要紧：`git diff HEAD` 会看到**别人未提交的活儿**，所以用 `WF_DIFFCOV_PATHS=a.py,b.py` 圈定被测文件；完全测不了的放进 `.diffcovignore`，每条都带理由，在 diff 里可见。

## 12. 换行归一

在 CRLF 检出上跑 `gofmt -l`，会永远把每个文件都标出来。门禁在判定前归一化换行，并把"仅空白差异"单独报出，而不是假装是格式失败。

## 13. 运行账本

每条命令追加到 `$HC_LEDGER`（jsonl）：`cmd`、`dir`、`slug`、`rc`、`dur_s`、tokens、cost、`settled`、`stalled`、`missing`。一张没有写 `settled` 的票就是没结束——不管转写记录怎么说。

`wfctl stats` 派生出真正要紧的数字：票数、返工率、验收失败轮次、白跑率、单票成本。默认排除 test/exp 票，免得自己的冒烟测试把数字刷好看。

## 14. `gate_watch` —— 还有人用这套东西吗？

没人会注意到的那种失败：流程存在、文档很好，然后六周里每次改动都是手改。`gate_watch.py` 读账本与收敛报告；如果最近 N 天既没有委托票也没有新报告，它说一次（带冷却）。健康时输出为空、退出 0——适合放进 cron。

入口四件也一起查：AGENTS.md 锚点、runbook 技能、凭据自动加载、key 那一行本身。任何一件消失，立即报出。

## 退出码速查

| 工具 | 0 | 2 | 3 | 4 | 5 | 6/7/124 |
|---|---|---|---|---|---|---|
| `wfctl deleg` | 成功 | — | 预期产物缺失 | 并发锁 | 任务书缺 `实测事实:` | 异常 / 无 `agent_settled` / 停滞 |
| `wfctl converge` | 已收敛 | 报告缺失或 CR 测试证据不成立 | 未收敛 | — | — | — |
| `diffcov.py` | ≥阈值 | — | — | 无法测量（SKIP） | 低于阈值 | — |
| `dispatch_verify.py` | 全部一致 | 产物被改 / 越界 | 与真值不符 | 数量不符 | 参数错 / 真值缺失 | — |
| `ledger_stats.py` | 有数据 | — | 账本为空 | — | — | — |

## 环境变量

| 变量 | 默认 | 用途 |
|---|---|---|
| `HC_HOME` | `~/AppData/Local/hermes`，否则 `~/.hermes` | 技能、脚本、账本、`.env` 所在 |
| `HC_SCRIPTS` | `$HC_HOME/scripts` | 五个辅助工具 |
| `HC_LEDGER` | `$HC_HOME/run_ledger.jsonl` | 运行账本 |
| `HC_ENV_FILE` | `$HC_HOME/.env` | 凭据文件（`DEEPSEEK_API_KEY`） |
| `WF_TEST_CMD` | 自动探测 | 覆盖测试命令 |
| `WF_DIFFCOV` | `1` | 置 `0` 可跳过改动行覆盖 |
| `WF_DIFFCOV_PATHS` | 全部改动 | 只测本票文件 |
| `WF_DIFFCOV_MIN` | `1.0` | 覆盖率阈值 |
| `WF_NO_LOOKUP` | — | `1` 跳过第 2 道门（并会声明） |
| `HC_WATCH_REPOS` | 空 | `gate_watch` 要巡检的仓库，逗号分隔 |
