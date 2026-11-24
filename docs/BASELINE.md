# The red baseline

## The problem

A real repository is rarely green when you open it. Before the first ticket on any repo, run:

```bash
bash $wfctl preflight .
pytest -q ; echo "rc=$?"        # or: go test ./... ; npm test
```

If it is red, those failures are now part of your baseline. Two things must not happen:

1. every ticket fails verify because of failures it did not cause → the gate is ignored within a week;
2. someone "fixes" the baseline by deleting or skipping tests → the gate is defeated.

## The procedure

```bash
# 1. record the red set (node ids, one per line)
bash $wfctl testbaseline . "pytest -q"
#    → .agents/pytest-baseline.txt
#       tests/test_replay.py::test_baseline_matches
#       tests/test_watermark.py::test_sub_image_corner

# 2. from now on verify only fails on NEW failures
bash $wfctl verify .
#    [wfctl] ✅ 测试: pytest -q（rc=1，均为既有红 4 条，见 .agents/pytest-baseline.txt）
```

The baseline file is a normal text file: review it in the diff, delete it when the debt is paid, re-record it when the set legitimately changes.

## Deciding whether a baseline failure is data or code

"Refresh the baseline" and "the implementation broke" look identical in the failure output. Decide with evidence, not vibes:

| Symptom | Usually |
|---|---|
| golden/snapshot test, input size changed (623 → 632 samples) | **data drift** — re-snapshot, and say so in the commit message |
| assertion about behaviour, no data involved | **code** — do not refresh, fix it |
| failure only on one machine / one time zone | **environment** — pin it or exclude explicitly |

If it is data drift, the decision belongs to the repo owner, not to the agent: "new data arrived" and "we changed what we measure" produce the same new snapshot and mean different things.

## Note on `wfctl testbaseline` and interpreters

`testbaseline` runs the command you give it. On a machine where `python` is not the interpreter that has pytest installed, `python -m pytest` records **zero** failures and silently produces an empty baseline. Use the command that works in your shell (`pytest -q`), and check the file is not empty.

## .diffcovignore

Files that cannot be tested (a script whose top level calls a live API, a codegen artifact, a CLI entry point with no harness) go into `.diffcovignore` at the repo root, one glob per line, with a comment stating why:

```
# live-only script: top level calls the marketplace API, no test harness.
# it is listed here as visible debt — delete this line when it becomes testable.
tools/publish_sku.py
```

This is deliberately different from lowering `WF_DIFFCOV_MIN`: the exemption is in the diff, reviewable, and named. A threshold that quietly drops to 0.6 measures nothing and hides everything.
