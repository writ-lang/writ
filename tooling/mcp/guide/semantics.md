What each construct means, precisely. Read this before choosing a property kind.

## 1. Situations

A **situation** is one assignment of a value to every mutable cell (every entity × non-`fixed` arrow), a vacatable cell possibly `vacant`. Two situations are equal when every mutable cell holds the same value. Fixed cells (the wiring) are the same in all of them and are not part of a situation. The set of possible situations is the product of the cells' domains; the space writ builds is the part reachable from the initial one.

## 2. The initial situation

There is exactly one: the instance named by `(initial …)`. It is index `0`.

## 3. Moves

- A move is **enabled** in a situation when its `when` guard is true there. A guard is evaluated in that one situation; `is` is false when either side has no answer.
- Firing a move applies all of its effects at once, each reading the situation the move started from. The result is the next situation, or, if a `gap` fires, no situation: a **gap edge** out of the model.
- A `set` whose target or right side has no answer makes the move **absent** there: no edge at all.
- One step fires exactly one enabled move. Several enabled moves are nondeterministic alternatives, and writ explores every one: concurrency is interleaving, and there is no synchronous step and no built-in scheduler.
- A move whose effects change nothing is an edge back to the same situation.

## 4. The property kinds

Let R be the reachable situations and F the formula. A **run** is a maximal path: it goes on for ever, or it stops at a situation with no enabled move, or at one whose only moves are gaps.

| kind | meaning | sort |
| --- | --- | --- |
| `(possible F)` | some s in R satisfies F | reachability |
| `(never F)` | no s in R satisfies F | safety (an invariant is `(never (not P))`) |
| `(live F)` | for every s in R, some situation reachable from s satisfies F | recoverability: no trap |
| `(inevitable F)` | from every s in R, every run reaches F | liveness: termination, must-happen |
| `(inevitable F (fair M…))` | the same, ignoring runs in which a named move is enabled infinitely often and never taken | liveness under strong fairness |

There is no fairness unless you write `(fair …)`, and it only ever names moves. A run that stops is never unfair, so fairness cannot rescue a deadlock. `inevitable` implies `live` and `live` implies `possible` (from the initial situation); the gap between `live` and `inevitable` is a world that can always still reach F and need never do it.

## 5. Laws and properties

A law, `(equation NAME GUARD)` in the schema, is checked in every reachable situation but never restricts a move. `writ_check` reports, per law, the moves that **can break it** (a conservative analysis: any move that writes a cell the law reads), the reachable situations that **violate** it, and the shortest route to one. "A law can be broken" means a reachable situation violates it. To make a rule hold, put it in the moves' `when` guards; to ask whether it holds, write a `never` property. In claims, `(accept MOVE LAW)` records a known breaker; an unacknowledged breaker is reported `unadmitted` and fails the check.

## 6. Gaps and dead ends

A **gap** is a declared silence, `(gap "MSG")`: the model says its rules do not cover what happens next. A **dead end** is a reachable situation with no enabled move (a gap does not count as a move). Neither is an error: the report counts dead ends with a route to each, because only you know whether an ending is the goal or a deadlock. Say which with `(inevitable GOAL)`: an ending that is not GOAL then fails with a route.

## 7. n/a

A property is `n/a` when it cannot be asked of this model. It is a **failure**: the check fails as it does for `fails`, and `writ_check` adds a `why n/a` line naming what is missing. Causes:

- its formula names an arrow the type lacks: `(is a.colour red)` when `job` has no `colour`;
- it compares with a value outside the type: `(is a.stage finished)` when `stage-t` has no `finished`;
- it names a type the schema lacks in `some` or `all`;
- its `(fair M)` names a move the model lacks.

After an edit, a property that became `n/a` counts as LOST. Never make a check pass by deleting what a question asks about.

## 8. Witnesses

The space is built breadth-first, so every route printed is a shortest one (fewest moves). Among equally short routes, writ reports the first found: moves are tried in the order they are declared, situations in index order. A `fails` for `never` shows the route to the violating situation; for `live` and `inevitable` it shows `stuck at:` the nearest situation from which F is unreachable (`live`) or avoidable for ever (`inevitable`), with the route *to* it. That route is empty when the stuck situation is `#0`. A failing `inevitable` then says how a run avoids F from there: `avoids: the run stops at #N` (no move left), `loop:` a shortest cycle back to it, or, under `(fair …)`, `loops among:` the situations a fair run circles in. A holding `possible` shows the route to the nearest F situation: that route is the answer to "is there a way".

## 9. Indices

Situation `#N` is the N-th situation discovered breadth-first. The search is deterministic, so the same source gives the same numbering on every run, and `writ_show` re-enumerates to resolve an index. Almost any edit renumbers: a new or reordered move, a new value, a changed guard. Never carry an index from one version of a model to another: re-run `writ_check` on the new source and take its indices.

## 10. Rules

A `.rules` program is evaluated to its least fixpoint over the finite space, stratum by stratum; negation must be stratified (no recursion through `not`), so every answer is exact. `writ_derive` with `why: true` returns a derivation tree: the rule used at each step, down to built-in facts about situations, edges and cells. It proves the fact is derivable; it does not prove that nothing else is.

## 11. writ_compare

Both models are built. The old model's claims are put to both, and properties are matched **by name**. Each row is:

- `preserved`: passes in both;
- `LOST`: passes in the old and fails or is `n/a` in the new; the row carries the route through the new model that breaks it;
- `gained`: fails in the old, passes in the new.

A property that fails in both is no row; a closing `still failing in both models:` line names it, so an edit that fixed nothing does not look clean.

Laws (equations) are matched by name and meaning: a law deleted or rewritten is LOST. `writ_check` given the same claims path, or the same `model_name` with inline sources, prints the same comparison against the previous check as a `revision:` block. That history lives in the server process: it is lost when the server restarts, and a client that starts a server per call never sees it; use `writ_compare` then.
