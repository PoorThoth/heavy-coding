# Contributing

English · [简体中文](CONTRIBUTING.zh-CN.md)

This project is about not trusting unverified claims, so it starts with itself.

## The gate: you must be vouched

Every PR from an unvouched author is **closed automatically** by [`vouch`](https://github.com/mitchellh/vouch). Bots and collaborators with write access are always allowed.

How to get vouched:

1. Open one issue that is worth reading — a real reproduction, a concrete gap, or a clear question. Keep it to one screen.
2. A maintainer replies `vouch` in that issue. You are on the list (`.github/VOUCHED.td`) and your PRs are no longer auto-closed.
3. If your PR was already closed, comment `/recheck` on it after being vouched.

Denounced accounts stay blocked; commenting `denounce <reason>` on an issue blocks a user permanently.

Issues are **not** gated. Only denounced accounts get their issues closed.

## Before you open a PR

```bash
./install.sh                      # or: export HC_SCRIPTS="$PWD/scripts"
cd examples/lab && bash "$HC_SCRIPTS/../skills/grill-then-implement/scripts/wfctl.sh" verify .
```

The PR must come with:

- a ticket (`.agents/tasks/<slug>/SPEC.md`) whose every criterion carries `[test: file::case]`
- evidence: the command you ran and its **exit code** — a screenshot of a green checkmark is not evidence
- no test weakened to make something pass, no `.diffcovignore` line added to dodge coverage

If any gate fails, say which one and why. "It works on my machine" with no rc is a claim, not a result.

## Using AI is fine

Write with whatever agent you like. What we do not accept is a change you cannot explain: if you can't say what your diff does and how it interacts with the rest of the system, the PR gets closed. That is the whole point of the project — the human stays the one who understands the code.

## What gets closed without discussion

- PRs that never ran `verify`, or that report success without an exit code
- issue dumps produced by an agent without a human reading them
- "while I was here" refactors bundled into a bug fix

## Where to start

`docs/GATES.md` lists the 14 gates and what rc each one returns. `examples/lab` lets you break a gate on purpose in 60 seconds — the fastest way to see what this project actually checks.
