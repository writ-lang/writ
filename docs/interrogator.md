# Writ Interrogator — Relational Extension

A stratified, witness-producing **rules engine** over a model's finite
universe, and a **solver** for structure-preserving maps. Both are optional
tooling ([kernel spec §14](kernel-spec.md#14-conformance)) and change no kernel
word. §N refers to the kernel spec; sections here are *Extension §N*.

## 0. Position and contract

Every answer stays a proof over a fully enumerated finite space:

1. **The universe is finite and closed**: the schema's objects, rosters, cell
   valuations, and the state category's situations and edges
   ([§12.3](kernel-spec.md#123-the-generated-space)).
2. **Stratified fixpoints only.** Recursion through negation is rejected at
   read time; answers are exact.
3. **Derivations are witnesses**: a rule's proof tree, as a modality's route
   is ([§15](kernel-spec.md#15-required-reporting)).
4. **No unification over compound terms.** The universe is atoms; binding is
   search over finite domains.

Models cannot recurse ([§8.5](kernel-spec.md#85-chains)); rules can, because
they only query the enumerated result and never add a situation, edge or cell
(Extension §5).

## 1. The `.rules` file

A third file type beside `.writ` ([§6.1](kernel-spec.md#61-roles)) and
`.claims` ([§16](kernel-spec.md#16-claims-files)), with the same reader
([§5](kernel-spec.md#5-lexical-structure)) and forms
([§11](kernel-spec.md#11-forms)), holding relation declarations and rules.

```lisp
(relation subordinate 2)          ; name and arity

(rule (subordinate X Y)           ; head
  (is X.reports-to Y))            ; body: base case from the instance

(rule (subordinate X Y)           ; transitive closure — the recursion
  (is X.reports-to Z)             ; the language's paths deliberately
  (subordinate Z Y))              ; exclude; the tool is where it belongs
```

`(load "ct.rules")` brings the standard rules library: `reach`, `mutual`
(strongly connected classes), `before` and `one-way` (irreversible steps, by
situation and by move), `final-phase` and `dead-end`.

- A **declaration** is `(relation NAME ARITY)`, or `(relation NAME (T1 … Tn))`
  to sort each column as `Situation`, `Edge` or a schema type. Use the typed
  form when an arrow name is shared by several types
  ([§7](kernel-spec.md#7-names)) and so cannot type its root.

  ```lisp
  (relation subordinate (person person))   ; the declaration above, typed
  (relation across (Situation cargo))      ; sorts may be mixed
  ```

- A **head** is a declared relation applied to variables or constants.
- A **body** is a conjunction of kernel guards
  ([§10.2](kernel-spec.md#102-guards)), relations, negated relations
  `(not (R …))`, and the built-ins of Extension §2.
- **A variable is an ALL-CAPS atom**; anything else is a constant. A model
  name spelled in capitals (`KNIGHT`) would read as a variable, so a rule that
  uses one is rejected at the atom.
- **Variables are typed by use** — a roster, the reachable situations, or the
  transitions — through a program-wide fixpoint over `(relation, column) →
  sort`, so `Y` above is typed from the other rule. An untypable variable is an
  error; constants are checked, never seeding a sort.
- **A body joins in written order.** Positive relations, built-ins and a
  top-level `(is PATH V)` bind variables; a negation or test may only use
  variables bound before it. An unbound variable is rejected where it occurs.
- **`(is PATH PATH)` compares two paths** in the same situation, as the
  kernel's chain-against-chain test does, so a form like stdlib's `differ`
  over two cells reads the same in `.rules` as in a claims file. It only
  tests, never binds, and two paths that land in different types are
  rejected: they could never be equal.
- Semantics: semi-naïve least fixpoint, per stratum; recursion through
  negation has no stratum order and is rejected at read time.
- A `.rules` file may `load` libraries: their forms expand here too, and
  their schemas are skipped.

In a rule, the right of `is` is a variable or constant, not a chain. Equate
two chains with a shared variable:

```lisp
(rule (conflict C) (is C.approver P) (is C.preparer P))
```

## 2. Built-in relations — the derived category as data

A **situation** is the kernel's ([§12.1](kernel-spec.md#121-situations)).

| Relation             | Holds when                                              |
| -------------------- | ------------------------------------------------------- |
| `(situation S)`      | S is a reachable situation                              |
| `(init S)`           | S is the initial situation                              |
| `(edge E S1 S2)`     | transition named E maps situation S1 to situation S2    |
| `(holds S G)`        | guard G is true in S (G a guard datum, not a variable)  |
| `(gap-edge E S)`     | transition E fires at S with no successor               |
| `(phase S P)`        | P names the phase S belongs to                          |
| `(phase-step P Q)`   | some move leads out of phase P into phase Q, P ≠ Q      |

A **phase** is a class of mutually reachable situations; a step between
phases can never be walked back. P is the phase's least-indexed situation, so
it joins with the other relations directly. Phases are built in because they
take one linear pass, where deriving them from `reach` is quadratic; `reach`
and `before` stay quadratic since their answers are pairs. `phase-step` also
needs inequality on atoms, which rules lack.

These names are reserved: a `.rules` file cannot declare a relation called
`edge`, `phase` or any other built-in.

`(holds S G)` takes a guard datum, not a term. Its free variables are the
rule's, so `(holds S (is X.a Y))` finds where a mutable arrow points in S.

**Modalities are two-line derivations.** With

```lisp
(relation can-reach 1)
(rule (can-reach S) (holds S F))            ; the goal set itself
(rule (can-reach S) (edge E S T) (can-reach T))   ; and a move into it
```

`possible F` is `(init S) (can-reach S)`; `live F` is the absence of a
reachable situation outside `can-reach`; `never F` is the emptiness of
`(situation S) (holds S F)` — one backward pass, where going forward through
`reach` is quadratic. The claims modalities stay normative
([§16.1](kernel-spec.md#161-properties)); rules add the variants a domain needs.
Binding the second argument of `edge` runs the dynamics backward.

## 3. `writ solve` — searching for structure-preserving maps

Functor checking ([§16.4](kernel-spec.md#164-dictionaries--functor-check--via))
verifies a map; `writ solve` finds them.

```bash
writ solve --functor SOURCE.writ TARGET.writ [--over T1 T2 …]
writ solve --simulation A.writ B.writ
```

(`writ solve --morphism`, between two instances of one schema, is specified in
[§17](kernel-spec.md#17-comparison-search-and-export).)

- `--functor` finds every total, equation-preserving schema map (optionally
  over the `--over` types) and prints each as `(map X => Y)` datums. Zero
  solutions is a finding, reported with the first obstruction.
- `--simulation` does the same between two models' control quivers
  (`writ control`), matching every move of A to one of B.

Answers are complete — all maps, or provably none — each with its check
transcript.

## 4. Command line

```bash
writ derive  MODEL.writ RULES.rules RELATION
writ derive  MODEL.writ RULES.rules "(RELATION ARG…)"      # bound query
writ derive  MODEL.writ RULES.rules --why "(RELATION ARG…)" # derivation tree
writ solve   --functor SOURCE.writ TARGET.writ [--over T1 T2 …]
writ solve   --simulation A.writ B.writ
```

```bash
writ derive oversight.writ org.rules subordinate            # all rows
writ derive oversight.writ org.rules "(subordinate nabu X)" # bound query
writ derive oversight.writ org.rules --why "(subordinate nabu cabinet)"
```

A situation is written as its bare index — the numbering `writ show --at N`
uses — in answers and in bound queries alike. `writ derive` computes only the
asked relation and its dependencies. Exit
status ([§18](kernel-spec.md#18-command-line)): `writ solve` exits `1` on zero
solutions; `writ derive` exits `0` for any well-formed query, empty included;
unreadable input is `2`.

## 5. What is deliberately absent

- **Unification and compound terms** — the universe is atoms (revisit if
  rosters ever become open).
- **Streams and fair interleaving** — no space is infinite
  ([§12.4](kernel-spec.md#124-finiteness)).
- **Rules as model content** — a rule never adds a situation, edge or cell.
- **Arithmetic** — no numbers ([§8.2](kernel-spec.md#82-type)); counting is a
  finite disjunction.

## 6. Theory note

The native query algebra for ologs is Δ ⊣ Σ ⊣ Π
([Appendix I.6](kernel-spec.md#i6-adjunctions); Δ is `writ migrate --along`).
Over finite instances Datalog matches it for these questions and gives better
witnesses.
