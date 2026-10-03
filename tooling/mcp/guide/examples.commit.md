Two-phase commit with two participants. Each votes yes or no (two moves each: the choice is nondeterministic, so writ tries both); the coordinator decides; each participant applies the decision. The coordinator here commits as soon as *some* participant is ready.

```lisp file=commit.writ
(load "stdlib.writ")
(schema tpc
  (type vote-t (yes no))
  (type outcome-t (commit abort))
  (type state-t (working committed aborted))
  (type part (maybe vote vote-t) (arrow state (to state-t)))
  (type coord (maybe decision outcome-t)))
(instance start tpc
  (part p1 (state working))
  (part p2 (state working))
  (coord c))
(use tpc)
(initial start)

(form (participant P YES NO APPLY-COMMIT APPLY-ABORT)
  (transition YES (when (not (defined P.vote))) (do (set P.vote yes)))
  (transition NO (when (not (defined P.vote))) (do (set P.vote no)))
  (transition APPLY-COMMIT (when (and (is c.decision commit) (is P.state working)))
                           (do (set P.state committed)))
  (transition APPLY-ABORT (when (and (is c.decision abort) (is P.state working)))
                          (do (set P.state aborted))))
(participant p1 p1-yes p1-no p1-commit p1-abort)
(participant p2 p2-yes p2-no p2-commit p2-abort)

; Commit as soon as one participant is ready.
(transition decide-commit
  (when (and (not (defined c.decision)) (some (p part) (is p.vote yes))))
  (do (set c.decision commit)))
(transition decide-abort
  (when (and (not (defined c.decision)) (some (p part) (is p.vote no))))
  (do (set c.decision abort)))
```

```lisp file=commit.claims
(load "stdlib.writ")
(property atomic "no participant commits while another voted no"
  (never (and (some (x part) (is x.state committed))
              (some (y part) (is y.vote no)))))
(property terminates "every run ends with every participant decided"
  (inevitable (all (x part) (not (is x.state working)))))
```

```text writ_check model=commit.writ claims=commit.claims
states: 49   edges: 94
regime: committing — no move can be undone
gaps: none
dead ends: 6
  reached by: p1-yes, p2-yes, decide-commit, p1-commit, p2-commit
  reached by: p1-yes, p2-no, decide-commit, p1-commit, p2-commit
  reached by: p1-yes, p2-no, decide-abort, p1-abort, p2-abort
  reached by: p1-no, p2-yes, decide-commit, p1-commit, p2-commit
  reached by: p1-no, p2-yes, decide-abort, p1-abort, p2-abort
  reached by: p1-no, p2-no, decide-abort, p1-abort, p2-abort
fails  atomic
  "no participant commits while another voted no"
  witness:  1. p1-yes          → #1   p1.vote: ∅ → yes
            2. p2-no           → #6   p2.vote: ∅ → no
            3. decide-commit   → #14   c.decision: ∅ → commit
            4. p1-commit       → #29   p1.state: working → committed
holds  terminates
  "every run ends with every participant decided"
```

`atomic` fails: `p1` votes yes, `p2` votes no, the coordinator commits, `p1` commits. `terminates` holds, and the six dead ends are the designed endings (every participant has applied a decision), which is what `inevitable` confirms.

**The fix.** Commit only when every participant voted yes: `all` from the standard library.

```lisp file=commit-fixed.writ
(load "stdlib.writ")
(schema tpc
  (type vote-t (yes no))
  (type outcome-t (commit abort))
  (type state-t (working committed aborted))
  (type part (maybe vote vote-t) (arrow state (to state-t)))
  (type coord (maybe decision outcome-t)))
(instance start tpc
  (part p1 (state working))
  (part p2 (state working))
  (coord c))
(use tpc)
(initial start)

(form (participant P YES NO APPLY-COMMIT APPLY-ABORT)
  (transition YES (when (not (defined P.vote))) (do (set P.vote yes)))
  (transition NO (when (not (defined P.vote))) (do (set P.vote no)))
  (transition APPLY-COMMIT (when (and (is c.decision commit) (is P.state working)))
                           (do (set P.state committed)))
  (transition APPLY-ABORT (when (and (is c.decision abort) (is P.state working)))
                          (do (set P.state aborted))))
(participant p1 p1-yes p1-no p1-commit p1-abort)
(participant p2 p2-yes p2-no p2-commit p2-abort)

; Commit only when every participant voted yes.
(transition decide-commit
  (when (and (not (defined c.decision)) (all (p part) (is p.vote yes))))
  (do (set c.decision commit)))
(transition decide-abort
  (when (and (not (defined c.decision)) (some (p part) (is p.vote no))))
  (do (set c.decision abort)))
```

```text writ_check model=commit-fixed.writ claims=commit.claims
states: 33   edges: 58
regime: committing — no move can be undone
gaps: none
dead ends: 4
  reached by: p1-yes, p2-yes, decide-commit, p1-commit, p2-commit
  reached by: p1-yes, p2-no, decide-abort, p1-abort, p2-abort
  reached by: p1-no, p2-yes, decide-abort, p1-abort, p2-abort
  reached by: p1-no, p2-no, decide-abort, p1-abort, p2-abort
holds  atomic
  "no participant commits while another voted no"
holds  terminates
  "every run ends with every participant decided"
```

```text writ_compare old=commit.writ new=commit-fixed.writ claims=commit.claims
equations:
properties:  atomic      gained
             terminates  preserved
```

`some` and `all` range over a type's entities; their variable heads chains (`p.vote`) and cannot stand alone as a value.
