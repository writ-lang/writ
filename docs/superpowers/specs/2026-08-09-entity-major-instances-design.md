# Entity-major instance clauses

*2026-08-09 — design, approved. Status: not yet implemented.*

## The problem

An instance body has two clause shapes that look identical:

| Clause | Shape | Example |
| --- | --- | --- |
| roster | `(TYPE ENTITY…)` | `(book hamlet)` |
| valuation | `(ARROW (ENTITY V)…)` | `(status (hamlet available))` |

Both are `(name …)`. Nothing marks which is which: the reader must already know
whether the head names a type or an arrow. `decode_instance`
(`core/syntax/decl.ml`) resolves the head by trying `Schema.type_of` first and
falling back to an arrow lookup — the ambiguity is in the language, not just in
the reader's head.

Two further consequences, both verified against the current binary:

- A valuation is **arrow-major**: a column. The reader thinks row-wise ("hamlet
  is a book, available"); the syntax is written column-wise ("the `status`
  column: hamlet ↦ available").
- Because arrow names are scoped per type (§7), one valuation clause can
  silently span two unrelated arrows that happen to share a name:
  `(status (hamlet available) (ana on-duty))` sets `book.status` and
  `librarian.status` in one clause. This builds today.

The tool's own output has the same defect. `pol schema` emits `dom` and `cod`
as parallel lists that the reader must join by name:

```lisp
(dom (person-member-of person) (book-home book) (book-status book) …)
(cod (person-member-of branch) (book-home branch) (book-status shelf-state) …)
```

## Constraint: this cannot be fixed in the library

§11.1 restricts a form's template to kernel words and earlier-declared forms.
Every instance clause is headed by a **user-defined** name, so no form can emit
one. Verified:

```
pol: template of `shelved` mentions `status`, a form not yet declared
pol: template of `opening-day` mentions `book`, a form not yet declared
```

Even a form wrapping an entire instance fails. The instance layer is closed to
the extension mechanism, so any change here is a grammar change.

## Design

One production replaces two:

```
instance-d ::= (instance NAME (of SCHEMA) clause…)
clause     ::= (TYPE ENTITY… slot…)
slot       ::= (ARROW value)
value      ::= VALUE | ENTITY | vacant
```

### Rules

1. The clause head is **always** a declared open type. A clause headed by an
   arrow is no longer legal.
2. Entities are atoms; slots are lists; **atoms must precede slots**. This is
   what keeps the production unambiguous.
3. Slots are permitted only when the clause names **exactly one** entity. Two
   or more entities plus a slot is an error — never a silent broadcast.
4. `ARROW` must be owned by `TYPE`, whether declared in the type body or at
   schema top with `(of TYPE)`.
5. One answer per cell, unchanged (§8.3), with the existing error text.
6. A type may head several clauses. An entity appears in exactly one, because
   entity names are fresh (§7) — so all of an entity's slots live together.
7. A clause with slots but no entity — `(book (status available))` — is an
   error: a slot needs something to belong to.
8. `(of SCHEMA)` is not a clause and is matched before clause dispatch, as the
   current parser already does. `of` is a kernel word, so it can never collide
   with a type name.

Only open types can head a clause, and this is total rather than a
restriction: enumerated types take their members from the schema, so they have
no roster, and they cannot own arrows — `(type NAME (VALUE…))` and
`(type NAME arrow-d…)` are alternatives in the grammar, verified by
`pol: expected an (arrow …) declaration`. So every arrow's owner is an open
type that always has a clause available to carry its slots.

### Worked example (spec §4)

```lisp
;; before                                ;; after
(instance day-one (of oversight)         (instance day-one (of oversight)
  (bureau watchdog prosecutions)           (bureau watchdog     (independence independent))
  (person alice)                           (bureau prosecutions (independence independent))
  (case docket)                            (person alice        (employer watchdog))
  (employer      (alice watchdog))         (case   docket       (investigator watchdog)
  (investigator  (docket watchdog))                             (prosecutor   prosecutions)
  (prosecutor    (docket prosecutions))                         (stage        open)
  (independence  (watchdog independent)                         (judge        vacant)))
                 (prosecutions independent))
  (stage         (docket open))
  (judge         (docket vacant)))
```

Nine clauses to four. Zero-slot rosters such as `(person ana ben)` are
unchanged — they are the same production with no slots.

## What does not change

- **`Instance.t` keeps `rosters` and `valuation`.** The internal representation
  is untouched, so the state builder, the interrogator, `compare`, `derive` and
  every downstream consumer are unaffected. This is a parser-local change.
- **The 27 words.** No keyword is added or removed; the grammar loses a
  production.
- `vacant`, the unset-slot defaults, and "every `fixed` slot is set" carry over
  verbatim from §9.3.
- Chains, guards, transitions, equations, claims files: untouched.

## Spec changes

- Merge the clause syntax of §9.2 (rosters) and §9.3 (valuations) into a single
  §9.2 *Clauses*, and **keep §9.3 as the home of `vacant`**. Renumbering would
  break live cross-references: §9.3 is cited for `vacatable` at §8.3 and in
  Appendix B's keyword index, and §9.2 is cited at §8.2 for "the schema does not
  know who exists". Both stay valid under this split.
- Appendix A: one production replaces two.
- Rewrite every instance in the document: §4 running example, Appendix C
  (river), Appendix D (island), and inline examples in §8, §9, §12, §16, §17.
- §17: update the `pol schema` / `pol control` sample output.
- `docs/tour.md` — **done ahead of implementation** (2026-08-09), so the tour
  can be read in the new syntax while the parser is still on the old one. It
  carries a status banner saying the listings will not parse yet. Its console
  blocks were left unchanged and re-verified: translating its assembled model
  back to arrow-major and running it reproduces the claimed output
  byte-for-byte. Two new cheat-sheet entries cover "slots need exactly one
  entity" and "all of an entity's slots go in one clause". **Remove the banner
  when the parser lands**, and re-run the extraction check in the acceptance
  test.

## Code changes

| File | Change |
| --- | --- |
| `core/syntax/decl.ml` | `decode_instance`: head is always a type; parse trailing slots per entity; two new errors (slots with multiple entities; arrow not owned by this type) |
| `runtime/schema_data.ml` | emit one `(hom NAME (dom D) (cod C))` clause per arrow instead of parallel `dom`/`cod` lists |
| `runtime/control.ml` | same shape change for `(edge NAME (src S) (tgt T))` |
| `tooling/lsp/lib/feature/completion.ml` | clause-position completion follows the new shape |

Emitter output after the change:

```lisp
(instance t10-schema (of olog)
  (ob shelf-state branch person book)
  (eqn borrow-local)
  (hom person-member-of (dom person) (cod branch))
  (hom book-home        (dom book)   (cod branch))
  (hom book-status      (dom book)   (cod shelf-state))
  (hom book-holder      (dom book)   (cod person)))
```

## Migration and acceptance test

25 instances across 36 `.pol` files: 15 in `pol` — 14 of them in
`tests/unit/fixtures/`, 1 in `tests/models/` — plus 9 in `pol-problems` and 1
in `pol-arch`. The bulk is parser fixtures, which is the cheapest possible
place for a syntax migration to land.

**Acceptance test — the migration must be meaning-preserving, and this is
checkable exactly.** Because `Instance.t` is unchanged, every model's behaviour
must be identical:

1. Before any change, capture a baseline: `pol check` output (plus `--claims`
   where a claims file exists) for every `.pol` model in all three repos.
2. After parser change and migration, re-run and diff. **Byte-identical output
   is required.** Any difference is a migration bug, not an improvement.
3. `pol-problems/run-tests.sh` (98 checks) stays green.
4. `pol schema` / `pol control` output changes by design, so those two are
   compared by re-parsing rather than by diff: the emitted text must still build
   as an instance.

## Accepted costs

- An arrow set uniformly across many entities repeats its name once per entity
  (`independence` twice in the example above).
- An entity's slots cannot be split across clauses. This follows from entity
  names being fresh; it is a constraint, and arguably a feature.
- `pol schema` / `pol control` output is a documented interface (§17). It must
  change — emitting the old shape would emit syntax the new parser rejects.

## Out of scope

This spec covers instance clauses only. The user expects further simplification
candidates to surface while working through `docs/tour.md`; each gets its own
spec rather than being folded in here.
