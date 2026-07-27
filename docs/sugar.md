# Where the bulk actually is — a measurement, not a proposal

*Status: acted on. Written after the job shop pair, to answer "what syntax
would make Pol models shorter?" with numbers rather than taste — and the
numbers said the answer was not sugar at all. Both conclusions have since
shipped: `maybe` into stdlib §8, and the real change, `set` with a chain,
into §10.3.*

The prompt was a specific suggestion: replace

```lisp
(arrow held-by (to job) vacatable)
```

with `(arrow held-by *(to job))`, reading `*(x)` as "x, vacatable". It is a
reasonable instinct and the answer to it is short, so it comes first — but it
turns out to be the cheapest possible win in the least valuable place, and
finding *that* out is the useful part.

## The measurement

Every `.pol` file shipped as an example, counted by datum head:

| head | count |
| --- | --- |
| `transition` | **154** |
| `type` | 36 |
| `arrow` | 36 |
| `form` | 28 |
| `schema` | 10 |
| `instance` | 10 |
| `equation` | 4 |

And by file, non-comment non-blank lines:

| file | lines |
| --- | --- |
| `queens/queens.pol` | **468** |
| `queens/queens-unordered.pol` | 412 |
| `jobshop-best/jobshop-best.pol` | 69 |
| `workflow/workflow.pol` | 44 |
| everything else | 26–40 |

*(Both queens figures are as measured here. `queens.pol` is now 83 lines with
eight moves; the section "What the measurement got wrong" at the end says how,
and which half of this note's diagnosis survived.)*

Two things fall out immediately. **Transitions outnumber arrows four to one**,
so sugar aimed at `arrow` is aimed at 36 datums out of 278. And **one file is
seven times the size of every other**, so "why are Pol models long?" is really
one question about one file.

`queens.pol` is 561 lines. Fifty-eight of them are the schema, the instance,
the seven `safeN` forms, and the comments. The other five hundred are
**sixty-four transitions** — one per (column, row) pair.

## Why there are sixty-four

Not arithmetic, and not diagonals. Both of those were solved by making rows a
ladder walked by `next`/`prev` (`tests/examples/queens/README.md`). What is
left is one sentence of §10.3:

> `(set CHAIN V)` — writes the slot named by the chain's last step … V in the
> **target domain**

V is a literal. A move may write `q3.at := r5`, but not `q3.at := q3.at.next`.
So a queen cannot **walk** the board, only be *placed* on a named square — and
every named square needs its own transition. Eight queens × eight rows.

The same sentence sets the floor in the job shop. `jobshop-best` spends **nine
of its sixty-nine lines** on `tick-1` … `tick-9`, which are nine copies of one
idea, because `(set clk.at clk.at.next)` cannot be written either.

**This is the whole of the bulk, and it is not a syntax problem.** No form can
lower it: a form may expand to several *top-level* datums, but it cannot map
over a `&rest` capture, so `(place-all q3 r1 … r8)` is unwritable. The
design note is already written — [`set-as-chain.md`](set-as-chain.md) — and the
job shop is the third independent model to ask for it.

## The three walls, each tested rather than assumed

Each of these was checked by running `pol check` on a small file, because the
first two contradicted what reading the expander suggested.

### Wall 1 — `set` took a literal — **now removed**

Above. It cost 64 transitions in queens and 9 in `jobshop-best`. §10.3 now
takes a chain, so a value can be MOVED rather than only assigned by name.
`jobshop-best`'s clock went to one transition; queens went to eight, though
not in the way this note expected — see the end. The two semantic questions
this raised — when the right-hand side is read, and what an unanswerable chain
does — are decided and recorded in [`set-as-chain.md`](set-as-chain.md).

### Wall 2 — a form in expression position must yield exactly one datum

This is the one that kills `*(to job)` — including the version that looks like
it should work today:

```lisp
(form (opt T) => (to T) vacatable)
(type machine (arrow held-by (opt job)))
```

```
pol: opt.pol:4:33: form `opt` expands to several datums where one is required
```

Splicing several datums works **only at top level** (`Expander.stmt`); anywhere
inside a list, `Expander.expr` demands one. So the sugar as proposed cannot be
a form at all. It would have to be a **reader** change — `*` as a prefix sigil,
the first punctuation in the language besides `.` and `"`.

That is a bad trade, and the reason is Pivotal idea 7: *vocabulary grows but
meaning does not*. A form is rename-and-paste, so a reader can always expand it
by hand and see the kernel underneath. A sigil is not — it is kernel surface,
it applies to every file whether or not anyone wanted it, and it buys exactly
one keyword in one position.

**And the effect is available today, in fewer tokens than the proposal:**

```lisp
(form (maybe A T) => (arrow A (to T) vacatable))
(type machine (maybe held-by job))
```

Three tokens against the proposal's five, no kernel change, and the expansion
is readable. This is what shipped, as stdlib §8, and it is **used**: eight
arrows across the examples and `tests/models/politics.lib.pol` now take it,
including one inside another form's template (`headship` expands to `maybe`
expands to `arrow`, which nests correctly).

