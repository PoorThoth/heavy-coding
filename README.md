# Heavy Coding

**A gate-based workflow for delegating real code changes to an AI agent — where every gate is an exit code, not a claim.**

Coding agents are unreliable narrators. They say "done", "all tests pass", "I fixed it" — and the repo says otherwise. Heavy Coding wraps a delegated coding session in fourteen checkpoints that can only be passed by a machine-checkable fact: a test that actually ran, a diff line that was actually executed, a report that actually converges with the spec.

It is ~2.5k lines of dependency-free Bash + Python. No framework, no server, no vendor SDK.

```bash
$ wfctl verify /path/to/repo
[wfctl] ✅ 测试: pytest -q（rc=1，均为既有红 4 条，见 .agents/pytest-baseline.txt）
[wfctl] ✅ 改动行覆盖（PASS  32/32 行被执行（100.0%，阈值 100%））
[wfctl] ✅ converge --strict
[wfctl] ✅ 本票账本 rc=0 cost_usd=0.012712 settled=1
[wfctl] === verify 全绿: 4 项通过, 1 项跳过 ===
```

## Why

A delegated session has four silent failure modes, all of which look like success:

| Failure | What you see | What happened |
|---|---|---|
| Credential missing | `rc=0`, empty output | the executor printed `No API key found` and exited 0 |
| Tests never collected | `rc=0` | pytest collected 0 tests; "green" means nothing ran |
| Tests pass, code unreachable | `rc=0` | every test passes, nothing calls the new function |
| Report contradicts code | `rc=0` | the convergence report lists `file:line` that does not exist |

Each one is fixed by a gate that fails **loudly**: a nonzero exit code, a missing file, an uncovered diff line. That is the whole idea. There is no dashboard to trust and nothing to take on faith.

## Install

Requires: Bash (Linux / macOS / Git-Bash on Windows), Python 3.9+. Optional: Go, Node.

```bash
git clone https://github.com/<you>/heavy-coding.git
cd heavy-coding
./install.sh            # copies skills/ + scripts/ into $HC_HOME

export HC_HOME="$HOME/AppData/Local/hermes"   # or ~/.hermes
export HC_SCRIPTS="$HC_HOME/scripts"
export HC_LEDGER="$HC_HOME/run_ledger.jsonl"
wfctl=~/.hermes/skills/software-development/grill-then-implement/scripts/wfctl.sh
bash $wfctl envcheck    # tells you which .env it found, without printing secrets
```

`DEEPSEEK_API_KEY` in `$HC_HOME/.env` is only needed for the `deleg` step (the executor calls an OpenAI-compatible endpoint). Every other gate works offline.

## 5-minute quickstart

```bash
cd /path/to/your-repo
WF=~/skills/software-development/grill-then-implement/scripts/wfctl.sh

bash $WF task . my-first-ticket "add retry to fetch_user"   # ① scaffold .agents/tasks/<slug>/
$EDITOR .agents/tasks/my-first-ticket/SPEC.md              # ② write CR1..CRn, each with [test: file::case]
bash $WF lookup . "how do others solve this?" --slug my-first-ticket --search   # ③ real search, recorded
bash $WF deleg . .agents/tasks/my-first-ticket/brief.md    # ④ hand it to the executor, read the rc
bash $WF converge . .agents/tasks/my-first-ticket/SPEC.md --strict   # ⑤ does the report match the code?
bash $WF verify .                                          # ⑥ tests + patch coverage + converge + ledger
```

Optional but recommended on a real repo, before the first ticket:

```bash
bash $WF testbaseline . "pytest -q"        # record which tests are ALREADY red
export WF_DIFFCOV_PATHS=src/mod.py,tests/test_mod.py   # only measure what THIS ticket touched
```

## The gates

Fourteen gates, grouped by what they refuse to believe. Full detail and the rc table: [`docs/GATES.md`](docs/GATES.md).

| # | Gate | Refuses to believe |
|---|---|---|
| 1 | `wfctl envcheck` | that the executor has credentials |
| 2 | `wfctl lookup` | that the work started from prior art |
| 3 | `wfctl task` | that a task without a spec can be delegated |
| 4 | brief lint | that a task description is complete (five sections + observed facts + expected artifacts) |
| 5 | `wfctl worktree` | that two tickets can share one working tree |
| 6 | stall watchdog | that "still thinking" is progress |
| 7 | `dispatch_verify.py` | that the executor did not touch what it was told not to touch |
| 8 | `converge --strict` | the convergence report's own claims |
| 9 | per-CR test pointer | that a requirement is "covered" because a suite is green |
| 10 | test run + **known-red baseline** | that a red suite is this ticket's fault (or that a green run ran anything) |
| 11 | **patch coverage** | that tests ran the lines you changed |
| 12 | format normalization | that line-ending noise is a formatting failure |
| 13 | run ledger | that a ticket finished (rc / cost / `agent_settled`) |
| 14 | `gate_watch` | that the workflow is still being used at all |

## Design principles

1. **Self-reports do not count.** Executor output is evidence only when a command returns rc=0 on a machine-checkable artifact.
2. **A red baseline is data, not failure.** Real repos start red. Record the red set (`testbaseline`), then fail only on *new* red. Otherwise the gate becomes noise and gets ignored.
3. **Exemptions are explicit and versioned.** A file that cannot be tested goes in `.diffcovignore` with a reason, in the diff, reviewable. Thresholds never get quietly lowered.
4. **Gates about gates must be tested in a sandbox.** Changing a checker cannot be validated by that checker: inject a known failure, watch it go red, fix, watch it go green.
5. **Scope the measurement to the ticket.** `git diff HEAD` includes other people's uncommitted work; measuring it produces a meaningless number.

## Repository layout

```
skills/grill-then-implement/   the heavy chain: scaffold, delegate, converge, ledger
  scripts/wfctl.sh             the single entry point (task/lookup/deleg/converge/verify/…)
  scripts/task_scaffold.py     SPEC + brief templates with CR test pointers
  templates/task/              SPEC.md / brief.md / converge.md skeletons
skills/code-gate/SKILL.md      the 80-line runbook: 30s to pick light or heavy mode
skills/subagent-dispatch/      executor wrappers + dispatch_verify.py (artifact integrity)
scripts/converge_check.py      spec ↔ code ↔ test convergence
scripts/diffcov.py             patch coverage (Go coverprofile / Python settrace / Node)
scripts/covrunner.py           zero-dependency line coverage
scripts/ledger_stats.py        derive yield metrics from the run ledger
scripts/gate_watch.py          watchdog: nobody used the workflow for N days
docs/GATES.md                  every gate, every rc, what it catches
docs/BASELINE.md               the red-baseline procedure
```

## Status

Tested primarily on Windows + Git-Bash (MSYS) against Go, Python and Node repos; the Bash is POSIX-flavoured and the Python is stdlib-only, so Linux/macOS are expected to work but less exercised. Issues and PRs welcome.

## License

MIT © 2026 Ling Guiqian
