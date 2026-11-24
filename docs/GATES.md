# The gates

English · [简体中文](GATES.zh-CN.md)


Every gate below returns an exit code. Nothing here asks you to trust a summary.

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

## 1. `wfctl envcheck` — is the executor actually able to run?

Missing `DEEPSEEK_API_KEY` makes the executor print `No API key found for deepseek` **and exit 0**. That is the archetype of the problem this repo exists for.

```
rc=0  key present (prints only len=N, never the value)
rc=1  key missing, with the exact file paths it searched
```

Also checks the executor binary and the repo's git state.

## 2. `wfctl lookup <repo> "<question>" --slug <slug>` — did the work start from prior art?

Writes `.agents/tasks/<slug>/lookup.md` from a real search (sources + what they do + what differs here). `deleg` refuses to run without it, because "the agent will figure it out" is how re-inventions happen.

```
rc=0  record present, §4 conclusion non-empty, no <placeholders>
rc=1  missing / placeholder / no sources  (escape: WF_NO_LOOKUP=1)
```

## 3. `wfctl task` — a ticket with a spec or no ticket

Creates `.agents/tasks/<slug>/{SPEC.md,brief.md}`. The SPEC is a list of `**CR1**…**CRn**` requirements, each with a machine-checkable acceptance criterion and a test pointer:

```markdown
- **CR1** merge_specs builds attrs from specs, dictionary lookup injected as a callback.
  [test: tests/test_attrs.py::test_merge_plain_and_dict]
- **CR3** glue code in the publish script (not importable, no test harness).
  [test: n/a: top-level script calls the live API, covered by .diffcovignore]
```

Anything that cannot be tested must say so **in the spec**, with a reason of ≥8 characters. The gate prints the exemption when it accepts it — exemptions are visible, not silent.

## 4. Brief lint — is the task description complete?

`deleg` rejects a brief that lacks any of: the five sections (facts / steps / constraints / deliverables / self-check), an observed-facts line, or `expect:` (the artifacts it must produce).

```
rc=5  no line starting with 实测事实: (observed facts)
```

The observed-facts requirement exists because a brief full of assumptions is where agents hallucinate most cheaply. "Run this and paste what it printed" costs one line.

## 5. `wfctl worktree` — one ticket per working tree

Second concurrent ticket in the same directory: `rc=4` (lock file). Isolation is not a nicety; two agents in one tree delete each other's edits.

## 6. Stall watchdog

No new event for N seconds → `rc=124`, the process is killed and the ticket is marked stalled. A hanging executor must not look like a running one.

## 7. `dispatch_verify.py` — did the executor stay inside its box?

Re-hashes the artifacts the executor declared, compares against a truth file, and checks count and key fields.

```
rc=0  every declared artifact matches
rc=2  an artifact was modified out of scope / escaped its sandbox
rc=3  content differs from truth (per --key-field)
rc=4  count mismatch (--expect-count N)
rc=5  bad arguments, or the truth file is missing
```

## 8. `converge --strict` — does the report describe the code?

Six checks, all mechanical:

1. a convergence report exists for this slug;
2. it contains a final verdict line;
3. every `CRn` from the SPEC is mentioned;
4. at least one `path:line` evidence reference — cited, not paraphrased;
5. when the verdict is "not converged", a gap list with reproduction steps;
6. **every CR's test pointer actually runs green** (see gate 9).

```
rc=0  converged
rc=2  report missing, or a CR's test evidence does not hold
rc=3  not converged (gap list expected)
```

## 9. Per-CR test pointer — "covered by a green suite" is not coverage

Each `[test: file::case]` is checked three ways: the file exists, the case name appears in it, and **that single case is executed** (`pytest file::case`, `go test -run Name`, `node --test`). A requirement whose named test fails is not covered, no matter how green the rest of the suite is.

`[test: n/a: reason]` is the only exemption, and it is printed.

## 10. Test run + known-red baseline

Runs whatever the repo uses: `WF_TEST_CMD` → pytest markers (`pytest.ini`, `pyproject.toml`, `setup.cfg`, `tox.ini`, `tests/test_*.py`) → `package.json` `test` script → `go test ./...`.

