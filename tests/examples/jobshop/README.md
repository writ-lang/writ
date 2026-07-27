# A blocking job shop — and what Pol is actually good at

## The problem, from the beginning

A **job shop** is a workshop. Several *jobs* are in progress at once, and each
one needs to visit several *machines* — but each job visits them **in its own
order**. A machine does one thing at a time.

That last pair is the whole difficulty — and it is worth seeing why, because
the difficulty is *not* that machines are shared. It is that the **orders
differ**.

Here are two shops. Both have three jobs, both have the blocking rule below,
both are otherwise the same file:

**Shop A** — every job takes the machines in the same order:

| job | first | then |
| --- | --- | --- |
| `a` | m1 | m2 |
| `b` | m1 | m2 |
| `c` | m1 | m2 |

**Shop B** — each job has its own order:

| job | first | then |
| --- | --- | --- |
| `a` | m1 | m2 |
| `b` | m2 | m3 |
| `c` | m3 | m1 |

In **Shop A** the jobs queue. They contend for m1, one wins, the others wait —
but every job is trying to go the same way through the shop, so the one in
front is always the one that can move. There is congestion and no dilemma.

In **Shop B** read down the columns: the routings chase each other in a
**cycle**. `a` wants what `c` starts on, `b` wants what `a` starts on, `c`
wants what `b` starts on. Now who goes first is a real decision, and some
answers are unrecoverable.

That is not a claim you have to take on trust — both shops are in this
directory, and `pol` answers them differently:

```
jobshop-samerouting.pol   holds  never-stuck     (exit 0)
jobshop.pol               fails  never-stuck     (exit 1)
```

`diff` the two files and you get **exactly two lines**, both of them the
routing table:

```diff
-  (first  (a m1) (b m2) (c m3))
-  (second (a m2) (b m3) (c m1))
+  (first  (a m1) (b m1) (c m1))
+  (second (a m2) (b m2) (c m2))
```

Same blocking rule, same jobs, same machines — `m3` simply sits idle in Shop A —
same forms, same questions. Take the cycle out and the deadlock goes with it.

## What "blocking" means, and why it is the interesting case

In a textbook job shop, a job that finishes on a machine steps off it and waits
somewhere for the next one. That "somewhere" is a **buffer** — floor space, a
pallet, a queue.

A **blocking** shop has no buffers. There is nowhere to put a part down, so a
job **cannot leave a machine until it has acquired the next one**. It holds
what it has while it waits for what it needs.

This is not an exotic assumption. It is what you get when the part is bolted
into a fixture, or too heavy to set down, or when a robot arm can only move a
part machine-to-machine. It is also the assumption that makes the shop
*dangerous*, because "hold what you have while waiting for more" is exactly the
condition under which a system can seize.

## Deadlock

Suppose all three jobs start at once. Each takes its first machine — all legal,
all sensible, nothing has gone wrong yet:

- `a` holds m1, and needs m2
- `b` holds m2, and needs m3
- `c` holds m3, and needs m1

Now nobody can move. `a` waits on `b`, `b` waits on `c`, `c` waits on `a`. No
job will ever release a machine, because releasing requires first acquiring the
next one. The shop is stopped **forever**, and no amount of waiting fixes it.

![The deadlock: each job holds one machine and waits for the next, in a cycle](../../../docs/diagrams/jobshop-deadlock.svg)

Solid is *holds*, dashed is *waited for*. Follow either kind of arrow all the
way round and you return where you started — that cycle **is** the deadlock.
Break it anywhere and the shop runs: give one job a buffer, reverse one
routing, or release the first machine before acquiring the second, and the
cycle cannot close.

The unnerving part is that nothing illegal happened. Every single move was
allowed. The shop walked into the trap three correct decisions at a time, and
that is precisely the kind of failure a human reading the routings will miss.

## What Pol is asked, and what it answers

Two questions, which sound similar and are not:

