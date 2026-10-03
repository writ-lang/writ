# The Writ language, for writing a model that runs

Twenty-six kernel words. Everything else — quantifiers, equality, ordering,
domain vocabulary — is a library form built from them.

```
load use initial schema type arrow to fixed vacatable equation
instance vacant transition when do set vacate gap
and or not is defined some form &rest
```

Three file types, kept apart:

| | |
| --- | --- |
| `.writ` | the model — schema, instance, transitions |
| `.claims` | properties and queries about it |
| `.rules` | Datalog-style relations over its situation space |

## A model, whole

```lisp
(load "stdlib.writ")                      ; there is NO implicit prelude

(schema shop
  (type stage-t (queued running done))   ; an ENUMERATED type: named values
  (type machine (maybe held-by job))     ; `maybe` = stdlib for a vacatable arrow
  (type job                              ; an OPEN type: entities, declared below
    (arrow stage (to stage-t))
    (arrow uses  (to machine) fixed)))   ; `fixed` = wiring, no move may change it

(instance start shop                     ; exactly ONE starting configuration
  (machine m1)
  (job a)
  (uses  (a m1))
  (stage (a queued))
  (held-by (m1 vacant)))                 ; `vacant` = no answer, not a value

(use shop)
(initial start)

(transition begin
  (when (and (is a.stage queued) (not (defined a.uses.held-by))))
  (do (set a.uses.held-by a) (set a.stage running)))

(transition finish                       ; and the machine is handed back
  (when (is a.stage running))
  (do (set a.stage done) (vacate a.uses.held-by)))
```

`a.uses.held-by` is a **chain**: follow `uses` from `a`, then `held-by`.

## The six things that trip people up

**A move that cannot fire is absent.** `when` states the situations the move
exists in; there is no error and no rollback.

**`vacant` is the absence of an answer.** Only a `vacatable` arrow may be
empty, and only `vacate` empties it; `set` cannot write `vacant`.

**`is` is strict; an undefined side makes it false.** So `differ` (stdlib) is
*true* when either side is undefined. If you mean "both filled and different",
write `(and (defined A) (defined B) (differ A B))`.

**A law is observed, not enforced.** `writ check` reports which moves break an
`(equation name GUARD)`, and where. A constraint you want enforced goes in a
`when`.

**Effects are simultaneous.** Every effect reads the situation the move started
from, so `(do (set a.x b.y) (set b.y a.x))` is a swap.

**A guard tests a cell; it cannot bind what a cell holds.** The right of `is`
is a literal or another chain, never a variable, so `(query pick (where (k
slot) (c part)) (is k.chosen c))` silently answers **empty**. To read a mutable
cell, use the rules engine, where `holds` binds: `(rule (pick K C) (situation
S) (holds S (is K.chosen C)))`, then `writ derive` (`docs/interrogator.md` §2
in the writ repository).

## Guards

| | |
| --- | --- |
| `(is CHAIN V)` | the chain's answer is V — a literal, or another chain |
| `(defined CHAIN)` | the chain has an answer at all |
| `(and …)` `(or …)` `(not G)` | as expected; `(and)` is true |
| `(some (x TYPE) G)` | some entity of TYPE satisfies G |
| `(all (x TYPE) G)` | stdlib: every entity of TYPE does |

## Effects

| | |
| --- | --- |
| `(set CHAIN RHS)` | write the slot; RHS is a literal or a chain |
| `(vacate CHAIN)` | empty it — only if the arrow is `vacatable` |
| `(gap "MSG")` | the rules are declared silent here; no next situation |

A `set` whose chain has no answer makes the move **absent**, so a walker stops
at the end of a ladder with no guard.

## Questions (`.claims`)

```lisp
(load "stdlib.writ")

(property finishes "the job can finish"
  (possible (is a.stage done)))

(property never-stuck "from anywhere, it can still finish"
  (live (is a.stage done)))

(property must-finish "and no run of it goes on for ever"
  (inevitable (is a.stage done)))

(query where-is
  (where (m machine)) (defined m.held-by))
```

`live` detects traps and `inevitable` detects non-termination (see the
modalities in SKILL.md).

**A `property` carries a description string; a `query` does not** (§16.2 —
`(query NAME (where (x TYPE)…) GUARD)`). Giving a query one is `malformed
query`, and the whole claims file is rejected.

## Forms — the only way to abstract

```lisp
(form (idle M) (not (defined M.held-by)))             ; a named guard
(form (job-of J E A L) (enters J E) (advances J A) (leaves J L))
```

A form is **rename-and-paste**: no recursion, no computation, no mapping over
`&rest`. At top level it may expand to several datums; inside a list, to
exactly one.

**A form cannot introduce a bound variable.** An undeclared symbol in a template
is read as a form name, so writing `(form (deps-met C) (all (R req) …))`
fails with *"template of `deps-met` mentions `R`, a form not yet declared"*.
Thread the binder in as a parameter — `(form (deps-met C R) (all (R req) …))`
— and pass a name at each call site.

A **domain library** is declarations only — a schema, an instance, forms — and
no `use`/`initial`/`transition`. Load it by relative path.

## No arithmetic, and what to do instead

No numbers, recursion or unbounded structures — that is what makes exhaustive
search terminate.

- **A quantity** → a small enumerated type (`(type load-t (none some full))`).
- **Time, or a counter** → a ladder of named entities walked by an arrow:
  `(type tick (arrow next (to tick) fixed vacatable))`, then
  `(set clk.at clk.at.next)`. Running off the end stops the move.
- **A distance or a diagonal** → *name* it and put it in the data as a `fixed`
  arrow, rather than computing it.

## Modelling checklist

1. What kinds of thing exist? → `type`
2. What does each know about? → `arrow` (`fixed` if it never changes)
3. What is true at the start? → `instance`
4. What can happen, and when? → `transition`
5. What do you want to know? → `.claims`, in a separate file

Keep it **small**: the space is the product of every mutable cell. Three jobs on
three machines is 51 situations; adding a clock makes it 1314.
