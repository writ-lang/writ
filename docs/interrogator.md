
# Pol Interrogator — Relational Extension

An extension to the Pol interrogator: a **stratified, finite, witness-producing
rules engine** over a model's universe, and a **solver** that searches for
structure-preserving maps. Both are tooling — nothing here touches the
language, and no kernel word changes. Deleting any datum described in this
document changes what is asked of a model, never what the model is.

This document is **optional**: it is not part of the kernel spec's Part III,
and a conforming processor ([kernel spec §14](kernel-spec.md#14-conformance))
does not implement it. Section references of the form §N are to the kernel
spec; sections of this document are cited as *Extension §N*.

## 0. Position and contract

The kernel's promise is that every answer is a proof over a fully enumerated
finite space. This extension inherits that promise by construction:

1. **The universe is finite and closed.** Rules range over the model's
   schema objects, rosters, cell valuations, and — crucially — the *derived
   state category*: its situations and its edges
   ([§12.3](kernel-spec.md#123-the-generated-space)). Nothing else exists.
2. **Stratified fixpoints only.** Recursion through negation is rejected at
   read time (the standard stratification check). Least fixpoints over a
   finite universe terminate; answers are exact, never samples.
3. **Derivations are witnesses.** Every derived fact carries its derivation
   tree; the interrogator prints the tree on request. This extends the
   witness contract of [§15](kernel-spec.md#15-required-reporting) rather
   than replacing it — a modality witness is a route, a rule witness is a
   proof tree.
4. **No unification over compound terms.** The universe is atoms (elements,
   entities, situations, edge names). Variable binding is search over finite
   domains; equality is equality. General unification solves a problem this
   universe does not pose, and is deliberately absent.

**Recursion, and why it lives here.** The language deliberately has no
operator for "follow this arrow any number of times"
([§8.5](kernel-spec.md#85-chains)) — a chain is a literal finite word, which
is what keeps a model a finite presentation (Pivotal idea 3). This document
reintroduces recursion, and the two positions are consistent because they
apply to different objects: the language forbids it in *presenting* a model,
this engine permits it in *querying* the already-enumerated result. A rule
never adds a situation, an edge, or a cell (Extension §5).

## 1. The `.rules` file

A rules file is a third file type alongside `.pol`
([§6.1](kernel-spec.md#61-roles)) and `.claims`
([§16](kernel-spec.md#16-claims-files)). It shares Pol's reader
([§5](kernel-spec.md#5-lexical-structure)) and form expander
([§11](kernel-spec.md#11-forms)). It contains **relation declarations** and
**rules**, and may `load` libraries of rule forms.

```lisp
(relation subordinate 2)          ; name and arity

(rule (subordinate X Y)           ; head
  (is X.reports-to Y))            ; body: base case from the instance

(rule (subordinate X Y)           ; transitive closure — the recursion
  (is X.reports-to Z)             ; the language's paths deliberately
  (subordinate Z Y))              ; exclude; the tool is where it belongs
```

- A **declaration** is `(relation NAME ARITY)` — as above, and the common
  case — or `(relation NAME (T1 … Tn))`, which gives a **sort per column**:
  `Situation`, `Edge`, or a schema type name. Arity is then the list's length.
  The untyped form stays legal and needs no annotation wherever the columns
  can be typed from use; the typed form **seeds** each column's sort directly,
  and is required where nothing else can supply one. It is not optional
  sugar: arrow names are scoped to the type that owns them
  ([§7](kernel-spec.md#7-names)), so one name may be shared by several types,
  and a variable rooted in a shared arrow name — `X.at`, where both
  `traveler` and `cargo` own `at` — cannot be typed from the arrow. No
  built-in supplies an entity sort either, so without the annotation such a
  rule is unwritable. A typed column is checked like any other: a term
  resolving to a different sort is a conflict at that term.

  ```lisp
  (relation subordinate (person person))   ; the declaration above, typed
  (relation across (Situation cargo))      ; sorts may be mixed
  ```

- A **head** is a declared relation applied to variables or constants.
- A **body** is a conjunction of literals: kernel guards over paths
  (`is`, `defined`, and their boolean combinations —
  [§10.2](kernel-spec.md#102-guards)), declared relations, negated relations
  (`(not (R …))` — subject to stratification), and the built-in relations of
  Extension §2.
- Variables are implicitly typed by first use (a variable first appearing
  in an entity position of type T ranges over T's roster; in a situation
  position, over reachable situations; in an edge position, over
  transitions). A variable whose type cannot be inferred is an error at the
  variable. "First use" is resolved by a **program-wide least fixpoint** over
  `(relation, column) → sort`, not by a left-to-right pass: in the transitive
  closure above, `Y` occurs only in the head and in a sort-transparent
  relation literal, so nothing in that rule types it — it is typed by
  `subordinate`'s second column, learned from the other rule. A left-to-right
  reading would reject this section's own example. Constants never seed a
  sort; a constant in a sorted column is checked against it.
- Semantics: least fixpoint, computed bottom-up (semi-naïve), per stratum.

## 2. Built-in relations — the derived category as data

The rules engine exposes what the interrogator already computes. A
**situation** is the kernel's ([§12.1](kernel-spec.md#121-situations)); the
relations below are named for it.

| Relation             | Holds when                                              |
| -------------------- | ------------------------------------------------------- |
| `(situation S)`      | S is a reachable situation                              |
| `(init S)`           | S is the initial situation                              |
| `(edge E S1 S2)`     | transition named E maps situation S1 to situation S2    |
| `(holds S G)`        | guard G is true in S (G a closed guard datum)           |
| `(gap-edge E S)`     | transition E fires at S with no successor               |

Two consequences worth spelling out:

**The modalities become two-line derivations.** With

```lisp
(relation reach 2)
(rule (reach S S) (situation S))
(rule (reach S T) (edge E S M) (reach M T))
```

`possible F` is `(init S) (reach S T) (holds T F)`; `live F` is the absence
of a reachable situation from which no F-situation is reachable; `never F` is
the emptiness of possible's answer set. The interrogator keeps
`possible`/`live`/`never` as blessed claim vocabulary
([§16.1](kernel-spec.md#161-properties), which remains their normative
definition) — they are the common case and their witnesses print as move
routes — but the rules engine is the general instrument behind and beyond
them: bounded-step variants, "live-until", release/precedence patterns, and
any CTL-fragment question a domain needs become rule libraries and tool
releases, never language changes.

**Backward analysis is free.** `(edge E S1 S2)` is a relation, not a
function; querying it with the *second* argument bound runs the dynamics in
reverse: "which situations can reach this one", precondition inference,
abduction over the finite graph. This is relational programming's
run-it-backward move, obtained here by backward image over an enumerated
graph — no unification machinery required, because the graph is already
data.

## 3. `pol solve` — searching for structure-preserving maps

Functor checking ([§16.4](kernel-spec.md#164-dictionaries--functor-check--via))
verifies a hand-written map. Over finite schemas, functor *finding* is a
finite constraint problem — exactly what relational search does well. The
solver enumerates rather than verifies:

```bash
pol solve --functor SOURCE.pol TARGET.pol [--over T1 T2 …]
pol solve --simulation A.pol B.pol
```

These are the extension's two modes; `pol solve --morphism`, which searches
between two *instances* of one schema, is specified by the kernel spec
([§17](kernel-spec.md#17-comparison-search-and-export)) and is not repeated
here.

- `--functor` searches for total, dom/cod-preserving, semantically
  equation-preserving maps from the source schema (optionally restricted to
  a scope) to the target schema, and prints each as a ready-to-use map
  file — bare `(map X => Y)` datums. **Zero solutions is itself a
  finding**: no compliant reading of this structure in the target's terms
  exists, reported with the obstruction (the first unmappable arrow or the
  first equation no assignment preserves).
- `--simulation` runs the same search between two models' control quivers
  (as exported by `pol control`, [§17](kernel-spec.md#17-comparison-search-and-export)):
  every move of A assigned a counterpart in B, preserving src/tgt —
  comparison by move structure, discovered rather than declared.

Search is plain finite backtracking with the checks as propagators; answers
are complete (all maps, or provably none), and each carries its check
transcript as witness.

## 4. Command line

```bash
pol derive  MODEL.pol RULES.rules RELATION
pol derive  MODEL.pol RULES.rules "(RELATION ARG…)"      # bound query
pol derive  MODEL.pol RULES.rules --why "(RELATION ARG…)" # derivation tree
pol solve   --functor SOURCE.pol TARGET.pol [--over T1 T2 …]
pol solve   --simulation A.pol B.pol
```

```bash
pol derive oversight.pol org.rules subordinate            # all rows
pol derive oversight.pol org.rules "(subordinate nabu X)" # bound query
pol derive oversight.pol org.rules --why "(subordinate nabu cabinet)"
```

Exit status follows the kernel spec's per-flag rule
([§18](kernel-spec.md#18-command-line)): a search exits `1` for "nothing
found" only where the absence is the bad news. For both `pol solve` modes
here it is — zero solutions exits `1` with the obstruction — which is the
opposite of `pol solve --morphism`, where finding nothing is an ordinary
negative answer and exits `0`. The two flags ask different questions.
`pol derive` exits `0` for any well-formed query, empty answer set included:
an empty relation is an answer. Unreadable input is `2` throughout.

## 5. What is deliberately absent

- **General unification and compound terms.** The universe is atoms; there
  are no term structures to partially instantiate. If the kernel ever gains
  open rosters (entity creation under a scope bound) or structured values,
  answers-with-variables start paying rent and this decision should be
  revisited — as a search engine for "up to scope N" questions, still
  tool-side. Recorded here so the decision is remembered as conditional,
  not dogmatic.
- **Unbounded streams and fair interleaving.** These exist to search
  infinite spaces fairly. This universe has no infinite spaces
  ([§12.4](kernel-spec.md#124-finiteness)).
- **Rules as model content.** A rule never adds a situation, an edge, or a
  cell. The engine derives facts *about* the model; the model is presented
  only in the language.
- **Arithmetic.** Still no numbers ([§8.2](kernel-spec.md#82-type)). Counting
  questions ("at least two independent bureaus") are finite disjunctions a
  form can spell out.

## 6. Theory note — the principled query algebra

For Ologs, the categorically native query story is not relational
programming but the **data-migration adjoint triple** Δ ⊣ Σ ⊣ Π: queries as
functors between schemas, answers as migrated instances. That triple is the
kernel spec's own reading of migration
([Appendix I.6](kernel-spec.md#i6-adjunctions)), where Δ is `pol migrate
--along` and Σ and Π are the adjoints not yet exposed as verbs.

Over finite instances, those migrations and stratified Datalog meet in
expressive power for the questions this tool asks; Datalog is adopted here
as the pragmatic engine with the better witness story (derivation trees). If
the interrogator ever grows a full query algebra, the adjoint triple is the
theory to reach for, with this engine underneath.
