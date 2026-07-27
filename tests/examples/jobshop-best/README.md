# The same job shop — which schedule is shortest?

*This is one of a pair. Next door in
[`../jobshop-possible/`](../jobshop-possible/): **can** every job finish, and
which schedules seize. Here: **which** schedule is best. Read that one first —
it explains the shop, the blocking rule, and the deadlock.*

The shop is identical: three jobs, three machines, routings in a cycle, no
buffers. The only new thing is a **clock**.

```
fails  done-by-4
holds  done-by-5
  witness:  1. a-enters   2. b-enters   3. tick-1
            4. b-advances 5. a-advances 6. tick-2
            7. a-leaves   8. b-leaves   9. c-enters  10. tick-3
            11. c-advances  12. tick-4  13. c-leaves
```

**Five ticks, and not four.** That is the optimal makespan, and the witness is
the schedule that achieves it.

## How you get a "best" out of a language with no numbers

Pol has no arithmetic, so a duration cannot be added up and a makespan cannot
be computed. But Appendix G's escape clause is exact about the way round it:

> quantities and arithmetic … out of scope, **unless honestly reduced to small
> named scales**

A clock is precisely that. Ticks are **entities on a ladder** — `t1 → t2 → …`,
walked by `next` — the same construction the queens model uses for rows. One
extra arrow per job, `moved`, records whether that job has already acted in the
current tick; `tick-N` advances the clock and resets every flag. An operation
therefore occupies exactly one tick, without a single number being added.

With time in the model, this becomes an ordinary question:

```lisp
(property done-by-5 "every job finished by tick 5"
  (possible (and (all (j job) (is j.stage done)) (is clk.at t5))))
```

And then the trick that makes it an *optimisation*:

> Ask it for decreasing N. **The smallest N that holds is the optimum**, and
> its witness is the optimal schedule.

That is how you optimise with a decision procedure — repeated feasibility
rather than a cost function — and it is why the claims file asks exactly two
questions. `done-by-4` **fails** and `done-by-5` **holds**, which pins the
answer from both sides. One that fails and one that holds is a *proof* of
optimality, where either alone would only be a bound.

## Read the optimal schedule against the other model

The schedule starts `a` and `b` together and **holds `c` back** until they are
clear. That is not an accident of search order — it is forced, and the model
next door is what proves it: the only situation in which all three machines are
busy **is** the deadlock. Full utilisation is never survivable here, so the
best schedule is the one that overlaps exactly two jobs and no more.

Neither model can tell you that alone. `jobshop-possible` shows the trap;
`jobshop-best` shows the fastest route around it; and it is the same fact seen
from two directions.

## What it costs

**Time is expensive.** The same three jobs go from 51 situations to **1314**,
because the space now carries the clock and a `moved` flag per job. That is the
price of asking about time, and it is the argument for keeping the untimed
model around rather than replacing it: ask the cheap question first, and only
pay for the clock when the answer you need is a duration.

It will also not scale like a real solver. Nine ticks and three jobs is
comfortable; a shop floor is not. The honest positioning is that Pol gives you
an *optimal* answer with a *proof* on small instances, where a solver gives you
a good answer fast on large ones.

**The clock is advanced by one transition per tick**, because `set` takes a
literal value. What this model wants to write is

```lisp
(do (set clk.at clk.at.next) …)
```

and cannot — a chain on the right of `set`. That is
[`docs/set-as-chain.md`](../../../docs/set-as-chain.md), and this is the third
independent model to ask for it.

## Files

- `jobshop-best.pol` — the shop plus a clock. Nine ticks available.
- `jobshop-best.claims` — the two bounds that pin the optimum.
- `jobshop-best.rules` — both, re-asked of the rules engine, so the cross-check
  oracle compares two implementations of one question.
