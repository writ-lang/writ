# Eight queens — and what made it tractable

Eight queens on a board, none attacking another. `pol check queens.pol
--claims queens.claims` answers it in about a fifth of a second, and the
witness under the holding `solvable` **is** a solution — the eight moves that
place the queens.

This scenario is here for three reasons. It is the first puzzle Pol can state
that it could not state before; it is the clearest measurement in the
repository of *which* optimisation matters; and it is where a 468-line model
became a fifteen-line one over a shared library, in two modelling steps and
one split — the first step needing no language feature at all, the second
needing a specific one, which is a distinction worth being able to point at.

## The board is a library

Neither `.pol` file here contains a board. Both load one:

```lisp
(load "../libraries/chess.lib.pol")
(use board)
(initial empty)
```

[`../libraries/chess.lib.pol`](../libraries/chess.lib.pol) is a **domain
library** — the vocabulary of a chessboard, and none of its behaviour. That split is what leaves `queens.pol` at fifteen lines
and `queens-unordered.pol` at twenty: everything they share is said once.

| | lines |
| --- | --- |
| `../libraries/chess.lib.pol` — squares, rows, diagonals, the `free` test, the empty board | 69 |
| `queens.pol` — the cursor and eight moves | **15** |
| `queens-unordered.pol` — sixty-four moves in eight lines | **20** |

Three things make it a library rather than a file that happens to be loaded.

**It is declarations only.** The loader refuses a loaded file that contains
`(use …)`, `(initial …)` or a transition, so a library can carry a schema, an
instance and forms — but never a model's own choice of what to run.

**It is found by a relative path, with nothing configured.** Design D3's
*first* search rule is the including file's own directory, which is what makes
`../libraries/…` resolve — no `POL_LIB`, no install step. `stdlib.pol` is
shipped; a domain library is not, and that is the whole difference between the
two kinds. (`POL_TRACE_LOADS=1` prints which file each load resolved to, which
is how you check rather than assume.)

**It pays the namespace.** Names are global across the loaded universe and may
not be redeclared (§7), so every model loading this gives up `board`, `square`,
`queen`, `free`, `empty` and the rest. That cost is exactly why this is a
*domain* library and not an addition to stdlib — the standard library may not
spend the shared namespace on a worldly concept.

And it **offers** rather than imposes. The library declares a `cursor-t`;
`queens.pol` advances one and needs eight moves, `queens-unordered.pol` never
touches it and needs sixty-four. Which of the vocabulary to use is the model's
say — and the unused cursor costs the unordered space nothing, because a cell
that never changes is the same cell in every situation.

## The board itself is one idea: name the diagonals

**Columns** are not constrained, they are unrepresentable: queen `q3` **is**
the queen of column 3, so no two queens can share one. Building the constraint
into the data is the oldest trick in the puzzle and it costs nothing here.

**Rows and diagonals** are the real question, and the model answers both the
same way — by *naming* them. A square knows three things, all `fixed` and all
filled in by the instance:

```lisp
(type square
  (arrow row (to row-t)  fixed)      ; which row this square is on
  (arrow da  (to diag-t) fixed)      ; the ↘ diagonal through it
  (arrow db  (to diag-t) fixed))     ; the ↗ diagonal through it
```

Diagonals are ordinary entities, `d1`…`d15`. "These two queens share a
diagonal" is then just `is`. No arithmetic is needed and none is smuggled in:
|Δrow| = |Δcol| is never *computed*, it is *looked up*, because the table is
small and fully known — which is Pivotal idea 3 doing exactly the work it
exists to do.

That one decision collapses the *guards*. Safety stops being seven
distance-indexed forms and becomes **one**, quantified over queens instead of
enumerated per column:

```lisp
(form (free B S)
  => (all (B queen)
       (and (differ B.at.row S.row) (differ B.at.da S.da) (differ B.at.db S.db))))
```

An unplaced queen blocks nothing, and that too is free rather than arranged:
its `at` is vacant, so `B.at.row` has no answer, `is` is strict, and `differ`
is therefore true.

## The second idea: don't say which queen

Naming the diagonals shortens every guard but leaves sixty-four moves — one per
square — because a move has to say which queen it places. **A cursor says it
instead.**

```lisp
(form (fill N S)
  => (transition N
       (when (and (not (defined cur.q.at)) (free p S)))
       (do (set cur.q.at S) (set cur.q cur.q.next))))

(fill place-1 cur.q.sq1)   ; …and seven more. That is the entire move set.
```

**Eight moves, not sixty-four.** The moves index *rows*; which column they fill
is whatever `cur` currently points at, and each move advances it. Column order
is then enforced by construction rather than by a conjunct in every guard.

