# SPEC —— <slug> (<date>)

## Acceptance criteria (each one falsifiable)

- **CR1** <what changes + what "correct" means, in one sentence> [test: <tests/test_x.py>::<test_case>]
- **CR2** <the edge case that must not silently pass> [test: <tests/test_x.py>::<test_case>]
- **CR3** <the part that genuinely cannot be tested> [test: n/a: <reason, >=8 chars>]

> Rule: every criterion must be **falsifiable by a command or a code location**; if the environment matters, say how to reproduce it on this machine.
> **Every CR needs `[test: file::case]`** — the convergence gate really runs that one case (pytest / `go test -run` / `node --test`). Static checks are three: the file exists, the case name appears in it, and it exits 0. Documentation-only criteria may use `[test: n/a: reason]`, and the reason is printed by the gate.

## Boundaries (do not cross)

- Only touch: <files>
- Do NOT: <run live API / touch the DB / git push / commit>
- Pre-existing uncommitted work in this repo is off limits: <paths or "none">
- If it cannot be done, **stop and report the blocker** — no "should be fine" conclusions without evidence.
