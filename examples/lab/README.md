# Sandbox: break a gate with your own hands

English · [简体中文](README.zh-CN.md)

```bash
cd examples/lab
bash $WF task . demo "make whisper end with an exclamation mark"      # ① open a ticket
# ② write CR1 in the SPEC with [test: tests/test_demo.py::test_whisper]
bash $WF converge . .agents/tasks/demo/SPEC.md --strict               # → rc=3/2 (no report yet)
```

Three reds worth causing once, by hand:

| Injection | Command | Expected |
|---|---|---|
| report cites no `file:line` | `wfctl converge … --strict` | rc=3 (not converged) |
| CR points at a case that does not exist | same | rc=2 (test evidence does not hold) |
| code changed, no test added | `wfctl verify .` | diffcov rc=5, naming every uncovered line |
