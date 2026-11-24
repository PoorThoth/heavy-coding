---
name: code-gate
description: "Use when changing code/fixing bugs/delivering: pick light or heavy mode first, accept exit codes only."
version: 1.0.2
author: Heavy Coding
license: MIT
triggers:
  - change code
  - write code
  - fix bug
  - commit
  - refactor
  - deliver code
metadata:
  heavy-coding:
    tags: [workflow, gate, exit-code, delegation]
    related: [grill-then-implement, docs/GATES.md]
---

# Entry point for any code change (runbook) · 30 seconds to pick a mode → hand back an exit code
English · [简体中文](SKILL.zh-CN.md) ｜ Full gate spec: `docs/GATES.md`

## When to Use

Before touching any repo file / adding a feature / fixing a bug / batch-editing data / delivering code. Picking the mode is not optional.

## Step 0: pick the mode

| Condition (all must hold) | Mode |
|---|---|
| one file or one module · no schema change · no money · no deploy · one ticket finishes it | **Light** |
| ≥3 modules / database / money / production / cannot finish in one ticket | **Heavy** |

If you cannot tell → go heavy. State the mode in your first line so the user can interrupt.

**Changing a gate, checker or template ⇒ always heavy.** It affects every later ticket; it is not "a one-line change". Such a change cannot be certified by the very gate it modifies: prove it in a sandbox with red evidence both ways (red → fix → green) and hand over an "injected failure → actual rc" table.

## Light mode

```bash
cd <repo> && git status --porcelain          # ① baseline: only start from a known state
<edit code>                                   # ② one thing at a time
go test ./... -count=1 > /tmp/t.log 2>&1; echo RC=$?   # ③ tests (Python: pytest -q, Node: npm test; never pipe)
git add -A && git commit -m "<what changed, why>"
```

- **Green tests ≠ wired up.** Read back the target line (`file:line`) and confirm the caller actually calls it. Report rc directly (`cmd > log 2>&1; echo $?`), never the rc of a pipeline tail.

## Heavy mode (7 commands) · dual track = spec axis `converge --strict` ∥ standards axis with an independent reviewer (running one is not a dual track)

```bash
WF=$HC_HOME/skills/software-development/grill-then-implement/scripts/wfctl.sh
bash $WF preflight <repo>                     # ① executor ready (executor binary / key / repo state)
bash $WF task <repo> <slug> "<goal>"          # ② scaffold .agents/tasks/<slug>/{SPEC.md,brief.md}
# ③ write the SPEC: one `- **CRn**` per requirement + a **[test: file::case]** pointer
#    (converge really runs that case; missing pointer ⇒ rc=2; untestable ⇒ [test: n/a: reason ≥8 chars])
#    write the brief: five sections + a line starting `实测事实:` (observed facts) + `expect:`
bash $WF lookup <repo> "<question>" --slug <slug>   # ④ recorded prior-art search (delegation is refused without it)
bash $WF deleg <repo> .agents/tasks/<slug>/brief.md # ⑤ delegate; read the rc
bash $WF converge <repo> .agents/tasks/<slug>/SPEC.md --strict   # ⑥ convergence
bash $WF verify <repo>    # ⑦ accept: tests (Go/pytest/npm) + patch coverage + converge + ledger
bash $WF diffcov <repo> · stats --since <date>   # patch coverage (default 100%, unmeasurable → SKIP rc=4) · ledger metrics
```

**On the first ticket in a real repo, do two things first:** `bash $WF testbaseline <repo> "pytest -q"` pins the **known-red baseline** (afterwards only new failures fail, and the report says "rc=1, all of them recorded reds"); `export WF_DIFFCOV_PATHS=<this ticket's files>` scopes coverage to this ticket (`git diff HEAD` picks up other people's uncommitted work and dilutes the number into noise). Language pitfalls (Go module paths / Python interpreter and settrace cost / exemption lists) are in `docs/BASELINE.md`.

| rc | Meaning | What to do |
|---|---|---|
| 0 | done and converged | only now may you say "done" |
| 3 | expected artifact missing | look at the drop location before re-running |
| 4 | second ticket in the same directory | wait for the lock, or remove a stale one |
| 5 | brief has no line starting `实测事实:` | add the observed-facts line |
| 6 / 7 / 124 | bad stop_reason / no `agent_settled` / stall watchdog | read the error and classify; `--continue` to resume; artifacts may be half-written — inspect first |
| converge 2 / 3 | report missing / not converged / **a CR's test evidence does not hold** | add `file:line` and `[test: file::case]`; never weaken a test to fit the implementation |
| diffcov 5 | changed lines were never executed | add tests that reach them; declarations and error branches get tested or split out |

## Two silent preconditions

1. **`DEEPSEEK_API_KEY` missing** ⇒ the executor prints "No API key" and exits `rc=0`, wasting the run. wfctl auto-loads it from `$HC_HOME/.env` (`WF_ENV_FILE=` overrides; only the key length is printed). Still failing → `wfctl envcheck` tells you what it searched.
2. **Repo has no `.agents`** ⇒ run `wfctl task` to scaffold it. **A CRLF checkout makes gofmt red forever** ⇒ only normalized diffs count (`wfctl verify` already handles it; do not hand-edit line endings).

**Report three things at the end**: mode (light/heavy) · the verification command with its real rc · the archive path.
