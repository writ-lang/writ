# Schemas as data — a design note

*Status: the encoding is in `stdlib.pol` §6; no emitter exists. Depends on the relational
extension landing first (see "Sequencing").*

Pol already writes one part of itself in itself. `pol control MODEL`
(kernel §17) emits a model's move list as an **instance of the standard
library's `quiver` schema** — the dynamics, as ordinary Pol data. The
payoff is visible in the relational extension: `pol solve --simulation`
is not a bespoke algorithm, it is the ordinary map search run between two
quiver-instances. One special verb became an instance of a general one.

This note asks what happens if the same move is made one level up: **let
a schema be an instance too.**

## The encoding

One schema, whose instances are schemas:

```lisp
(schema olog
  (type ob)                                   ; objects = types
  (type hom                                   ; morphisms = arrows
    (arrow dom (to ob) fixed)
    (arrow cod (to ob) fixed))
  (type chain                                 ; a chain, as a linked list
    (arrow head (to hom) fixed)
    (arrow tail (to chain) fixed vacatable))  ; vacant tail = end of chain
  (type eqn
    (arrow lhs (to chain) fixed)
    (arrow rhs (to chain) fixed)))
```

The only subtle part is `chain`, named for the kernel's own term. A chain
is a sequence of arrows, and Pol has no lists and no recursion —
deliberately (§8.5, Pivotal idea 3). But it does not need them: the chains
of a *given* schema are finite and known, so one is rostered as a linked
list, and the empty tail is a `vacant` slot. The recursion lives in the
**data**, which is enumerated, never in the language, which stays
first-order. This is the eaten goat of
Appendix C wearing a different hat — absence as a first-class value
(Pivotal idea 1) is what closes the list.

Everything is `fixed`, so a schema-as-instance has exactly one situation.
That is the right answer: a schema does not change over world-time. Its
changes are commits (§6.3).

## It works, and it closes

The kernel spec's own §4 running example, written as data — types,
arrows, and the `same-agency` equation as two chains sharing a tail:

```lisp
(instance oversight-as-data (of olog)
  (ob   indep-status stage-t person bureau case)
  (hom  employer independence stage investigator prosecutor judge)
  (chain p-inv p-pro p-ind)
  (eqn  same-agency)
  (dom  (employer person) (independence bureau) (stage case)
        (investigator case) (prosecutor case) (judge case))
  (cod  (employer bureau) (independence indep-status) (stage stage-t)
        (investigator bureau) (prosecutor bureau) (judge person))
  (head (p-inv investigator) (p-pro prosecutor) (p-ind independence))
  (tail (p-inv p-ind) (p-pro p-ind) (p-ind vacant))
  (lhs  (same-agency p-inv))
  (rhs  (same-agency p-pro)))
```

`pol check` reports `states: 1  edges: 0`.

And the encoding **closes on itself** — `olog` is expressible as an
instance of `olog`, with `ob = {ob, hom, chain, eqn}` and
`hom = {dom, cod, head, tail, lhs, rhs}`. That also builds. Nothing a
schema contains needs a construct the encoding cannot carry, and the
demonstration is the schema describing its own six arrows.

This is the closest thing Pol has to a metacircular definition, and it is
the honest version of the "Maxwell's equations" analogy. McCarthy's
`eval` bought *universal computation*; Pol must refuse that, because
decidability by exhaustion is the whole product (idea 3). What Pol can
have is the other half of the same insight: a description of itself, in
itself, short enough to read.

## What it buys

The tooling surface, verb by verb.

**Schema maps stop being special.** A dictionary (§16.4) is checked three
ways. Under the encoding, two of the three stop being bespoke:

| §16.4 check | becomes |
| --- | --- |
| **totality** — nothing in scope untranslated | an instance homomorphism is total on rostered entities |
| **shape** — an arrow's translation runs between the translations of its endpoints | *literally the naturality square* for `dom` and `cod` |
| **laws** — the image of each equation holds in the target | stays special: semantic, not structural |

