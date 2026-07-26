# Schemas as data — a design note

*Status: **implemented**. The encoding is `stdlib.pol` §7 and `pol schema
MODEL` emits it (kernel §17). What changed since the note was written — laws
became guards, so an equation is no longer a pair of chains — is recorded
under "What the encoding lost, and why that is fine".*

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
  (type ob)                          ; objects = types
  (type hom                          ; morphisms = arrows
    (arrow dom (to ob) fixed)
    (arrow cod (to ob) fixed))
  (type eqn))                        ; laws, by name only
```

Arrow names are scoped to their dom (§7), so two types may each own a
`status`. Entity names in the emitted instance are not scoped, so the
emitter gives each `hom` a name — `dom-arrow`, freshened until it collides
with nothing. What identifies an arrow here is `dom` and `cod`, not its
spelling.

Everything is `fixed`, so a schema-as-instance has exactly one situation.
That is the right answer: a schema does not change over world-time. Its
changes are commits (§6.3).

## It works, and it closes

The kernel spec's own §4 running example, as `pol schema` emits it —
no longer hand-written:

```lisp
(instance oversight-schema (of olog)
  (ob indep-status stage-t person bureau case)
  (hom person-employer bureau-independence case-stage
       case-investigator case-prosecutor case-judge)
  (eqn same-agency)
  (dom (person-employer person) (bureau-independence bureau) (case-stage case)
       (case-investigator case) (case-prosecutor case) (case-judge case))
  (cod (person-employer bureau) (bureau-independence indep-status)
       (case-stage stage-t) (case-investigator bureau)
       (case-prosecutor bureau) (case-judge person)))
```

Re-checked, that reports `states: 1  edges: 0` — the right answer, since
every arrow of `olog` is `fixed` and a schema does not change over
world-time.

And the encoding **closes on itself**. Point the emitter at a model whose
schema is `olog` and it prints `olog`:

```lisp
(instance self-schema (of olog)
  (ob ob hom eqn)
  (hom hom-dom hom-cod)
  (dom (hom-dom hom) (hom-cod hom))
  (cod (hom-dom ob) (hom-cod ob)))
```

Machine-produced, not hand-written, which is the difference between a claim
and a test — and it is one, in `test_schema_data.ml`.

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

## What the encoding lost, and why that is fine

The note was written while an equation was `(= CHAIN CHAIN)`, and the first
version of `olog` encoded exactly that: a `chain` type as a linked list, and
an `eqn` with `lhs` and `rhs`. Then laws became guards (`docs/law-as-guard.md`)
and that shape stopped describing the language it claims to describe.

The encoding now carries laws **by name only**. Encoding a guard body would
mean a second tree construction — booleans, `some` binders, n-ary operands —
and it would buy nothing, because the two checks this export exists to
collapse read only `dom` and `cod`, and the third is semantic however it is
represented. The claim "the encoding closes" is therefore narrower than it
was: everything a schema contains is representable **except a law's body**,
which is declined on purpose rather than missed.

The linked-list trick that made `chain` work is gone with it. It was the
prettiest part of the note — recursion living in the roster while the language
stays first-order — and it is worth recording that it was correct and is
simply no longer needed.

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
   `stdlib.pol` §7, beside `quiver` (§3). It is a schema and nothing else, so
   it cost nothing to ship early and gives the encoding somewhere to
   live. Note the price paid: `ob`, `hom`, `chain` and `eqn` are now
   reserved for every model that loads stdlib (§7), the same standing
   cost `quiver` already carries for `node` and `edge`.
3. **~~Add the emitter~~ — done.** `pol schema MODEL` (kernel §17), with the
   round trip as its test: emit `olog` itself and confirm it describes its own
   two arrows. `test_schema_data.ml` also pins the §7 fresh-name discipline,
   which is where this export can actually go wrong — two arrows sharing a
   name collapsing onto one `hom` entity reads fine and is then refused by the
   front end.
4. **Re-express one existing verb** — `compare` is the best candidate —
   as a rules query over two olog-instances. If that reads well, migrate
   `--functor`. If it does not, stop: the encoding is still a useful
   export format even if no verb collapses.

**Do not delete the existing verbs.** Let the general path arrive first
and the special ones become thin wrappers, the way `all` lives in stdlib
while `some` stays in the kernel.