Then it compares the failing set with `.agents/pytest-baseline.txt` (written by `wfctl testbaseline`). Real repositories are already red when you arrive: data drift, a long-standing broken test, someone's WIP. Failing because of those makes the gate noise, so:

- failures ⊆ baseline → **pass**, and the count is printed;
- any failure outside the baseline → **fail**, listing only the new ones.

See [`BASELINE.md`](BASELINE.md).

## 11. Patch coverage — did the tests run the lines you changed?

`diffcov.py` diffs the change set, keeps added executable lines (comments, blank lines and docstrings excluded — they never emit a line event), runs the tests, and checks which of those lines were actually executed.

```
rc=0  ≥ threshold (default 100%) executed
rc=4  cannot measure (no git, no changes, unsupported language) → reported as SKIP, never as pass
rc=5  below threshold, with the exact uncovered line numbers
```

Go uses `go test -coverprofile`; Python uses `covrunner.py` (`sys.settrace`, line-level, no third-party package); Node is currently SKIP.

Scope matters: `git diff HEAD` sees **other people's uncommitted work**, so the measured set is restricted with `WF_DIFFCOV_PATHS=a.py,b.py` (or `.diffcovignore` for files that cannot be tested at all, each with a reason in the diff).

## 12. Format normalization

`gofmt -l` on a CRLF checkout flags every file, forever. The gate normalizes line endings before deciding, and reports "only whitespace changed" separately instead of pretending to be a formatting failure.

## 13. Run ledger

Every command appends to `$HC_LEDGER` (jsonl): `cmd`, `dir`, `slug`, `rc`, `dur_s`, tokens, cost, `settled`, `stalled`, `missing`. A ticket that never wrote `settled` did not finish, whatever the transcript says.

`wfctl stats` derives the numbers that actually matter: tickets, rework rate, acceptance-failure rounds, wasted-run rate, cost per ticket. Test/experiment runs are excluded by default so your own smoke tests don't flatter the numbers.

## 14. `gate_watch` — is anyone still using this?

The failure mode nobody notices: the workflow exists, the docs are good, and for six weeks every change was made by hand. `gate_watch.py` reads the ledger and convergence reports; if there was no delegated ticket and no new report in the last N days, it says so once (with a cooldown). Healthy = silent output, exit 0 — suitable for cron.

Entry-theft checks run too: the AGENTS.md anchor, the runbook skill, the credential auto-loader, and the key line itself. If any of them disappeared, that is reported immediately.

## Exit codes at a glance

| Tool | 0 | 2 | 3 | 4 | 5 | 6/7/124 |
|---|---|---|---|---|---|---|
| `wfctl deleg` | ok | — | expected artifact missing | concurrent ticket lock | brief lacks `实测事实:` | exception / no `agent_settled` / stalled |
| `wfctl converge` | converged | report missing or CR test evidence broken | not converged | — | — | — |
| `diffcov.py` | ≥ threshold | — | — | cannot measure (SKIP) | below threshold | — |
| `dispatch_verify.py` | all match | artifact tampered / out of scope | differs from truth | count mismatch | bad args / truth missing | — |
| `ledger_stats.py` | has data | — | ledger empty | — | — | — |

## Environment variables

| Var | Default | Purpose |
|---|---|---|
| `HC_HOME` | `~/AppData/Local/hermes`, else `~/.hermes` | where skills, scripts, ledger, `.env` live |
| `HC_SCRIPTS` | `$HC_HOME/scripts` | the five helper tools |
| `HC_LEDGER` | `$HC_HOME/run_ledger.jsonl` | run ledger |
| `HC_ENV_FILE` | `$HC_HOME/.env` | credential file (`DEEPSEEK_API_KEY`) |
| `WF_TEST_CMD` | auto-detected | override the test command |
| `WF_DIFFCOV` | `1` | set `0` to skip patch coverage |
| `WF_DIFFCOV_PATHS` | all changed | restrict coverage to this ticket's files |
| `WF_DIFFCOV_MIN` | `1.0` | coverage threshold |
| `WF_NO_LOOKUP` | — | `1` bypasses gate 2 (and says so) |
| `HC_WATCH_REPOS` | empty | comma-separated repos for `gate_watch` |
