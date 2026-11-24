# 红基线

[English](BASELINE.md) · **简体中文**

## 问题

真实仓库很少在你打开时是绿的。在任何一个仓库上开第一票之前，先跑：

```bash
bash $wfctl preflight .
pytest -q ; echo "rc=$?"        # 或：go test ./... ; npm test
```

如果是红的，那些失败就是你基线的一部分。有两件事绝不能发生：

1. 每张票都因为不是自己造成的失败而验收失败 → 门禁一周内就被忽略；
2. 有人靠删测试、跳过测试来"修好"基线 → 门禁被绕过。

## 流程

```bash
# 1. 记录红集合（每行一个 node id）
bash $wfctl testbaseline . "pytest -q"
#    → .agents/pytest-baseline.txt
#       tests/test_replay.py::test_baseline_matches
#       tests/test_watermark.py::test_sub_image_corner

# 2. 从此 verify 只为「新」失败发红
bash $wfctl verify .
#    [wfctl] ✅ 测试: pytest -q（rc=1，均为既有红 4 条，见 .agents/pytest-baseline.txt）
```

基线文件就是普通文本：在 diff 里复查它，债还完就删掉它，集合合法变化时重新记录。

## 判断一条基线失败是数据还是代码

"刷新基线"和"实现坏了"在失败输出里长得一模一样。用证据判断，不要凭感觉：

| 现象 | 通常是什么 |
|---|---|
| golden / 快照测试，输入规模变了（623 → 632 条） | **数据漂移**——重拍基线，并在提交说明里写清 |
| 断言的是行为，不涉及数据 | **代码**——不要刷新，去修 |
| 只在某台机器 / 某个时区失败 | **环境**——钉死它，或显式排除 |

如果是数据漂移，这个决定属于仓库主人，不属于 agent："新数据到了"和"我们改了要测的口径"会产出同一个新快照，但含义完全不同。

## `wfctl testbaseline` 与解释器

`testbaseline` 只跑你给的那条命令。在一台 `python` 不是装了 pytest 的那个解释器的机器上，`python -m pytest` 会记录 **0 条**失败，并静默产出一个空基线。用你 shell 里真能跑的那条（`pytest -q`），并检查文件不是空的。

## .diffcovignore

测不了的文件（顶层直接调线上 API 的脚本、codegen 产物、没有测试挂点的 CLI 入口）写进仓库根的 `.diffcovignore`，一行一个 glob，并附一句原因：

```
# 只在上线时执行的脚本：顶层就调市场 API，没有测试挂点。
# 这里是显式登记的债 —— 谁把它改成可测，就删掉这一行。
tools/publish_sku.py
```

这与下调 `WF_DIFFCOV_MIN` 是两件事，故意的：豁免在 diff 里、可复查、有名字。一个偷偷降到 0.6 的阈值什么都测不出来，还把所有东西都遮住了。