Its limit is worth stating in the same breath: `maybe` covers the **plain**
vacatable arrow, and there is no spelling for `fixed vacatable` — never
rewired, but may run off the end. One shipped arrow still wants it,
`jobshop-best`'s tick ladder:

```lisp
(type tick (arrow next (to tick) fixed vacatable))
```

Covering that would need either a second name (`fixed-maybe` is worse than what
it abbreviates) or flags as slots, which hands a form a keyword position for a
saving that does not justify it.

### Wall 3 — template heads, which is not a wall

`Forms.allowed_head` lets a template datum be headed by a reserved word, an
**earlier form**, or a **slot**. So a template can head a datum with a
user-chosen arrow name, provided the name arrives through a slot:

```lisp
(form (rung N P A B) => (N (A B)) (P (B A)))   ; legal to declare
```

It is only Wall 2 that stops this being useful — instance data lives *inside*
an `(instance …)` list, so the two datums have nowhere to splice to. Worth
recording because it means removing Wall 2 would also let forms generate
instance data, which is a second payoff for one change.

## What to do

**1. Nothing to the reader.** No `*(x)`. The sigil costs a global lexical rule
and buys one keyword; `(maybe held-by job)` is already shorter.

**2. Add `maybe` to the standard library.** One line, no kernel change, and it
covers the case that prompted the question.

**3. The real change is `set` with a chain, and it is a widening, not sugar.**
**DONE.** Symmetric with what §10.2 did to `is`, and it adds no kernel word, so
the count stays at twenty-seven. The two open questions were decided as
[`set-as-chain.md`](set-as-chain.md) recommended — the right-hand side is read
in the situation the move started from, and a chain with no answer makes the
move absent rather than a no-op. `jobshop-best`'s clock went from eight
transitions to one, and queens from sixty-four moves to eight — though not by
the route this note assumed. See the end.

**4. Wall 2 is worth a note of its own, eventually.** Splicing inside a list
would let forms build instance data and type bodies, and it is the general
version of what the `*(x)` proposal wanted in one specific spot.

## What the measurement got wrong

The counting above is correct and its conclusion about *sugar* still stands.
Its conclusion about **queens** does not, and the error is worth keeping
because it is the kind this whole note was written to avoid.

The note said the 500 lines of `queens.pol` were forced by §10.3 — one move
per (column, row), because `set` took a literal. §10.3 was then widened, and
queens was rewritten twice. It is now **83 lines** with **eight** moves, the
same 2057 situations and the same 92 boards.

It took two independent changes, and the note had only half of one.

**Step 1 — name the diagonals. No language feature at all.** Give squares a
`da` and `db` arrow, so a diagonal is a named entity rather than a ladder
walked *d* times. Seven distance-indexed `safeN` forms become one quantified
`free`; a seven-conjunct guard becomes three. 468 lines to 119, and `(set Q.at
S)` still writes a literal exactly as it always could. **Better data, not a
bigger language** — this would have worked before any of the work above.

**Step 2 — a cursor. This is the one that needs §10.3.** After step 1 there
were still sixty-four moves, because a move had to say *which* queen it
placed. A cursor says it instead: the moves index rows only, and each advances
`cur` with `(set cur.q cur.q.next)` — a chain on the right — while
`(set cur.q.at S)` writes the queen the cursor named when the move *began*,
which needs simultaneity. 119 lines to 83, sixty-four moves to eight.

So the note's diagnosis was **right about the cause and wrong about the cure**.
Transitions were the bulk; §10.3 was the constraint; but the fix was not the
obvious one. The obvious one — let a queen *walk* — was built and measured and
is worse: 7.6× the situations, and a finished board stops being a dead end,
which is the nicest thing that example shows. What actually cashed the widening
was moving a **cursor**, not moving the thing being placed.

One thing this note never named, and should have: Pol has no move that picks
its destination nondeterministically. A guard's binder is scoped to the guard,
so `(some (s square) …)` cannot hand `s` to `(set q.at s)`. That is why the
sixty-four could not simply be quantified away, and why the answer had to come
from somewhere else entirely.

The transferable lesson: when a model is long, ask what its **data** cannot say
before asking what the **language** cannot say — and when the language *is* the
answer, the useful move may not be the one the shortcoming suggests.
