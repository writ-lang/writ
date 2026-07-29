# The Pol language, for writing a model that runs

Twenty-seven kernel words. Everything else — quantifiers, equality, ordering,
domain vocabulary — is a library form built from them.

```
load use initial schema type arrow to of fixed vacatable equation
instance vacant transition when do set vacate gap
and or not is defined some form &rest
```

Three file types, and keeping them apart is deliberate: a model, the questions
asked of it, and derivations over it are three documents.

| | |
| --- | --- |
| `.pol` | the model — schema, instance, transitions |
| `.claims` | properties and queries about it |
| `.rules` | Datalog-style relations over its situation space |

## A model, whole

```lisp
(load "stdlib.pol")                      ; there is NO implicit prelude

(schema shop
  (type stage-t (queued running done))   ; an ENUMERATED type: named values
  (type machine (maybe held-by job))     ; `maybe` = stdlib for a vacatable arrow
  (type job                              ; an OPEN type: entities, declared below
    (arrow stage (to stage-t))
    (arrow uses  (to machine) fixed)))   ; `fixed` = wiring, no move may change it

(instance start (of shop)                ; exactly ONE starting configuration
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
```

`a.uses.held-by` is a **chain**: follow `uses` from `a`, then `held-by`. Chains
are how everything is said.

## The five things that trip people up

**A move that cannot fire is ABSENT, not failed.** `when` states the situations
the move exists in. There is no error, no exception, no rollback.

**`vacant` is the absence of an answer, not a value.** Only a `vacatable` arrow
may be empty. `set` cannot write `vacant` — that is what `vacate` is for.

**`is` is strict; an undefined side makes it false.** So `differ` (stdlib) is
*true* when either side is undefined. If you mean "both filled and different",
write `(and (defined A) (defined B) (differ A B))`. The kernel will not guess.

**A law is OBSERVED, not enforced.** `(equation name GUARD)` does not stop a
move; `pol check` reports whether any reachable move breaks it, and where. A
constraint you want *enforced* goes in a `when`.

**Effects are simultaneous.** Every effect of one move reads the situation the
move started from, so `(do (set a.x b.y) (set b.y a.x))` is a swap and the order
of effects cannot be observed.

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

A `set` whose chain has no answer makes the move **absent** — which is how a
walker stops at the end of a ladder with no guard needed.

## Questions (`.claims`)

```lisp
(load "stdlib.pol")

(property finishes "the job can finish"
  (possible (is a.stage done)))

(property never-stuck "from anywhere, it can still finish"
  (live (is a.stage done)))

(query where-is "which machine holds what"
  (where (m machine)) (defined m.held-by))
```

`possible` / `never` / `live`. **`live` is the trap detector**: it asks whether
F stays reachable from *every* reachable situation, which is what "cannot paint
itself into a corner" means.

## Forms — the only way to abstract

```lisp
(form (idle M) => (not (defined M.held-by)))          ; a named guard
(form (job-of J E A L) => (enters J E) (advances J A) (leaves J L))
```

A form is **rename-and-paste**: no recursion, no computation, and it cannot map
over its `&rest`. At top level it may expand to several datums; *inside* a list
it must expand to exactly one.

A **domain library** is declarations only — a schema, an instance, forms — and
no `use`/`initial`/`transition`. Load it by relative path.

## No arithmetic, and what to do instead

Pol has no numbers, no recursion and no unbounded structures. That is the point:
it is what makes exhaustive search terminate.

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

Keep it **small**. The space is the product of every mutable cell; three jobs and
three machines is 51 situations, and adding a clock took it to 1314. If a model
will not finish, ask what the space *holds* before blaming the engine.
