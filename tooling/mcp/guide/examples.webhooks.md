An order is authorized and can then be captured or voided. A payment gateway sends `capture` and `void` webhooks; delivery is at-least-once, so a handled webhook can arrive again, and two workers consume them concurrently. The requirement: a voided order is never captured. That mentions order (*after* voided), so the model keeps a history cell, `o.was-voided`, set by the void handler (`idioms`, History).

```lisp file=webhooks.writ
(load "stdlib.writ")
(schema shop
  (type status-t (authorized captured voided))
  (type yes-no (no yes))
  (type order (arrow status (to status-t)) (arrow was-voided (to yes-no)))
  (type kind-t (capture void))
  (type stage-t (queued working done))
  (type hook (arrow kind (to kind-t) fixed) (arrow stage (to stage-t)))
  (type worker (maybe job hook)))
(instance start shop
  (order o (status authorized) (was-voided no))
  (hook cap (kind capture) (stage queued))
  (hook vd (kind void) (stage queued))
  (worker w1)
  (worker w2))
(use shop)
(initial start)

; At-least-once delivery: a handled webhook can arrive again.
(transition redeliver-capture (when (is cap.stage done)) (do (set cap.stage queued)))
(transition redeliver-void (when (is vd.stage done)) (do (set vd.stage queued)))

(form (consumer W TAKE-CAP TAKE-VOID CAPTURE VOID SKIP-VOID)
  (transition TAKE-CAP (when (and (is cap.stage queued) (not (defined W.job))))
                       (do (set W.job cap) (set cap.stage working)))
  (transition TAKE-VOID (when (and (is vd.stage queued) (not (defined W.job))))
                        (do (set W.job vd) (set vd.stage working)))
  ; "Skip duplicates": capture unless already captured.
  (transition CAPTURE (when (and (is W.job.kind capture) (not (is o.status captured))))
                      (do (set o.status captured) (set W.job.stage done) (vacate W.job)))
  (transition VOID (when (and (is W.job.kind void) (is o.status authorized)))
                   (do (set o.status voided) (set o.was-voided yes)
                       (set W.job.stage done) (vacate W.job)))
  (transition SKIP-VOID (when (and (is W.job.kind void) (not (is o.status authorized))))
                        (do (set W.job.stage done) (vacate W.job))))
(consumer w1 w1-take-capture w1-take-void w1-capture w1-void w1-skip-void)
(consumer w2 w2-take-capture w2-take-void w2-capture w2-void w2-skip-void)
```

```lisp file=webhooks.claims
(property no-capture-after-void "a voided order is never captured"
  (never (and (is o.was-voided yes) (is o.status captured))))
(property can-settle "the order can always still be settled"
  (live (not (is o.status authorized))))
```

```text writ_check model=webhooks.writ claims=webhooks.claims
states: 45   edges: 91
regime: reversible — 38 of 45 situations lie on cycles
gaps: none
dead ends: none
fails  no-capture-after-void
  "a voided order is never captured"
  witness:  1. w1-take-capture   → #1   cap.stage: queued → working, w1.job: ∅ → cap
            2. w2-take-void      → #6   vd.stage: queued → working, w2.job: ∅ → vd
            3. w2-void           → #12   o.status: authorized → voided, o.was-voided: no → yes, vd.stage: working → done, w2.job: vd → ∅
            4. w1-capture        → #21   o.status: voided → captured, cap.stage: working → done, w1.job: cap → ∅
holds  can-settle
  "the order can always still be settled"
```

`no-capture-after-void` fails. The witness: `w1` takes the capture webhook, `w2` takes the void and voids the order, then `w1` captures it, because the capture handler's guard only skips orders that are *already captured*. Duplicates are not even needed: the two workers are enough. `can-settle` holds: the order can always leave `authorized`.

**The fix.** Capture only an order that is still `authorized`, and acknowledge any other capture webhook without effect (a new `SKIP-CAP` move per worker).

```lisp file=webhooks-fixed.writ
(load "stdlib.writ")
(schema shop
  (type status-t (authorized captured voided))
  (type yes-no (no yes))
  (type order (arrow status (to status-t)) (arrow was-voided (to yes-no)))
  (type kind-t (capture void))
  (type stage-t (queued working done))
  (type hook (arrow kind (to kind-t) fixed) (arrow stage (to stage-t)))
  (type worker (maybe job hook)))
(instance start shop
  (order o (status authorized) (was-voided no))
  (hook cap (kind capture) (stage queued))
  (hook vd (kind void) (stage queued))
  (worker w1)
  (worker w2))
(use shop)
(initial start)

; At-least-once delivery: a handled webhook can arrive again.
(transition redeliver-capture (when (is cap.stage done)) (do (set cap.stage queued)))
(transition redeliver-void (when (is vd.stage done)) (do (set vd.stage queued)))

(form (consumer W TAKE-CAP TAKE-VOID CAPTURE SKIP-CAP VOID SKIP-VOID)
  (transition TAKE-CAP (when (and (is cap.stage queued) (not (defined W.job))))
                       (do (set W.job cap) (set cap.stage working)))
  (transition TAKE-VOID (when (and (is vd.stage queued) (not (defined W.job))))
                        (do (set W.job vd) (set vd.stage working)))
  ; Capture only what is still authorized; ack anything else.
  (transition CAPTURE (when (and (is W.job.kind capture) (is o.status authorized)))
                      (do (set o.status captured) (set W.job.stage done) (vacate W.job)))
  (transition SKIP-CAP (when (and (is W.job.kind capture) (not (is o.status authorized))))
                       (do (set W.job.stage done) (vacate W.job)))
  (transition VOID (when (and (is W.job.kind void) (is o.status authorized)))
                   (do (set o.status voided) (set o.was-voided yes)
                       (set W.job.stage done) (vacate W.job)))
  (transition SKIP-VOID (when (and (is W.job.kind void) (not (is o.status authorized))))
                        (do (set W.job.stage done) (vacate W.job))))
(consumer w1 w1-take-capture w1-take-void w1-capture w1-skip-capture w1-void w1-skip-void)
(consumer w2 w2-take-capture w2-take-void w2-capture w2-skip-capture w2-void w2-skip-void)
```

```text writ_check model=webhooks-fixed.writ claims=webhooks.claims
states: 35   edges: 80
regime: reversible — 28 of 35 situations lie on cycles
gaps: none
dead ends: none
holds  no-capture-after-void
  "a voided order is never captured"
holds  can-settle
  "the order can always still be settled"
```

```text writ_compare old=webhooks.writ new=webhooks-fixed.writ claims=webhooks.claims
equations:
properties:  no-capture-after-void  gained
             can-settle             preserved
```

The guard on the current state, not on "have I seen this before", is what makes the handler safe against duplicates and reordering alike.
