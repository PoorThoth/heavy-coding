# Ticket templates

[简体中文](README.md)

`wfctl task` copies these three into `.agents/tasks/<slug>/`. They are scaffolds, not paperwork: every section ends with something a machine can check.

| File | What it is | Rule |
|---|---|---|
| `SPEC.md.tpl` | Acceptance criteria, one `**CRn**` each | every CR carries `[test: file::case]`; untestable ⇒ `[test: n/a: reason >=8 chars]` |
| `brief.md.tpl` | The work order handed to the executor | five sections + a line starting `实测事实:` (observed facts) + `expect:` |
| `converge.md.tpl` | The convergence report | every CR appears twice: implementation `file:line`, and what was actually run |
| `lookup.md.tpl` | Prior-art check | §4 conclusion non-empty; delegation is refused without it |
| `preamble.txt` | Prepended to the brief on `deleg` | says: no questions, leave evidence, report the rc |

## Language

Chinese is the default. `WF_TEMPLATE_LANG=en` switches to `*.md.en.tpl` and `preamble.en.txt`. An unknown language falls back to Chinese.

## Placeholders

Templates are rendered with `<slug>`, `<goal>`, `<date>`, `<project>`, and the generated tables `<cr_table>` / `<cr_test_table>`. Angle-bracket text that is *not* one of those is left alone on purpose — it is an instruction to the person filling the ticket in.