This needs both halves of the §10.3 widening and it is the reason that widening
earned its place:

- `set` takes a **chain**, so the cursor walks itself: `(set cur.q cur.q.next)`.
- Effects are **simultaneous** (§10.1), so `(set cur.q.at S)` still writes the
  queen the cursor named when the move *began*, not the one it has just moved
  to. Write the two effects in either order and the space is identical — and
  that is asserted, because it was not true when this model was first built.
  Getting it wrong gave 9 situations instead of 2057, which is what found the
  bug: the right-hand sides were read at the start but the *target path* was
  walked at write time, so order was observable through the left side.

The ring closes the model neatly. After `q8` the cursor lands back on `q1`,
which is already placed, so nothing is enabled — a finished board is a **dead
end**, which is precisely what a finished board should be.

### What the two steps replaced

The previous version walked. Rows were entities on a **ladder** — `next`
climbed, `prev` descended — so the square a queen *d* columns away attacks was
`R.next` walked *d* times, which needed one `safeN` form per distance and a
seven-conjunct guard per move:

```lisp
(transition place-3-5
  (when (and (not (defined q3.row)) (defined q2.row)
             (safe2 q1.row r5) (safe1 q2.row r5)
             (safe1 q4.row r5) (safe2 q5.row r5)
             (safe3 q6.row r5) (safe4 q7.row r5)
             (safe5 q8.row r5)))
  (do (set q3.row r5)))
```

| | lines | moves | forms | per-move guard |
| --- | --- | --- | --- | --- |
| ladder version | 468 | 64 | 7 `safeN` | 7–8 conjuncts |
| named diagonals | 119 | 64 | 1 `free` | 3 conjuncts, quantified |
| …plus the cursor | 83 | **8** | 2 | 3 conjuncts, quantified |
| …board split into the library | **15** + 69 shared | 8 | 1 + 1 shared | 3 conjuncts, quantified |

Same 2057 situations, same 2056 edges, same 736 dead ends, same 92 boards at
every step. Nothing about the space moved through any of it.

The last row is bookkeeping rather than a saving: 15 + 69 is not fewer lines
than 83. What it buys is that the 69 are shared — the two models together went
from 167 lines to 104 — and that a reader opening `queens.pol` sees eight moves
and nothing else.

The two ideas are independent and it is worth keeping them apart. **Naming the
diagonals** is a *data* change and needs no language feature — it would have
worked years ago. **The cursor** is what needs §10.3, and it is the one that
removes the sixty-four.

### What is left, and why

Eight `(fill …)` lines and a table of instance data. The data is genuinely
irreducible — it is the board — and eight moves is one per row, which is the
puzzle's own shape.

The remaining awkwardness is that `sq1`…`sq8` are eight separate arrows where
one indexed arrow would do. Pol has no indexed arrow, deliberately: an arrow
is a function with a name, not an array. Writing the board column-wise makes
the data read as a table, which is the best available answer.

## The optimisation that worked: order the placements

`queens.pol` and `queens-unordered.pol` describe the same puzzle and have the
same 92 solutions. The unordered one lets any column be filled at any time.

| | moves | situations | `pol check` |
| --- | --- | --- | --- |
| `queens-unordered.pol` | 64 | 118 969 | 30 s |
| `queens.pol` | 8 | 2 057 | 0.2 s |

Nothing about legality changed. What changed is what the space *holds*: every
safe **subset** of columns, versus every safe **prefix**. The subsets are the
same boards reached by every order of arrival, and the search pays for each
permutation. Fifty-eight times fewer situations.

Ordering used to be one conjunct. It is now the difference between having a
cursor and not: **a cursor can only exist if there is an order to advance
along**, so committing to column order buys the 8-move model as well as the
58× — the same decision paying twice.

The unordered file is not ugly about it. Its sixty-four moves are written as
eight `(column …)` lines, and the square is never named, because `Q.sqN` is the
square:

```lisp
(form (column Q N1 N2 N3 N4 N5 N6 N7 N8)
  => (transition N1 (when (and (not (defined Q.at)) (free p Q.sq1))) (do (set Q.at Q.sq1)))
     …)

(column q3 p31 p32 p33 p34 p35 p36 p37 p38)
```

That is §10.3's chain earning its place a second time — and the names are kept
rather than letting the transitions go anonymous, because a route then reads
`p11, p23, p35, …`, which *is* the board. But sixty-four moves is what the
model **has**, however few lines declare them, and that is the thing being
measured.

