A consumer charges a customer for a message, then acks it. The ack can be lost, in which case the broker times out and redelivers. Charges are counted on a ladder `c0 → c1 → c2` (`idioms`, Counters), so "never charged twice" is `(never (is acct.charges c2))`. Termination is asked twice: plainly, and assuming an offered `ack` is not refused for ever.

```lisp file=consumer.writ
(load "stdlib.writ")
(schema billing
  (type stage-t (queued delivered processed acked))
  (type count (arrow next (to count) fixed vacatable))   ; a ladder, not a number
  (type message (arrow stage (to stage-t)))
  (type account (arrow charges (to count))))
(instance start billing
  (count c0 c1 c2)
  (next (c0 c1) (c1 c2) (c2 vacant))
  (message m (stage queued))
  (account acct (charges c0)))
(use billing)
(initial start)

(transition deliver (when (is m.stage queued)) (do (set m.stage delivered)))
(transition process (when (is m.stage delivered))
  (do (set acct.charges acct.charges.next) (set m.stage processed)))
(transition ack (when (is m.stage processed)) (do (set m.stage acked)))
; The ack can be lost: the broker times out and redelivers.
(transition timeout (when (is m.stage processed)) (do (set m.stage queued)))
```

```lisp file=consumer.claims
(property charged-once "the customer is never charged twice"
  (never (is acct.charges c2)))
(property finishes "every run acks the message"
  (inevitable (is m.stage acked)))
(property finishes-fairly "it does, if an offered ack is not refused for ever"
  (inevitable (is m.stage acked) (fair ack)))
```

```text writ_check model=consumer.writ claims=consumer.claims
states: 10   edges: 9
regime: committing — no move can be undone
gaps: none
dead ends: 3
  reached by: deliver, process, ack
  reached by: deliver, process, timeout, deliver, process, ack
  reached by: deliver, process, timeout, deliver, process, timeout, deliver
fails  charged-once
  "the customer is never charged twice"
  witness:  1. deliver   → #1   m.stage: queued → delivered
            2. process   → #2   m.stage: delivered → processed, acct.charges: c0 → c1
            3. timeout   → #4   m.stage: processed → queued
            4. deliver   → #5   m.stage: queued → delivered
            5. process   → #6   m.stage: delivered → processed, acct.charges: c1 → c2
fails  finishes
  "every run acks the message"
  stuck at: #9 (m.stage=delivered acct.charges=c2)
  witness:  1. deliver   → #1   m.stage: queued → delivered
            2. process   → #2   m.stage: delivered → processed, acct.charges: c0 → c1
            3. timeout   → #4   m.stage: processed → queued
            4. deliver   → #5   m.stage: queued → delivered
            5. process   → #6   m.stage: delivered → processed, acct.charges: c1 → c2
            6. timeout   → #8   m.stage: processed → queued
            7. deliver   → #9   m.stage: queued → delivered
  avoids:   the run stops at #9: no move is left
fails  finishes-fairly
  "it does, if an offered ack is not refused for ever"
  assuming fair: ack
  stuck at: #9 (m.stage=delivered acct.charges=c2)
  witness:  1. deliver   → #1   m.stage: queued → delivered
            2. process   → #2   m.stage: delivered → processed, acct.charges: c0 → c1
            3. timeout   → #4   m.stage: processed → queued
            4. deliver   → #5   m.stage: queued → delivered
            5. process   → #6   m.stage: delivered → processed, acct.charges: c1 → c2
            6. timeout   → #8   m.stage: processed → queued
            7. deliver   → #9   m.stage: queued → delivered
  avoids:   the run stops at #9: no move is left
```

`charged-once` fails: process, lose the ack, redeliver, process again. Both termination properties fail too, stuck at `#9`, where the message is delivered but `process` cannot fire because the ladder has ended (`acct.charges.next` has no answer). That dead end is the **bound**, not the system: the ladder only counts to `c2`. Read it as such.

**The fix.** An idempotency key: the first processing sets `m.key-seen` and charges; any later one only marks the message processed.

```lisp file=consumer-fixed.writ
(load "stdlib.writ")
(schema billing
  (type stage-t (queued delivered processed acked))
  (type count (arrow next (to count) fixed vacatable))   ; a ladder, not a number
  (type yes-no (no yes))
  (type message (arrow stage (to stage-t)) (arrow key-seen (to yes-no)))
  (type account (arrow charges (to count))))
(instance start billing
  (count c0 c1 c2)
  (next (c0 c1) (c1 c2) (c2 vacant))
  (message m (stage queued) (key-seen no))
  (account acct (charges c0)))
(use billing)
(initial start)

(transition deliver (when (is m.stage queued)) (do (set m.stage delivered)))
; The idempotency key: charge only the first time this message is processed.
(transition process (when (and (is m.stage delivered) (is m.key-seen no)))
  (do (set acct.charges acct.charges.next) (set m.key-seen yes)
      (set m.stage processed)))
(transition process-again (when (and (is m.stage delivered) (is m.key-seen yes)))
  (do (set m.stage processed)))
(transition ack (when (is m.stage processed)) (do (set m.stage acked)))
; The ack can be lost: the broker times out and redelivers.
(transition timeout (when (is m.stage processed)) (do (set m.stage queued)))
```

```text writ_check model=consumer-fixed.writ claims=consumer.claims
states: 6   edges: 6
regime: reversible — 3 of 6 situations lie on cycles
gaps: none
dead ends: 1
  reached by: deliver, process, ack
holds  charged-once
  "the customer is never charged twice"
fails  finishes
  "every run acks the message"
  stuck at: #2 (m.stage=processed m.key-seen=yes acct.charges=c1)
  witness:  1. deliver   → #1   m.stage: queued → delivered
            2. process   → #2   m.stage: delivered → processed, m.key-seen: no → yes, acct.charges: c0 → c1
  loop:     1. timeout → #4   2. deliver → #5   3. process-again → #2   (and again, for ever)
holds  finishes-fairly
  "it does, if an offered ack is not refused for ever"
  assuming fair: ack
```

Now `charged-once` holds. `finishes` still fails, correctly: a run can lose the ack for ever (`timeout` again and again). `finishes-fairly` holds: if `ack` is not refused for ever, every run acks. That is `inevitable` with `(fair …)` doing its job, and the honest statement of what this protocol guarantees.

```text writ_compare old=consumer.writ new=consumer-fixed.writ claims=consumer.claims
equations:
properties:  charged-once     gained
             finishes-fairly  gained
still failing in both models: finishes
```

`finishes` fails in both models, so it is no row of the comparison; the last line names it, so a fix that fixed nothing cannot pass for one.
