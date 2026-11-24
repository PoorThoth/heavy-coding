# 参与贡献

[English](CONTRIBUTING.md) · **简体中文**

这个项目的主题就是「不采信没验证过的说法」，所以从它自己开始。

## 第一道门：你必须被 vouch

未通过 vouch 的作者的 PR 会被 [`vouch`](https://github.com/mitchellh/vouch) **自动关闭**。机器人、以及有 write 权限的协作者自动放行。

怎么被 vouch：

1. 提一个值得读的 issue——真实的复现、具体的缺口、或一个清楚的问题，一屏以内。
2. 维护者在那条 issue 下回 `vouch`，你就进了名单（`.github/VOUCHED.td`），之后 PR 不再被自动关。
3. 如果你的 PR 已经被关了，被 vouch 之后在那条 PR 下评论 `/recheck` 重跑检查。

被 denounce 的账号会被永久拦截；在 issue 下回 `denounce 理由` 即可拉黑某人。

**issue 不做门槛**：只有被 denounce 的人，issue 才会被自动关。

## 提 PR 之前

```bash
./install.sh
cd examples/lab && wfctl verify .
```

PR 必须带：

- 一张票（`.agents/tasks/<slug>/SPEC.md`），每条判据都带 `[test: 文件::用例]`
- 证据：你跑的命令和它的**退出码**——截个绿勾不算证据
- 不许为了让东西变绿去削弱测试，也不许往 `.diffcovignore` 里加一行躲覆盖

哪道门没过就直说哪道、为什么。没有 rc 的「在我机器上是好的」只是一句话，不是结果。

## 用 AI 写代码没问题

用什么 agent 都行。我们不接受的是自己讲不清的改动：如果你的 diff 干了什么、跟系统其它部分怎么交互，你说不出来，这个 PR 就会被关掉。这正是这个项目存在的理由——人得是那个懂代码的人。

## 会被直接关掉的情况

- 从没跑过 `verify`，或者报了成功却没有退出码的 PR
- agent 生成、人没读过的 issue 倾倒
- 把「顺手重构」塞进一个修 bug 的 PR

## 从哪开始

`docs/GATES.zh-CN.md` 是 14 道门和每道门的 rc；`examples/lab` 可以让你在 60 秒内亲手弄红一道门——看这个项目到底在检查什么，没有比这更快的方式。
