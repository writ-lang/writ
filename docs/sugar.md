# Where the bulk actually is — a measurement, not a proposal

*Status: findings only. Nothing implemented, and the one change worth making
is not sugar. Written after the job shop pair, to answer "what syntax would
make Pol models shorter?" with numbers rather than taste.*

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

### Wall 1 — `set` takes a literal

Above. Costs 64 transitions in queens, 9 in `jobshop-best`. Designed already,
not implemented.

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
is readable. Verified: builds, checks, `set`/`vacate` both work through it.
If `maybe` is worth having, it belongs in the standard library, not the reader.

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
It removes 64 transitions from one model and 9 from another; it is symmetric
with what §10.2 already did to `is`; and it adds no kernel word, so the count
stays at twenty-seven. [`set-as-chain.md`](set-as-chain.md) has the design and
the two open semantic questions (when the right-hand side is read, and what an
undefined right-hand side does). Those need deciding before anything is built.

**4. Wall 2 is worth a note of its own, eventually.** Splicing inside a list
would let forms build instance data and type bodies, and it is the general
version of what the `*(x)` proposal wanted in one specific spot.

## The honest caveat

Removing Wall 1 does **not** by itself get eight queens under thirty lines.
Each queen's safety guard names a different set of distances to the other
seven, so the eight walk-transitions do not collapse into one form invocation —
they collapse from sixty-four bodies to eight, which is a large win and not a
total one. Any line count quoted before the change is built is an estimate,
and this note declines to quote one.
