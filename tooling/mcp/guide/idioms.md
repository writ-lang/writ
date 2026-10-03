Modelling patterns. A model that parses can still ask the wrong question; most mistakes are here, not in the syntax.

## Concurrency

- **One move is one atomic step.** Whatever a real system does indivisibly (a test-and-set, a transaction) is one move; whatever it does in separate steps (read, then write) must be separate moves, or the model hides the race. `examples.mutex` is exactly this.
- **N identical workers**: write one form taking the worker and its move names, and call it once per worker (`examples.webhooks`). Interleaving is automatic: every enabled move of every worker is explored at every step.
- **Use the fewest workers that show the behaviour.** Two exhibit any race or mutual-exclusion bug; a third rarely adds one. Identical workers multiply the space by symmetric copies (w1 holds the job, or w2 does) and writ does not merge them.
- **Guard every move on the state it changes.** A move that can fire again after doing its job is a self-loop that doubles edges and hides dead ends: `(when (and (is b.acked yes) (is a.role leader)))`, not `(when (is b.acked yes))`.

## Messaging

Give each message its own stage cell; a consumer takes any queued one, so every delivery order is explored. These are small patterns, combine them:

```lisp
; duplicate delivery (at-least-once): a handled message can arrive again
(transition redeliver (when (is m.stage done)) (do (set m.stage queued)))
; loss: a sent message can vanish
(transition lose (when (is m.stage sent)) (do (set m.stage lost)))
; bounded retries: m.tries walks a ladder r0 -> r1 -> r2; at the end the
; retry is absent and only giving up is left
(transition retry (when (is m.stage lost))
  (do (set m.stage sent) (set m.tries m.tries.next)))
(transition give-up (when (and (is m.stage lost) (not (defined m.tries.next))))
  (do (set m.stage failed)))
```

- **Reordering** is free with one cell per message. To model a FIFO channel, guard taking `m2` on `m1` already taken.
- **An idempotency key** is a cell the handler sets the first time and tests after (`examples.consumer`).

## Time

There are no clocks. A timeout, an expiry or a crash is a move that is enabled whenever it could happen, so writ explores it firing at every possible moment:

```lisp
(transition timeout (when (is req.stage waiting)) (do (set req.stage expired)))
(transition lease-expires (when (defined l.holder)) (do (vacate l.holder)))
```

Add a ladder of ticks only when the order of two deadlines matters.

## Counters

A count is a ladder of entities walked by a fixed vacatable arrow, never a number:

```lisp
(type count (arrow next (to count) fixed vacatable))
(instance … (count c0 c1 c2) (next (c0 c1) (c1 c2) (c2 vacant)) …)
(transition charge (when …) (do (set acct.charges acct.charges.next)))
```

At the top of the ladder `acct.charges.next` has no answer, so `charge` is absent: the counter saturates by blocking. That block is the bound, not the system, and it shows up as a dead end or a stuck run. Make the ladder one step longer than the question needs (to ask "never charged twice", count to `c2`) and read a dead end at the top as the bound. For a cheap counter, prefer a small enum `(none one many)`.

## History

A property that mentions order ("never captured *after* voided") needs a cell that remembers: set a flag when the first event happens and test it with the second, as in `(never (and (is o.was-voided yes) (is o.status captured)))`. A history cell multiplies the space by its domain, so keep it two-valued.

## Abstraction and size

- The space is at most the product of every mutable cell's domain (plus one for vacatable cells). `writ_validate` prints the bound. Keep it under about 100000 for a check in seconds; the hard default is 200000 situations.
- Leave out everything no property reads: amounts become buckets (`(small large)`), identifiers become one entity per role, and payloads disappear.
- Model one instance of the thing at risk (one order, one message) and two of the things that race over it.
- Make wiring `fixed`: a fixed arrow costs nothing.
- When writ reports `E_STATE_LIMIT`, read its growth list: the cells that took the most values are the ones to shrink.

## Asking the right question

| requirement | property |
| --- | --- |
| "X must never happen" | `(never X)` |
| "P always holds" | `(never (not P))` |
| "it is possible to X"; "find a schedule" | `(possible X)` (the witness is the schedule) |
| "it can always recover"; "no trap"; "can always still finish" | `(live X)` |
| "it eventually finishes"; "it terminates" | `(inevitable X)` |
| "it finishes provided the retry is not refused for ever" | `(inevitable X (fair retry))` |
| "every ending is a good one" | `(inevitable GOOD-ENDING)` |

`live` and `inevitable` part company exactly where a system can loop for ever without being stuck: the retry that is always possible but need never succeed. Ask `live` for a capability that must not be lost and `inevitable` for an outcome that must be delivered. If `inevitable` fails only through a loop of retries, the honest fix is often the fairness assumption, stated, not a change to the model.

## The regression loop

1. Check the model; keep the claims fixed.
2. Edit the model to fix a failure.
3. `writ_compare` the old model against the new (or re-check with the same `model_name`). A LOST row is a guarantee the edit broke, with its route; an edit that fixes one property by losing another is not a fix (`examples.handoff`).
4. Never edit a claim to make it pass, and never delete what a claim asks about: `n/a` counts as LOST.