Worth noting against §14: the unordered space is 118 969 situations, which
is *under* the 200 000 an implementation is permitted to cap at. So the
spec's stated ceiling is not the real one — a model becomes unusable well
before it trips the limit that is supposed to catch it.

## The optimisation that mattered most: profile before optimising

Three plausible engine fixes were tried on this puzzle. Two bought nothing
and one bought 13×, and the difference was not intuition — it was measuring
instead of reasoning.

Timing `pol check` by phase on a 16 870-situation model settled it at once:

```
[load]      8 ms
[space]  2 059 ms     ← enumerating 16 870 situations and 68 703 edges
[report] 30 804 ms    ← everything after
```

The **search was never the problem.** `Space.dead_ends` asked, for each
situation, whether any edge left it — by filtering the whole edge list:

```ocaml
let enabled_of t s = List.filter (fun e -> same e.src s) t.edges
```

16 870 situations × 68 703 edges is 1.16 **billion** comparisons. One pass
over the edges answers the same question, and report time fell to 2 348 ms.
A second, smaller fix went with it: `shortest_path` rediscovered each route
by scanning every edge for a predecessor, when the BFS already knew the
parent of every situation it discovered — worth 18% on its own.

| | before | after |
| --- | --- | --- |
| 16 870 situations | 30.8 s | 2.3 s |
| 118 969 situations | did not finish in 10 min | 30 s |

*(Those figures were measured on the ladder version. The situation counts are
unchanged by the rewrite, so the comparison still stands; git has the file.)*

## The optimisations that did not work

Recorded because two plausible ideas measured to nothing, and knowing which
ideas are wrong is worth as much as the one that was right.

`State.index_of` maps a cell reference to its slot in the state vector by
**scanning** the layout:

```ocaml
if cells.(i) = cr then Some i else go (i + 1)
```

It is called on every step of every chain, in every guard, of every
transition, at every reachable situation — the innermost operation the
engine has. Replacing it with a hashtable built once at `build_ctx` is the
obvious fix, and the arithmetic is persuasive: 119 000 situations × 64 moves
× ~40 conjuncts × 8 cells is billions of record comparisons.

It made no difference. Measured on 6-queens, with the layout padded by
single-valued cells so the search is identical and only the layout grows:

| layout | linear scan | hashtable |
| --- | --- | --- |
| 6 cells | 579 ms | 559 ms |
| 406 cells | 1017 ms | 1060 ms |

At 406 cells a scan averages 200 comparisons against one hash, and the
hashtable is *marginally slower*. So `index_of` was never hot, and the
change was reverted rather than kept as complexity that buys nothing.

Two things the numbers do say. The padding experiment does not isolate what
it was meant to: cells **are** the state vector, so adding 400 of them grows
every state copied and every state compared — which is where that 2× came
from, not from scanning. And the real cost is elsewhere, plausibly in state
copying and the sheer edge count, which no lookup-table change touches.

## A third thing that did not work: walking

Once `set` took a chain, the obvious move was to let a queen **walk** its
column — `(set q3.at q3.at.up)` — turning 64 moves into 16. It was built and
measured, and it is worse on every axis that matters:

| | lines | situations | 92 boards visible? |
| --- | --- | --- | --- |
| placing (shipped) | 119 | 2 057 | **yes** |
| walking | 80 | 15 721 | **no** |

Two costs, one fatal. A walking queen passes *through* unsafe squares, so the
space grows 7.6×. And a complete board stops being a **dead end** — the queen
can always step again — which destroys the nicest thing this example
demonstrates: that `pol check`'s dead-end list *is* the solution set, all 92 of
them, with no query needed. The unordered walk variant does not even build; it
exceeds the 200 000 cap.

The general lesson is worth more than the puzzle: `set`-with-a-chain suits a
**clock**, which has one walker and a well-defined end, and not a **search**,
which needs branching *and* needs "no move left" to mean "solved".

## Files

- [`../libraries/chess.lib.pol`](../libraries/chess.lib.pol) — the domain
  library both models load: the board, and the `free` test over it. No moves.
  See [`../libraries/README.md`](../libraries/README.md).
- `queens.pol` — column-ordered, 2 057 situations. What the runner exercises.
- `queens-unordered.pol` — the same board without the ordering commitment, so
  no cursor and sixty-four moves (in eight lines). Kept as the measured
  contrast; **not** run by the test suite, because it takes ~30 s where the
  ordered model takes a fifth of a second.
- `queens.claims` — the question, kept apart from the puzzle (wish 12).
- `queens.rules` — the same question re-asked of the rules engine, so the
  cross-check oracle compares two implementations of one question.
