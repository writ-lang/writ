Two processes share a lock. Each checks that the lock is free, then takes it: two moves, so the other process can run in between. The question is the safety property every mutex owes: never both inside.

```lisp file=mutex.writ
(load "stdlib.writ")
(schema mutex
  (type pc-t (idle saw-free critical))
  (type proc (arrow pc (to pc-t)))
  (type lock (maybe holder proc)))
(instance start mutex
  (proc p (pc idle))
  (proc q (pc idle))
  (lock l))
(use mutex)
(initial start)

; Check, then take: two moves, so both processes can see the lock free.
(form (process P LOOK TAKE LEAVE)
  (transition LOOK (when (and (is P.pc idle) (not (defined l.holder))))
                   (do (set P.pc saw-free)))
  (transition TAKE (when (is P.pc saw-free))
                   (do (set l.holder P) (set P.pc critical)))
  (transition LEAVE (when (is P.pc critical))
                    (do (vacate l.holder) (set P.pc idle))))
(process p p-look p-take p-leave)
(process q q-look q-take q-leave)
```

```lisp file=mutex.claims
(property exclusive "never both in the critical section"
  (never (and (is p.pc critical) (is q.pc critical))))
(property p-can-enter "p can always still get in"
  (live (is p.pc critical)))
```

```text writ_check model=mutex.writ claims=mutex.claims
states: 14   edges: 26
regime: reversible — 14 of 14 situations lie on cycles
gaps: none
dead ends: none
fails  exclusive
  "never both in the critical section"
  witness:  1. p-look   → #1   p.pc: idle → saw-free
            2. q-look   → #4   q.pc: idle → saw-free
            3. p-take   → #6   p.pc: saw-free → critical, l.holder: ∅ → p
            4. q-take   → #8   q.pc: saw-free → critical, l.holder: p → q
holds  p-can-enter
  "p can always still get in"
```

`exclusive` fails, and the witness is the race: both look while the lock is free (steps 1 and 2), then both take it. The second take overwrites `l.holder` (`p → q`), which a real lock would refuse. `p-can-enter` holds: there is no deadlock, only a safety bug.

**The fix.** Make seeing the lock free and taking it one move, a test-and-set. `saw-free` disappears.

```lisp file=mutex-fixed.writ
(load "stdlib.writ")
(schema mutex
  (type pc-t (idle critical))
  (type proc (arrow pc (to pc-t)))
  (type lock (maybe holder proc)))
(instance start mutex
  (proc p (pc idle))
  (proc q (pc idle))
  (lock l))
(use mutex)
(initial start)

; Test-and-set: seeing the lock free and taking it are one move.
(form (process P TAKE LEAVE)
  (transition TAKE (when (and (is P.pc idle) (not (defined l.holder))))
                   (do (set l.holder P) (set P.pc critical)))
  (transition LEAVE (when (is P.pc critical))
                    (do (vacate l.holder) (set P.pc idle))))
(process p p-take p-leave)
(process q q-take q-leave)
```

```text writ_check model=mutex-fixed.writ claims=mutex.claims
states: 3   edges: 4
regime: reversible — 3 of 3 situations lie on cycles
gaps: none
dead ends: none
holds  exclusive
  "never both in the critical section"
holds  p-can-enter
  "p can always still get in"
```

Then price the edit against the old model:

```text writ_compare old=mutex.writ new=mutex-fixed.writ claims=mutex.claims
equations:   none
properties:  exclusive    gained
             p-can-enter  preserved
```

`exclusive` was gained and nothing was lost. The lesson is in `idioms` (Concurrency): whatever the real system does in two steps must be two moves, or the model cannot show the race.
