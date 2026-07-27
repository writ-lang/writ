# Eight queens — and what made it tractable

Eight queens on a board, none attacking another. `pol check queens.pol
--claims queens.claims` answers it in well under a second, and the witness
under the holding `solvable` **is** a solution — the eight moves that place
the queens.

This scenario is here for two reasons. It is the first puzzle Pol can state
that it could not state before, and it is the clearest measurement in the
repository of *which* optimisation matters.

## What the model can and cannot say

**Columns** are not constrained, they are unrepresentable: queen `q3` **is**
the queen of column 3, so no two queens can share one. Building the
constraint into the data is the oldest trick in the puzzle and it costs
nothing here.

**Rows** are said directly:

```lisp
(differ q1.row q2.row)
```

Which the language could not express until §8.6 let a law hold a guard and
`differ` joined the standard library. Before that, `is` took a literal on
the right and "two queens share a row" had no spelling at all.

**Diagonals** are said, not enumerated — which took one modelling decision.
`|Δrow| = |Δcol|` is arithmetic and Pol has none (Pivotal idea 3), so the
first version of this model listed the forbidden rows as literals and read
like a wall:

```lisp
(when (and (not (defined q3.row)) (defined q2.row)
           (differ q1.row r3) (differ q1.row r5) (differ q1.row r7)
           (differ q2.row r4) (differ q2.row r5) (differ q2.row r6)
           … 20 conjuncts …))
```

Make rows **entities on a ladder** instead of an enumerated set — `next`
climbs, `prev` descends, both running off the board into `vacant` — and the
square a queen *d* columns away attacks is just `R.next` walked *d* times.
Name the three-way test once per distance and the same transition becomes:

```lisp
(transition place-3-5
  (when (and (not (defined q3.row)) (defined q2.row)
             (safe2 q1.row r5) (safe1 q2.row r5)
             (safe1 q4.row r5) (safe2 q5.row r5)
             (safe3 q6.row r5) (safe4 q7.row r5)
             (safe5 q8.row r5)))
  (do (set q3.row r5)))
```

Nine conjuncts against twenty, and each says what it means: *the queen two
columns away is safe from a queen at r5*. Two language facts make it work. A
form's slot substitutes into a chain's **root**, so `R.next.next` becomes
`r5.next.next` at the call site. And running off the board leaves the chain
undefined, where `is` is strict — so `differ` is true and the board's edge
constrains nothing, which is exactly right and costs nothing to arrange.

The files are still **generated**, because there is one move per (column,
row) and sixty-four of those is not something to type. But that is a
consequence of the move set, not of the arithmetic.

## The optimisation that worked: order the placements

`queens.pol` and `queens-unordered.pol` describe the same puzzle and have
the same 92 solutions. They differ by **one conjunct**:

```lisp
(defined q7.row)     ; column 8 may only be filled once column 7 is
```

| | situations | `pol check` |
| --- | --- | --- |
| `queens-unordered.pol` | 118 969 | 26 s |
| `queens.pol` | 2 057 | under a second |

*(The unordered figure was "did not finish in ten minutes" when this was
written. Chasing that number is what found the engine bug below; the model is
unchanged, the engine is 13× faster, and the ordering still buys 58×.)*

Nothing about legality changed. What changed is what the space *holds*:
every safe **subset** of columns, versus every safe **prefix**. The subsets
are the same boards reached by every order of arrival, and the search pays
for each permutation. Fifty-eight times fewer situations, and the difference
between "never" and "instant".

Worth noting against §14: the unordered space is 118 969 situations, which
is *under* the 200 000 an implementation is permitted to cap at. So the
spec's stated ceiling is not the real one — a model becomes unusable well
before it trips the limit that is supposed to catch it.

## The optimisation that mattered most: profile before optimising

Three plausible engine fixes were tried on this puzzle. Two bought nothing
and one bought 13×, and the difference was not intuition — it was measuring
instead of reasoning.

Timing `pol check` by phase on the 16 870-situation model settled it at once:

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
| 118 969 situations | did not finish in 10 min | 26 s |

Both models still report 92 complete boards.

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
copying and the sheer edge count (8 980 edges for 6 queens), which no
lookup-table change touches.

**What the three halves teach together.** The model-level change bought 58×.
Two engine changes chosen by reading the code bought nothing. One engine
change chosen by timing the phases bought 13×. When a Pol model is slow, ask
what the *space* holds first — and if you must touch the engine, measure
where the time goes before deciding what to fix, because the innermost
operation is not reliably the expensive one.

## Files

- `queens.pol` — column-ordered, 2 057 situations. What the runner exercises.
- `queens-unordered.pol` — the same puzzle without the ordering conjunct.
  Kept as the measured contrast; **not** run by the test suite, because it
  does not finish.
- `queens.claims` — the question, kept apart from the puzzle (wish 12).
