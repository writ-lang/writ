# Grammar removals: `of`, `=>`, and the top-level arrow

*2026-08-09 — design, approved. Status: not yet implemented.*

**Ships together with
[entity-major instance clauses](2026-08-09-entity-major-instances-design.md).**
Both rewrite the same 25 instances; done separately they would migrate the same
files twice and require two byte-identical acceptance runs. Treat the two docs
as one change.

## Net effect

| | Before | After |
| --- | --- | --- |
| kernel words | 27 | **26** (`of` leaves) |
| infix tokens | 1 (`=>`, in two homes) | **0** |
| Appendix A | — | one alternative and two `=>` gone |

§2.5's claim — "everything in Pol is a parenthesised list whose head is a word"
— becomes true without qualification, and the exception clause added to it on
2026-08-09 is deleted rather than reworded.

## A. Delete the top-level arrow alternative

```
arrow-d ::= (arrow NAME (to TYPE) flag…)                 ; in a type body — KEPT
          | (arrow NAME (of TYPE) (to TYPE) flag…)       ; at schema top — DELETED
```

**Zero uses** across `pol`, `pol-problems` and `pol-arch`; all 58 arrows are
declared in a type body. It is a pure layout alternative with no extra power —
verified that it cannot attach an arrow to a type from another loaded schema:

```
pol: arrow `status` names an undeclared type `book` as its domain
```

**Not zero-cost, though.** It has **2 uses in `tests/unit/test_names.ml`**, and
both test error paths that stop existing once the alternative is gone:

| Test | Fate |
| --- | --- |
| "an explicit `(of TYPE)` domain must be a declared type too" | delete — the construct it rejects is no longer expressible |
| "§8.3 freshness reaches across a top-level arrow and a type body" | delete — no second declaration site remains |

Before deleting the second, confirm that arrow-name freshness *within* a type
body is still covered elsewhere in the suite; if not, add that case. Removing a
grammar alternative removes the error class it created, and the tests that
guarded it — this is the whole cost of A.

## B. Positional instance header

```
instance-d ::= (instance NAME SCHEMA CLAUSE…)        ; was (instance NAME (of SCHEMA) CLAUSE…)
```

25 sites. Unambiguous: the name and the schema are atoms, every clause is a
list — the same atoms-versus-lists rule that carries the entity-major design.
It also matches the positional style of `(use library)` and `(initial shelf)`.

**Rejected variant.** `(instance shelf (library) …)` — `(library)` is
indistinguishable from a zero-entity clause `(TYPE)`.

With A and B done, `of` has no remaining home: all 25 of its occurrences in
`.pol` files are instance headers.

## C. Drop `=>` from `form`

```
form-d ::= (form PATTERN TEMPLATE…)        ; was (form PATTERN => TEMPLATE…)
         | (form NAME DATUM)               ; was (form NAME => DATUM)
```

59 sites. Unambiguous: element 2 is the pattern — a list for a parameterised
form, an atom for a nullary one — and elements 3 onward are templates.

```lisp
(form (toggle P A B)
  (transition (when (is P A)) (do (set P B)))
  (transition (when (is P B)) (do (set P A))))
```

**Accepted cost, stated plainly.** A form's pattern and its templates are *both*
lists, so unlike everywhere else in the language, atoms-versus-lists does not
distinguish them — only position does. `=>` was the marker that made
`(form (a b c) (d e f))` unmistakable. This design accepts a reader having to
know that slot 2 is the pattern, in exchange for the language having no infix
token at all. That trade was the author's call, over a recommendation to hold.

## D. Drop `=>` from `map`

```
(functor NAME (from SCHEMA) (to SCHEMA) [(over TYPE…)] (map X Y)…)
```

`=>` has a **second home** in schema dictionaries (§16.4, and the `--map` file
of §17). Without this, `=>` survives and C does not achieve its purpose.

Zero uses, and §16.4 is deferred (unimplemented), so this is a spec-only edit:
no code, no migration.

## What does not change

- `to` stays. It is a head-position word, consistent with every other datum;
  removing it is a separate question, held as candidate 3.
- `Instance.t` keeps `rosters` and `valuation` — B is a header change only.
- Effects, guards, chains, equations, claims files: untouched.
- `@SLOT` stays; it is a prefix sigil on an atom, not infix.

## Spec changes

- Appendix A: delete the top-level `arrow-d` alternative; rewrite `instance-d`
  and both `form-d` productions.
- Appendix B: remove `of` from the keyword index; restate the count as
  **twenty-six**. Every "twenty-seven words" in the spec, `README.md` and
  `docs/tour.md` becomes twenty-six.
- §2.5: delete the `=>` exception clause added 2026-08-09; the "one shape"
  claim now holds unqualified.
- §8.3: drop the schema-top arrow syntax and its example.
- §9.1: positional header.
- §11.1: `=>` disappears from the syntax and from every example.
- §16.4, §17: `(map X Y)`.
- Rewrite every affected example: §4, Appendices C and D, and the tour.

## Code changes

| File | Change |
| --- | --- |
| `core/syntax/decl.ml` | instance header positional; drop the schema-top arrow branch |
| the expander (`Expander`) | `form` parses pattern-then-templates with no separator |
| `tests/unit/test_names.ml` | delete the 2 top-level-arrow tests; confirm in-body freshness stays covered |
| `runtime/schema_data.ml`, `runtime/control.ml` | emitted instance headers |
| `tooling/lsp/lib/feature/completion.ml` | header and form shapes |

## Migration and acceptance test

25 instance headers, 59 forms, 2 OCaml tests, 0 top-level arrows, 0 `map`
datums.

The acceptance test is the one from the entity-major design, and it covers this
change too: because none of A–D alters `Instance.t` or any runtime structure,
**`pol check` output must be byte-identical for every model in all three repos,
before and after.** Capture the baseline once, before either change. Any
difference is a migration bug. `pol-problems/run-tests.sh` (98 checks) stays
green; `pol schema` / `pol control` are compared by re-parsing, since their
emitted headers change by design.