1. **Is there a schedule that finishes every job?** — `possible`
2. **From *every* situation the shop can reach, can every job *still* finish?**
   — `live`

```
holds  all-finish        witness: a-enters a-advances a-leaves b-enters …
fails  never-stuck
  stuck at: (m1.held-by=a m2.held-by=b m3.held-by=c
             a.stage=on-first b.stage=on-first c.stage=on-first)
  witness:  1. a-enters   2. b-enters   3. c-enters
```

The first **holds** — a good schedule exists, and Pol prints one: run the jobs
one after another and nothing collides.

The second **fails**, and that is the answer worth having. Pol names the
deadlocked situation in full, and gives the three moves that reach it. Not "a
deadlock is possible in principle" — *this* state, by *these* moves.

**Answering the first question alone would be actively misleading.** "Yes, the
shop can finish everything" is true and useless, because it says nothing about
the schedules you can blunder into first. That gap between `possible` and
`live` is the Prologue's wish 8, and it is the reason this example is here.

## What is deliberately missing: time

A real scheduler wants to know how *long* a schedule takes — the **makespan** —
and each operation has a duration. **None of that is modelled here, and none of
it can be.** Durations are numbers, and Pol has none (Pivotal idea 3): there is
no arithmetic, no ordering, no way to add two quantities.

That sounds like a crippling omission for a scheduling example, and mostly it
is not. Notice which question the deadlock above turned on: **none of it
involved time.** The shop seizes because of the *shape* of the routings, and it
would seize identically whether each operation took a minute or a week. Making
the machines faster does not help; nothing helps, because no job will ever
release anything.

So the division is clean, and it is worth stating as a rule of thumb:

> Ask Pol whether a schedule **exists**. Ask a solver how **long** it takes.

Appendix G draws the same line — "quantities and arithmetic … out of scope,
unless honestly reduced to small named scales". A blocking shop's hardest
question happens to fall on Pol's side of it.

## What it taught us about the language

The models here and in `../queens/` are duplicated in different shapes, and the
difference decides what sugar can do:

| | duplicated over | can a form collapse it? |
| --- | --- | --- |
| queens | (queen, **row**) — 64 moves | **no** — `set` writes a literal, so each row needs its own move |
| job shop | (job) — 3 moves each | **yes** — one `(job-of …)` line per job |

Adding a fourth job here is **one line**. Adding a ninth row to queens is eight
more transitions. Both are "the model is repetitive", and only one of them is a
sugar problem.

**A form-generated transition is anonymous**, which the `N` slot in each form
exists to fix. Without it the deadlock witness reads `#0 #3 #6` — the trace is
correct and unreadable, which is the worst combination for the one output a
`live` failure exists to produce. Passing the move's name as a slot costs an
argument per invocation and nobody would discover it unaided; it is the reason
`(job-of a a-enters a-advances a-leaves)` looks the way it does.

**At scale, this model wants what queens wants.** Two operations per job fit in
named stages. A real routing is *n* operations, which wants a cursor walking the
job's chain — `(set j.cursor j.cursor.next)` — and `set` takes a literal.
That is `docs/set-as-chain.md`, arrived at here from a domain rather than from a
puzzle, which is the evidence that note asked for before recommending anything.

## Files

- `jobshop.pol` — the shop, with the cycle. Three forms, one line per job.
- `jobshop-samerouting.pol` — the same file with every job routed m1→m2, so
  there is no cycle to close. `never-stuck` holds. It differs from
  `jobshop.pol` by two lines and exists to make the claim above checkable
  rather than asserted; the test suite asserts both verdicts.
- `jobshop.claims` — the two questions, kept next door (wish 12).
- `jobshop.rules` — the same two, re-asked of the rules engine, so the
  cross-check oracle can compare two implementations of one question. Note the
  polarity comment: `live` is encoded as its **counterexample set**, and
  writing it the other way round would invert the oracle silently.
