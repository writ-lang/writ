# A blocking job shop — and what Pol is actually good at

Three jobs, three machines, routed in a cycle: `a` goes m1→m2, `b` goes m2→m3,
`c` goes m3→m1. **Blocking** means no buffers — a job holds the machine it is
on until it has *acquired* the next one. That hold-and-wait is the whole point:
without it a job shop cannot deadlock, and with it this one can.

`pol check` answers both halves of the question:

```
holds  all-finish        witness: a-enters a-advances a-leaves b-enters …
fails  never-stuck
  stuck at: (m1.held-by=a m2.held-by=b m3.held-by=c
             a.stage=on-first b.stage=on-first c.stage=on-first)
  witness:  1. a-enters   2. b-enters   3. c-enters
```

Three moves into a circular wait, with the deadlocked state named in full.
Each job holds the machine the next one is waiting for:

![The deadlock: each job holds one machine and waits for the next, in a cycle](../../../docs/diagrams/jobshop-deadlock.svg)

Solid is *holds*, dashed is *waited for*. Follow either kind of arrow all the
way round and you return where you started — that cycle **is** the deadlock,
and it is what `never-stuck` failing means. Break it anywhere and the shop
runs: give one job a buffer, reverse one routing, or release the first machine
before acquiring the second, and the cycle cannot close.

## Why this is the right shape of question for Pol

`all-finish` **holds** — some schedule finishes everything. On its own that is
close to worthless, and the pair is the lesson: a `possible` that holds tells
you a good schedule exists and says *nothing* about the bad ones you can walk
into first. `never-stuck` is the Prologue's wish 8, the trap detector, and it
is the question a scheduler actually needs answered.

**What is deliberately not modelled: durations, and therefore makespan.** Those
are arithmetic and Pol has none (Pivotal idea 3). That sounds like a crippling
omission for scheduling and mostly is not — the classical hard question about a
*blocking* shop is not how long a schedule takes but whether one exists at all,
and that is pure reachability. Appendix G's "unless honestly reduced to small
named scales" is the honest boundary: ask Pol about deadlock, ask a solver
about makespan.

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

- `jobshop.pol` — the shop. Three forms, one line per job.
- `jobshop.claims` — the two questions, kept next door (wish 12).
- `jobshop.rules` — the same two, re-asked of the rules engine, so the
  cross-check oracle can compare two implementations of one question. Note the
  polarity comment: `live` is encoded as its **counterexample set**, and
  writing it the other way round would invert the oracle silently.
