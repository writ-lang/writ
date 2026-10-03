Leader `a` hands leadership to `b`. In this version `b` acknowledges only once `a` has stepped down, and `a` steps down only once `b` has acknowledged.

```lisp file=handoff.writ
(load "stdlib.writ")
(schema cluster
  (type role-t (leader follower))
  (type yes-no (no yes))
  (type server (arrow role (to role-t))
             (arrow offered (to yes-no))
             (arrow acked (to yes-no))))
(instance start cluster
  (server a (role leader) (offered no) (acked no))
  (server b (role follower) (offered no) (acked no)))
(use cluster)
(initial start)

(transition offer (when (and (is a.role leader) (is a.offered no)))
  (do (set a.offered yes)))
; b acknowledges only once a has stepped down...
(transition b-ack (when (and (is a.offered yes) (is a.role follower) (is b.acked no)))
  (do (set b.acked yes)))
; ...and a steps down only once b has acknowledged.
(transition a-release (when (and (is b.acked yes) (is a.role leader)))
  (do (set a.role follower)))
(transition b-take (when (and (is b.acked yes) (is a.role follower) (is b.role follower)))
  (do (set b.role leader)))
```

```lisp file=handoff.claims
(property one-leader "never two leaders at once"
  (never (and (is a.role leader) (is b.role leader))))
(property hands-off "the handoff can always still complete"
  (live (is b.role leader)))
```

```text writ_check model=handoff.writ claims=handoff.claims
states: 2   edges: 1
regime: committing — no move can be undone
gaps: none
dead ends: 1
  reached by: offer
holds  one-leader
  "never two leaders at once"
fails  hands-off
  "the handoff can always still complete"
  stuck at: #0 (a.role=leader b.role=follower a.offered=no b.offered=no a.acked=no b.acked=no)
```

`hands-off` fails, stuck at `#0`: no run can ever complete the handoff, because after `offer` each side waits for the other. The one dead end, after `offer`, is that deadlock, not a designed ending. `one-leader` holds only because nothing happens.

**A first fix**, which looks right: let `b` acknowledge the offer itself and take over once it has.

```lisp file=handoff-v2.writ
(load "stdlib.writ")
(schema cluster
  (type role-t (leader follower))
  (type yes-no (no yes))
  (type server (arrow role (to role-t))
             (arrow offered (to yes-no))
             (arrow acked (to yes-no))))
(instance start cluster
  (server a (role leader) (offered no) (acked no))
  (server b (role follower) (offered no) (acked no)))
(use cluster)
(initial start)

(transition offer (when (and (is a.role leader) (is a.offered no)))
  (do (set a.offered yes)))
; b acknowledges the offer itself.
(transition b-ack (when (and (is a.offered yes) (is b.acked no)))
  (do (set b.acked yes)))
(transition a-release (when (and (is b.acked yes) (is a.role leader)))
  (do (set a.role follower)))
(transition b-take (when (and (is b.acked yes) (is b.role follower)))
  (do (set b.role leader)))
```

```text writ_check model=handoff-v2.writ claims=handoff.claims
states: 6   edges: 6
regime: committing — no move can be undone
gaps: none
dead ends: 1
  reached by: offer, b-ack, a-release, b-take
fails  one-leader
  "never two leaders at once"
  witness:  1. offer    → #1   a.offered: no → yes
            2. b-ack    → #2   b.acked: no → yes
            3. b-take   → #4   b.role: follower → leader
holds  hands-off
  "the handoff can always still complete"
```

The deadlock is gone, but compare the edit before calling it done:

```text writ_compare old=handoff.writ new=handoff-v2.writ claims=handoff.claims
equations:
properties:  one-leader  LOST      witness: 1. offer 2. b-ack 3. b-take
             hands-off   gained
```

`one-leader` is LOST, and the row carries the route: `b` takes over before `a` has released. This is the regression loop (`idioms`): an edit that makes one property pass by losing another is not a fix.

**The real fix.** `b` takes over only once `a` is a follower.

```lisp file=handoff-v3.writ
(load "stdlib.writ")
(schema cluster
  (type role-t (leader follower))
  (type yes-no (no yes))
  (type server (arrow role (to role-t))
             (arrow offered (to yes-no))
             (arrow acked (to yes-no))))
(instance start cluster
  (server a (role leader) (offered no) (acked no))
  (server b (role follower) (offered no) (acked no)))
(use cluster)
(initial start)

(transition offer (when (and (is a.role leader) (is a.offered no)))
  (do (set a.offered yes)))
; b acknowledges the offer itself.
(transition b-ack (when (and (is a.offered yes) (is b.acked no)))
  (do (set b.acked yes)))
(transition a-release (when (and (is b.acked yes) (is a.role leader)))
  (do (set a.role follower)))
(transition b-take (when (and (is b.acked yes) (is a.role follower) (is b.role follower)))
  (do (set b.role leader)))
```

```text writ_check model=handoff-v3.writ claims=handoff.claims
states: 5   edges: 4
regime: committing — no move can be undone
gaps: none
dead ends: 1
  reached by: offer, b-ack, a-release, b-take
holds  one-leader
  "never two leaders at once"
holds  hands-off
  "the handoff can always still complete"
```

```text writ_compare old=handoff.writ new=handoff-v3.writ claims=handoff.claims
equations:
properties:  one-leader  preserved
             hands-off   gained
```
