# Domain libraries

A **domain library** says what *exists*. A model says what may *happen*. These
two files hold the first half for the scenarios beside them, which is why those
scenarios are fifteen and twenty lines each.

| | serves | holds |
| --- | --- | --- |
| [`chess.lib.pol`](chess.lib.pol) | `queens/` | squares, rows, diagonals, the `free` test, the empty board |
| [`scheduling.lib.pol`](scheduling.lib.pol) | `jobshop-possible/`, `jobshop-best/` | machines, jobs, routings, the blocking rule, a clock |

Load one by relative path:

```lisp
(load "../libraries/chess.lib.pol")
```

## What makes a file a library

**Declarations only.** The loader refuses a loaded file containing `(use …)`,
`(initial …)` or a transition. So a library can carry a schema, an instance and
forms — never a model's own choice of what to run.

**It pays the namespace.** Names are global across the loaded universe and may
not be redeclared (kernel §7), so every model loading `chess.lib.pol` gives up
`board`, `square`, `queen`, `free`, `empty` and the entity names. That cost is
exactly why these are **domain** libraries and not additions to
[`core/stdlib/stdlib.pol`](../../../core/stdlib/stdlib.pol): the standard
library may not spend the shared namespace on a worldly concept. It is also the
difference in kind — `stdlib.pol` is shipped and installed; these are not.

**It offers rather than imposes.** `chess.lib.pol` declares a cursor;
`queens.pol` advances one and needs eight moves, `queens-unordered.pol` never
touches it and needs sixty-four. `scheduling.lib.pol` declares a clock;
`jobshop-best` runs it, `jobshop-possible` ignores it. Declining costs the
space nothing — a cell that is never written is the same cell in every
situation, which was measured rather than assumed.

**It is not only for models.** `jobshop-*.claims` and `jobshop-*.rules` load
`scheduling.lib.pol` too, for `all-done`. A model, a question and a derivation
can share one vocabulary without sharing a file — and questions still live in
their own document (wish 12).

## Why they are grouped here, and what that cost

Design D3 searches the **including file's own directory first**, deliberately so
that a library can sit next to the models that load it and be found with no
`POL_LIB` and no install step. Taken literally that argues for
`queens/chess.lib.pol` — and it is where this file started.

Grouping them trades a little of that for discoverability: one place to look for
"what vocabulary does this repository define", against loads that must now name
a path rather than a bare file. Both are legitimate. The bare-name form is still
what a *single* model's private library should use, and D3's first rule is what
makes `../libraries/…` resolve at all, so nothing about the search order
changed — only how much of it the load has to spell out.

`POL_TRACE_LOADS=1` prints which file each load actually resolved to, which is
how to check rather than assume:

```console
$ POL_TRACE_LOADS=1 pol check queens/queens.pol
pol: resolved "../libraries/chess.lib.pol" -> queens/../libraries/chess.lib.pol
pol: resolved "stdlib.pol" -> core/stdlib/stdlib.pol
```

## A third one, deliberately not here

[`tests/models/politics.lib.pol`](../../models/politics.lib.pol) is a domain
library too, and it stays with the unit-test corpus it serves. Moving it would
couple the unit tests to the examples tree for no gain — a library belongs
wherever all of its models can see it, and for that one, that is `tests/models/`.