The middle row is the point. "Shape" says
`dom(F a) = F(dom a)` and `cod(F a) = F(cod a)`; as olog-instances with
components `α_ob` and `α_hom` that is `α_ob ∘ dom_X = dom_Y ∘ α_hom` —
naturality, which the interrogator already searches for
(`pol solve --morphism`, Appendix I.3). Two of three checks fall out of
machinery that exists.

**`solve --functor` collapses into `solve --morphism`.** The extension's
schema-level search and the kernel's instance-level search are the same
search once schemas are instances. Two verbs, one implementation.

**`compare` becomes a query.** Two versions of a schema are two
olog-instances; preserved / lost / gained is set difference over their
rosters, which is a `.rules` query with a derivation tree for a witness —
rather than a report format only the tool knows how to produce.

## What it does not buy

**No new worlds become modellable.** This is an economy of the *tooling*,
not an increase in expressive power. Every model writable after is
writable before. Worth being blunt about, because "homoiconicity" invites
the opposite assumption.

**Equations only half-reduce.** Equation *representation* works (the
`eqn` type above). Equation *preservation* is semantic — §16.4 evaluates
it against the target's instance and marks the result `semantic` for
exactly this reason. Naturality does not reach it, so that check stays
bespoke.

**It costs a verb to save several.** The olog-instance has to be
produced, so something like `pol schema MODEL` joins `pol control`. That
is the honest ledger: +1 emitter, and several checkers become one.

**Two readings of one name.** `case` is a type in the schema and an
entity in the olog-instance. Lisp needs `quote` to manage this; Pol
should not get one. The discipline that replaces it is the rule
`pol control` already follows: **the olog-instance is derived, never
authored.** Nobody hand-writes `oversight-as-data`; the tool emits it.
Keep that and the level confusion stays in the tool, where it is a
serialization format, not in the language, where it would be a second way
to say the same thing.

## Why it does not disturb the seven ideas

- **Idea 3 (a small text denotes a large, fully known object)** — untouched.
  The olog-instance is finite; the linked list is roster data, and the
  situation space of a schema-as-data is a single point.
- **Idea 4 (definition and interrogation are separate)** — untouched,
  *provided* the instance is derived. A model still contains no questions;
  the olog-instance is an artifact, like the quiver export.
- **Idea 7 (vocabulary grows, meaning does not)** — this is the idea the
  note is in service of. `olog` is a stdlib schema, exactly like `quiver`.
  **It adds no kernel word.** The move is subtraction: several tooling
  verbs become instances of one, which is McCarthy's actual method as
  opposed to his famous result.

## Sequencing

1. **Wait for the relational extension.** The query layer this note leans
   on — "which arrows lost their image", "which equations survive" — is a
   `.rules` query. Doing this first would mean hand-writing report code
   that the rules engine then replaces.
2. **~~Add `olog` to the standard library~~ — done.** It sits in
   `stdlib.pol` §6, beside `quiver`. It is a schema and nothing else, so
   it cost nothing to ship early and gives the encoding somewhere to
   live. Note the price paid: `ob`, `hom`, `chain` and `eqn` are now
   reserved for every model that loads stdlib (§7), the same standing
   cost `quiver` already carries for `node` and `edge`.
3. **Add the emitter** (`pol schema MODEL`), and check the round trip:
   emit `olog` itself and confirm it matches the hand-written
   `olog-as-data` above. That is the regression test for the whole idea.
4. **Re-express one existing verb** — `compare` is the best candidate —
   as a rules query over two olog-instances. If that reads well, migrate
   `--functor`. If it does not, stop: the encoding is still a useful
   export format even if no verb collapses.

**Do not delete the existing verbs.** Let the general path arrive first
and the special ones become thin wrappers, the way `all` lives in stdlib
while `some` stays in the kernel.
