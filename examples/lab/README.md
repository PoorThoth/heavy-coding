# 沙盒：亲手弄红一次

```bash
cd examples/lab
bash $WF task . demo "把 whisper 改成句尾加感叹号"     # ① 建票
# ② SPEC 里写一条 CR1，带 [test: tests/test_demo.py::test_whisper]
bash $WF converge . .agents/tasks/demo/SPEC.md --strict # → rc=3/2（报告还没写）
```

三种最值得亲手试一次的红：

| 注入 | 命令 | 期望 |
|---|---|---|
| 报告里不写 `文件:行` | `wfctl converge … --strict` | rc=3（未收敛） |
| CR 指向不存在的用例 | 同上 | rc=2（测试证据不成立） |
| 改了代码不加测试 | `wfctl verify .` | diffcov rc=5，逐个点名未执行行 |
