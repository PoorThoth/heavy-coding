[Task] <slug>: <one sentence>. Follow `.agents/tasks/<slug>/SPEC.md` (CR1..CRn) and leave evidence.

[Prior art] Done by the host — see `lookup.md` in this directory.

Observed facts: <what was really run today, and what it printed — one line per fact>

Expect: <files this ticket must produce>

[Facts and material] (already scouted — do not re-explore)
- <file:line of the thing to change>
- <how the existing code is structured>
- <what the test style in this repo looks like>

[Steps]
1. **assess** — write `.agents/tasks/<slug>/assess.md`: current state (exact line numbers), what changes, whether the new behaviour is equivalent to the old.
2. **fix** — write the failing test first and paste the RED output, then implement until GREEN.
3. **test** — command + raw output for every CR into `.agents/tasks/<slug>/test.md`.
4. **close** — `py_compile`/build, the repo's test command, `git status --short` to prove the change surface.

[Hard constraints]
- **Do not commit, do not push, do not create a worktree, do not call any live API.**
- Change only the files listed in the SPEC; never `git add -A`.
- Never weaken a test or a criterion to make it pass. Stop and report if blocked.

[Deliverable fields] ① `git status --short` ② raw output of tests and build ③ key change locations (`file:line`) ④ self-assessed risks
