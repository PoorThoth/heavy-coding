---
name: grill-then-implement
description: "Heavy-mode reference: interrogate → SPEC → delegate → converge → accept; the criteria and pitfalls of every gate."
version: 2.0.0
author: Heavy Coding
license: MIT
metadata:
  heavy-coding:
    tags: [workflow, delegation, spec, converge]
---

# grill-then-implement — the heavy-mode reference

English · [简体中文](SKILL.zh-CN.md)

> Day to day you only need `skills/code-gate/SKILL.md` (the 80-line runbook). This file answers "why is it designed this way, and what exactly does each gate stop".
> Machine criteria for every gate: [`docs/GATES.md`](../../docs/GATES.md). Red-baseline procedure: [`docs/BASELINE.md`](../../docs/BASELINE.md).

## 1. What it solves

A delegated real code change has four silent failure modes that all look like success: missing credentials with rc=0, tests that were never collected, a green suite that never calls the new code, and a convergence report whose `file:line` does not exist. None of them is visible by reading the executor's prose — only a checkpoint that **fails loudly** catches them.

So every gate must satisfy three things:

1. it has its own **exit code**, and non-zero means something specific (`0` is only earned by a machine-checkable fact);
2. it has a **reproducible way to be made red** — you have to know how to break it before you can claim it works;
3. its failure output names the **location** (`file:line`, case name, uncovered line numbers), not "please check".

## 2. Shape of the chain

```
preflight → task(SPEC+brief) → lookup → deleg → converge → verify → ledger/stats
                                        ↘ dispatch_verify (artifact integrity)
```

| Stage | Command | What it stops | Non-zero means |
|---|---|---|---|
| 0 ready | `wfctl preflight` | executor present, key present, repo state known | 1 = precondition missing |
| 1 ticket | `wfctl task` | no SPEC, no ticket | — |
| 2 prior art | `wfctl lookup` | reinventing the wheel | 1 = no record |
| 3 delegate | `wfctl deleg` | brief without `实测事实:` / `expect:` | 5 = no observed-facts line; 3 = expected artifact never landed; 4 = concurrent lock; 7 = never settled; 124 = stalled |
| 4 artifacts | `dispatch_verify.py` | artifacts edited, out of scope, wrong count, wrong content | 2/3/4/5 |
| 5 converge | `wfctl converge --strict` | whether report, SPEC, code and tests agree | 2 = report or test evidence broken; 3 = not converged |
| 6 accept | `wfctl verify` | tests (incl. known-red baseline) + patch coverage + convergence + ledger | any item non-zero |
| 7 observe | `wfctl stats` / `gate_watch.py` | rework rate, wasted runs, and "is anyone using this at all" | 3 = empty ledger |

## 3. How to write a SPEC that actually holds

- One CR per requirement; phrase the criterion so a command can falsify it (`rc=0`, `file:line` present, a function returns a given value). Never "code quality is good".
- Every CR carries `[test: file::case]`. The convergence gate **runs** that case — it does not read the report.
- Genuinely untestable (a script whose top level calls a live API, a codegen artifact): write `[test: n/a: reason ≥8 chars]` and list the file in `.diffcovignore`. Exemptions are printed.
- **Write the boundaries down**: which files may change, what must not be run (live API, real DB, push), and that pre-existing uncommitted work is off limits.

## 4. How to write a brief that does not hallucinate

Five sections: ① the task in one sentence ② prior-art conclusion ③ facts and material (**already scouted — the executor must not re-explore**) ④ steps (assess / fix / test / close) ⑤ hard constraints.

Plus two machine-read lines:

- `实测事实: <what was actually run today and what it printed>` — without it `deleg` returns rc=5;
- `expect: <files that must be produced>` — missing it, `deleg` returns rc=3.

One good "facts" section saves half the executor's wandering; one good "constraints" section saves an incident.

## 5. Three hard rules at acceptance

1. **Self-reports do not count.** "Tests pass" from the executor is not evidence: the host runs it and pastes the rc.
2. **Pin the red baseline first.** Real repos are red when you arrive (data drift, long-standing breakage). Record it with `testbaseline`, then fail only on **new** reds. The baseline file is plain text and lives in the diff.
3. **Scope the measurement.** `git diff HEAD` counts other people's uncommitted work as this ticket's change, which turns coverage into noise. Use `WF_DIFFCOV_PATHS`; use `.diffcovignore` for files that truly cannot be tested — **never quietly lower the threshold**.

## 6. Pitfalls (all of them happened)

| Pitfall | Symptom | Fix |
|---|---|---|
| credentials silently missing | executor rc=0, no output | `wfctl envcheck`; wfctl auto-loads `$HC_HOME/.env` and prints only the length |
| test command falsely red | local `python` has no pytest | use the `pytest -q` that runs on PATH; never hardcode `python -m pytest` |
| same-day reports overwrite each other | one ticket wipes another's evidence table | report named `<slug>-<date>`; `--init` never rewrites an existing report |
| pointer attribution | a reason mentioning "already covered by CR1" gets the pointer assigned to CR1 | a pointer belongs to the first CR on its own line only |
| placeholder passes as filled | `<tests/x.py>::<case>` slips through | any `<` ⇒ "placeholder not filled" |
| Go repo without `internal/` skips tests | verify is falsely green | `go test ./...` |
| settrace too slow | 300 tests take 6 minutes | cache file ownership per code object → 60 s |
| docstrings count as uncovered | changing one comment zeroes coverage | exclude docstring ranges via `ast` |
| empty description still emits the annotation attribute | an empty attribute is sent | no description ⇒ no annotation; fix the description instead |

## 7. Cost

A real change (two files + 5 tests) on DeepSeek cost about **$0.013**, 6–11 minutes, 39k in / 26k out. The gates themselves spend zero tokens (pure scripts), and `gate_watch` is free too. Only the single `deleg` call costs money.
