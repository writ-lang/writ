# Should `set` take a chain? — a design note

*Status: proposal, nothing implemented. The symmetric twin of
`docs/law-as-guard.md`, which widened `is`; this asks whether `set` should be
widened the same way. It carries a real cost that `is` did not, and the note
does not resolve it.*

**The change in one line:** `(set CHAIN V)` accepts a **chain** on the right,
not only a literal — exactly as `(is CHAIN RHS)` now does (§10.2).

## Where the question came from

Eight queens, written in Pol, is 561 generated lines. The reason is not the
one it looks like.

Diagonals are *not* the problem — those were solved by modelling rows as a
ladder, so `R.next.next` says "two rows up" and no arithmetic is needed
(`tests/examples/queens/README.md`). What remains is that there is one
transition per **(column, row)** pair — sixty-four of them — and that floor
is set by a single sentence in §10.3:

> `(set CHAIN V)` — writes the slot named by the chain's last step … V in the
> target domain

V is a literal. A move can write `q3.row := r5`, but it cannot write
`q3.row := q3.row.next`. So a queen cannot *walk* the board; it can only be
placed on a named square, and every named square needs its own move.

Forms do not rescue it. A form may expand to several transitions, but it
cannot map over a `&rest` capture — §10.2's design note says so, and for a
good reason: the same power would let De Morgan rewrite `or`, which the
kernel deliberately withholds. So `(place-all q3 r1 … r8)` is unwritable, and
**no library can lower the floor.**

With a chain permitted, the whole model collapses:

```lisp
(form (adv Q) => (transition (when (defined Q.at)) (do (set Q.at Q.at.next))))
(adv q1) (adv q2) (adv q3) (adv q4) (adv q5) (adv q6) (adv q7) (adv q8)
```

Eight moves rather than sixty-four, and the puzzle fits in twenty lines.

## Why this is not simply "do what `is` did"

Widening `is` was cheap because `is` **reads**. Both sides are evaluated in
one situation and nothing changes underneath them. `set` **writes**, and that
makes three questions real that the `is` change never had to answer.

### 1. When is the right-hand side read?

`(do (set a.x b.y) (set b.y a.x))` is a swap if both right-hand sides are read
in the situation the move *started* from, and is not a swap if the second
`set` sees what the first one wrote.

§10.1 says effects are "applied atomically: no situation exists *between* two
effects of one move", which sounds like it settles the question — but it is a
statement about what the *space* contains, not about what an effect *reads*.
Today the distinction is unobservable, because no effect reads anything. The
moment one does, §10.1 needs a sentence it does not currently have.

The defensible answer is **read the starting situation**: it makes a `do`
block a simultaneous assignment, it matches what "no situation exists between"
already suggests, and it makes the order of effects within a move irrelevant —
which is worth keeping, since nothing today can detect that order.

The cost is that `Eval.apply` currently threads the state through the effects
one at a time, which is exactly the sequential reading. So this is a real
change to the evaluator, not a parser widening.

### 2. What if the chain has no answer?

`(set q.at q.at.next)` at the top of the ladder reads a vacant cell. The
options are to make the effect a no-op, to vacate the target, or to reject the
move.

§8.3 already forbids writing `vacant` through `set` — that is what `vacate`
is for, and the design note says why: `vacant` is not a member of the target
type. So "vacate the target" would smuggle in exactly what that rule
excludes. **No-op** and **not enabled** are both defensible; they differ in
whether a queen at the top of the board can still move, which is precisely the
kind of thing a modeller must be able to say out loud rather than discover.

### 3. Does the situation space stay finite?

Yes, and this is the one easy answer. A chain-valued `set` writes a value that
already exists in some cell, so it cannot invent members, and §12.1's space is
still the product of finitely many finite domains. Pivotal idea 3 is untouched.

## What it would cost, and what it would buy

**Buy.** A whole class of models stops being generated text: anything that
*moves* a value rather than assigning a named one — a ladder, a counter over a
named scale, a token passed along a chain of offices. `pol control`'s output
would shrink for the same reason. And the language would stop being asymmetric
in a way that is hard to justify to a reader: `is` compares a chain to a chain,
`set` cannot assign one.

**Cost.** One evaluator change (simultaneous read), one semantic decision
(undefined right-hand side), one sentence in §10.1 and one in §10.3. No new
kernel word — this is a widening, like `is`, so the count stays at
twenty-seven.

## Recommendation

**Not yet, and not on the strength of a puzzle.** Eight queens is a bad
witness for a language change: it is the case Appendix G already calls out as
needing "small named scales", and it is not what Pol is for.

The argument that would justify it is the *asymmetry* — that a reader who has
just learnt `(is a.x b.y)` will reasonably write `(set a.x b.y)` and be
refused. If that lands as a wart in practice, this note is the design; if it
never comes up, the floor on generated moves is a cost only puzzle models pay.

Worth revisiting when a **domain** model wants it — a token moving along a
delegation chain is the shape to watch for. Until then the honest position is
that the language is asymmetric on purpose, and that the reason is that
writing is harder than reading.
