A `.writ` file is s-expressions. `;` starts a comment to end of line. Atoms are case-sensitive; a quoted atom `"…"` may hold spaces (escapes `\n \t \r \" \\`). An atom containing `.` is a **chain**: `a.uses.held-by` follows the arrow `uses` from `a`, then `held-by`. ALL-CAPS atoms are blanks inside a form, and variables in a rules file; avoid them for names.

## Grammar

```
model       ::= library-datum… use-d initial-d transition-d…
library-datum ::= load-d | schema-d | instance-d | form-d

load-d      ::= (load "FILE")                  ; e.g. (load "stdlib.writ"); no implicit prelude
use-d       ::= (use SCHEMA)                   ; exactly one
initial-d   ::= (initial INSTANCE)             ; exactly one

schema-d    ::= (schema NAME type-d… equation-d…)
type-d      ::= (type NAME)                    ; open: entities are listed by the instance
              | (type NAME (VALUE…))           ; enumerated: these values and no others
              | (type NAME arrow-d…)           ; open, with arrows out of it
arrow-d     ::= (arrow NAME (to TYPE) flag…)
flag        ::= fixed                          ; wiring: set in the instance, no move may change it
              | vacatable                      ; may be empty (vacant)
equation-d  ::= (equation NAME guard)          ; a law; chains start at a TYPE name (see below)

instance-d  ::= (instance NAME SCHEMA clause…)
clause      ::= (TYPE ENTITY…)                 ; declare entities of an open type
              | (TYPE ENTITY slot…)            ; one entity with its slots
              | (ARROW (ENTITY value)…)        ; one arrow's value for several entities
slot        ::= (ARROW value)
value       ::= VALUE | ENTITY | vacant

transition-d::= (transition NAME (when guard) (do effect…))   ; NAME optional but always give one
guard       ::= (and guard…) | (or guard…) | (not guard)
              | (is CHAIN rhs)                 ; the chain's answer is rhs; false if it has none
              | (defined CHAIN)                ; the chain has an answer
              | (some (VAR TYPE) guard)        ; some entity of TYPE; VAR may only head chains
              | NAME | (NAME arg…)             ; a form
rhs         ::= VALUE | ENTITY | CHAIN
effect      ::= (set CHAIN rhs) | (vacate CHAIN) | (gap "MESSAGE")

form-d      ::= (form (NAME BLANK… [&rest BLANK]) TEMPLATE…)
              | (form NAME DATUM)              ; nullary, used as the bare atom NAME
```

The 26 kernel words: `load use initial schema type arrow to fixed vacatable equation instance vacant transition when do set vacate gap and or not is defined some form &rest`.

## A whole model

```lisp
(load "stdlib.writ")
(schema shop
  (type stage-t (queued running done))     ; enumerated
  (type machine (maybe held-by job))       ; maybe = stdlib for a vacatable arrow
  (type job
    (arrow stage (to stage-t))
    (arrow uses (to machine) fixed)))      ; wiring
(instance start shop
  (machine m1)
  (job a (stage queued) (uses m1))
  (job b (stage queued) (uses m1)))        ; m1.held-by is vacatable, so it starts vacant
(use shop)
(initial start)
(form (job-moves J BEGIN FINISH)
  (transition BEGIN
    (when (and (is J.stage queued) (not (defined J.uses.held-by))))
    (do (set J.uses.held-by J) (set J.stage running)))
  (transition FINISH (when (is J.stage running))
    (do (set J.stage done) (vacate J.uses.held-by))))
(job-moves a a-begin a-finish)
(job-moves b b-begin b-finish)
```

## Rules of each construct

**Types.** An enumerated type's values are atoms; an open type's entities come from the instance. Every type, entity, form and law shares one namespace with everything loaded; arrow names are scoped to their type.

**Arrows and cells.** Each (entity, arrow) pair is a cell. A `fixed` cell is wiring: given once in the instance, never written, not part of a situation. Every other cell is mutable and is part of the situation. In the instance, every non-vacatable cell needs a value; a vacatable mutable cell left out starts `vacant`; a fixed cell must be given even when vacatable (write `(c2 vacant)` at the end of a ladder).

**Chains.** `x.a.b` follows `a` from `x`, then `b`. If any step has no answer, the chain has none: `is` is then false, `defined` false, and a `set` whose target or right side has no answer makes the whole move absent in that situation.

**Moves.** `when` decides where the move exists; there is no failure and no rollback. All effects of one move read the situation it started from and apply together, so `(do (set a.x b.y) (set b.y a.x))` swaps. `set` cannot write `vacant`; use `vacate`, and only on a vacatable arrow. `(gap "MSG")` declares the rules silent here: the move leads out of the model. Omitting `(do …)` makes a move that changes nothing (a self-loop).

**Guards.** `(is A B)` is strict: false if either side has no answer, so `(not (is A B))` is true when A is vacant. `some` binds a variable that may head chains, `(some (j job) (is j.stage done))`, but cannot stand alone as a value: `(is x.owner j)` with a bare `j` is an error. A guard can test a cell but cannot bind what it holds for later use; use `.rules` for that.

**Laws.** `(equation NAME GUARD)` sits inside the schema. Its chains start at a type name, which ranges over every entity of that type: `(equation one-holder (not (and (is job.stage running) (not (defined job.uses.held-by)))))`. A law is observed: `writ_check` reports which moves can break it and the shortest route to a situation that does. It never prunes a move.

**Forms.** A form renames and pastes, before parsing: blanks (ALL-CAPS) are replaced by what the call wrote; `&rest R` captures the remaining arguments and `@R` pastes them. No recursion, conditionals or loops. A template may mention only kernel words, its own blanks and forms declared earlier; it cannot introduce a bound variable, so pass a `some` variable in as a parameter. A top-level call may expand to several datums (several transitions); inside a list it must expand to exactly one. Pass move names as parameters, as above: unnamed moves print as `#0`, `#1`…, which reads like a situation index.

## The standard library (`stdlib.writ`)

| form | means |
| --- | --- |
| `(all (X T) G)` | every X of type T satisfies G |
| `(= A B)` | equal, or either side has no answer |
| `(differ A B)` | `(not (is A B))`: true when either side has no answer |
| `(maybe A T)` | `(arrow A (to T) vacatable)`, inside a type |
| `(toggle P A B)` | two moves flipping P between A and B |
| `(latch P A B)` | one move taking P from A to B, never back |
| `(phase-gated P V G)` | `(and (is P V) G)` |
| `(span R A B)` | a junction type R with fixed arrows `left` to A and `right` to B |

It also declares the schemas `quiver` (types `node`, `edge`) and `olog` (types `ob`, `hom`, `eqn`): do not name your own types or entities `node`, `edge`, `ob`, `hom` or `eqn`.
