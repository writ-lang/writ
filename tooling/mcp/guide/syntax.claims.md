A `.claims` file holds the questions about one model, kept apart from it so an edit to the model cannot quietly change what is asked. It is read against the model: its chains are typed by the model's schema. Same lexical rules as `syntax.model`.

## Grammar

```
claims      ::= (load-d | form-d | property-d | query-d | accept-d)…

property-d  ::= (property NAME "DESCRIPTION" (MODALITY guard [fair-d]) [show-d])
MODALITY    ::= possible | never | live | inevitable
fair-d      ::= (fair MOVE…)                   ; only after an inevitable formula
show-d      ::= (show QUERY…)                  ; queries of this file, answered where the verdict points

query-d     ::= (query NAME (where (VAR TYPE)…) guard)    ; no description string
accept-d    ::= (accept MOVE LAW…)             ; this move is known to be able to break these laws
```

The guard is the model's guard language (`syntax.model`), including forms; load `stdlib.writ` here too if you use `all`, `differ` or `=`.

## The four property kinds

| kind | holds when | a failure shows |
| --- | --- | --- |
| `(possible F)` | some reachable situation satisfies F | nothing exists to show; a hold carries the route to F |
| `(never F)` | no reachable situation satisfies F | the shortest route to an F situation |
| `(live F)` | from every reachable situation, some F situation is still reachable | `stuck at:` a situation from which F is gone for good, and its route |
| `(inevitable F)` | no run avoids F for ever (every run reaches F) | `stuck at:` where a run can avoid F, and its route |
| `(inevitable F (fair M…))` | the same, ignoring runs in which a named move is offered again and again and never taken | as above |

There is no `always`, `eventually` or `exists`. Translate:

| you mean | write |
| --- | --- |
| P always holds; P is an invariant | `(never (not P))` |
| X can never happen | `(never X)` |
| X can happen; there is a schedule that does X | `(possible X)` (its witness is the schedule) |
| X can always still happen; no trap; can always recover | `(live X)` |
| X eventually happens; it terminates; it cannot be put off for ever | `(inevitable X)` |
| …provided the network/scheduler does not starve move M | `(inevitable X (fair M))` |

## Example

```lisp
(load "stdlib.writ")
(property finishes "the job can finish"
  (possible (is a.stage done)))
(property never-stuck "from anywhere it can still finish"
  (live (is a.stage done)))
(property must-finish "no run goes on for ever without finishing"
  (inevitable (is a.stage done) (fair a-finish))
  (show holder))
(property exclusive "the machine never has two jobs running"
  (never (and (is a.stage running) (is b.stage running))))
(query holder (where (m machine)) (defined m.held-by))
(accept a-finish one-holder)
```

## Rules

- A property needs its description string; a query must not have one. Either mistake rejects the whole file (`E_MALFORMED`).
- F may use `some` and `all` (stdlib); its variables head chains, as in the model.
- `(fair …)` names **moves** (transitions), so name your moves. Naming a move the model lacks makes the property `n/a`.
- `(show Q…)` answers the named queries at the situation the verdict singles out: the stuck situation of a failing `live` or `inevitable`, the violating one of a failing `never`, the satisfying one of a holding `possible`.
- A query answers the set of bindings that satisfy its guard, at the initial situation (or at `at` in `writ_query`). Its guard can test a cell (`(defined m.held-by)`, `(is j.stage done)`) but a bare variable cannot be a value: to ask *what a cell holds*, use `.rules` (`syntax.rules`).
- `accept` acknowledges that a move can break a law. A move that can break a law without an `accept` is reported `unadmitted`; an `accept` for a move that cannot is `stale`. Both make `writ_check` fail, as a failing property does. Violations are still reported.
- A property that names an arrow, value, type or move the model lacks is `n/a`: a failure, never a pass.
