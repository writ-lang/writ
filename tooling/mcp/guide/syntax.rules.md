A `.rules` file holds Datalog-style relations over a model's enumerated space, asked with `writ_derive`. Use it for what claims cannot say: *what* a cell holds where (a claims guard can only test it), closures such as "reports to, transitively", and custom modalities. Rules never add a situation, edge or cell. Same lexical rules as `syntax.model`.

## Grammar

```
rules       ::= (load-d | form-d | relation-d | rule-d)…

relation-d  ::= (relation NAME ARITY)                    ; columns typed by use
              | (relation NAME (SORT…))                  ; or typed explicitly
SORT        ::= Situation | Edge | TYPE                  ; TYPE: a schema type
rule-d      ::= (rule (NAME term…) literal…)             ; head, then body (a conjunction)
term        ::= VAR | CONSTANT                            ; VAR is ALL-CAPS; anything else a constant
literal     ::= (NAME term…)                             ; a declared relation
              | (not (NAME term…))                       ; negation of a declared relation
              | builtin
              | kernel guard over constants and variables ; (is X.arrow V), (is X.a Y.b), (defined X.arrow), …
```

## Built-in relations

| relation | holds when |
| --- | --- |
| `(situation S)` | S is a reachable situation |
| `(init S)` | S is the initial situation |
| `(edge E S1 S2)` | the move named E leads from S1 to S2 |
| `(holds S G)` | guard G (a guard datum, not a variable) is true in S; G's variables are the rule's |
| `(gap-edge E S)` | move E fires at S with no successor (a `gap`) |
| `(phase S P)` | S belongs to phase P: a class of mutually reachable situations, named by its least index |
| `(phase-step P Q)` | some move leads out of phase P into a different phase Q |

These names are reserved. `(load "ct.rules")` adds `reach`, `mutual`, `recurrent`, `before`, `phase-before`, `one-way`, `escapes`, `final-phase`, `moves` and `dead-end`.

## Example

```lisp
(relation holder (Situation machine job))
(rule (holder S M J) (situation S) (holds S (is M.held-by J)))

(relation can-finish 1)
(rule (can-finish S) (situation S) (holds S (is a.stage done)))
(rule (can-finish S) (edge E S T) (can-finish T))

(relation trapped 1)
(rule (trapped S) (situation S) (not (can-finish S)))

(relation sharing (job job))
(rule (sharing J K) (is J.uses M) (is K.uses M) (is J.uses K.uses))
```

`writ_derive` with relation `holder` and args `[null, "m1", null]` lists every situation index and the job holding `m1` there; with `why: true` and every argument given it returns the derivation tree. A situation is written as its bare index, the one `writ_show` takes.

## Rules

- A variable is an ALL-CAPS atom; a model name spelled in capitals would read as a variable and is rejected.
- A body joins in written order. Relations, built-ins and a top-level `(is PATH V)` bind variables; `not` and tests may only use variables bound before them.
- `(is PATH V)` with a variable V binds V to what the path holds. `(is PATH PATH)` compares two paths: it only tests, so both roots must be bound before it, and two paths landing in different types are refused. To bind a value two paths share, use one variable: `(is C.approver P) (is C.preparer P)`.
- Recursion is allowed; recursion through `not` is rejected (`E_RULES`). The answer is the least fixpoint, computed stratum by stratum.
- `holds` does not bind its situation: put `(situation S)` (or `edge`, `init`) before it. It does bind the guard's variables, so `(situation S) (holds S (is X.a Y))` binds Y to what `X.a` holds in S: the thing a claims query cannot do.
- `reach` and `before` are quadratic in the number of situations; prefer a backward relation like `can-finish` above, which is linear.
