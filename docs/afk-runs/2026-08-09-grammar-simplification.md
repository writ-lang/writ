# AFK run — grammar simplification

*2026-08-09 · branch `afk/grammar-simplification` in all three repos · **complete**.*

Implements two designs agreed beforehand: entity-major instance clauses, and
the removal of `of`, `=>` and the unused schema-top arrow form.

## Result

**27 words → 26. Infix tokens 1 → 0.**

`of` has no remaining home: the instance header is positional and the
schema-top arrow form is deleted. `=>` is gone from both of its homes, `form`
and `map`, so §2.5's "every datum is a parenthesised list headed by a word" is
now true without exception — the clause qualifying it is deleted rather than
reworded.

```lisp
(instance shelf library                    ; was (instance shelf (of library)
  (book   hamlet (status available)        ;       (book hamlet)
                 (holder vacant))          ;       (status (hamlet available))
  (person ana ben))                        ;       (holder (hamlet vacant))

(form (lend-to NAME WHO)                   ; was (form (lend-to NAME WHO) =>
  (transition NAME …))
```

Two clause shapes became one; the "which is this?" question a reader had to ask
of every instance clause no longer exists.

## Gates

Re-run after every task; final state:

```
make build   PASS
make test    PASS
make lint    PASS
pol-problems/run-tests.sh   98 checks passed, 0 failed
```

`run-tests.sh` was run against the freshly built binary with the migrated
corpus — the only configuration in which it proves anything here.

## Acceptance

`pol check` compared byte-for-byte against a baseline captured **before any
edit** (36 source models across three repos; `_build` copies excluded).

**33 of 36 byte-identical. All 3 deviations are position-only:**

| Model | Baseline | Now | Cause |
| --- | --- | --- | --- |
| `no_prelude.pol` | `17:1` | `16:1` | a clause folded away; file one line shorter |
| `politics.lib.pol` | `74:22` | `74:19` | `=> ` removed — exactly 3 columns |
| `recurse.pol` | `6:20` | `6:17` | `=> ` removed — exactly 3 columns |

Same error text, same meaning. No semantic difference in any model.

## What the gates caught that review would not have

1. **A silent correctness regression in the parser change.** `names.ml`'s
   `roster_entities` required *every* clause argument to be an atom, so an
   entity-major clause carrying a slot was skipped entirely and its entities
   went unregistered — letting a `some` binder shadow an entity undetected. The
   binder test caught it. Fixed to take the leading run of atoms, the same rule
   the parser applies.
2. **The migrator commented out a closing paren.** Deleting a valuation clause
   could leave a trailing `; …` comment as a list's last child, so `)` landed on
   the comment's line and was swallowed. Fixed by never closing a list on a line
   with an open comment.
3. **The migrator rewrote a deliberately malformed fixture.** `garbage.pol`
   exists to produce one specific parse error. A round-trip guard now makes the
   migrator refuse any file it cannot reproduce byte-for-byte; 35 of 36 models
   round-trip and `garbage.pol` is the only refusal, by design.
4. **Escaped quotes broke the OCaml-literal migrator**, which emitted
   `)))))))`. `\"` is a string delimiter to Pol but a backslash-atom to a naive
   lexer, so the paren count came out wrong.

## Found by reading, not by any gate

- **Both emitters produced the old spelling.** `pol schema` and `pol control`
  still wrote `(of SCHEMA)` headers; they parsed only because the old spelling
  was still accepted, and would have broken the moment it was removed. `pol
  schema` also wrote `dom` and `cod` as two parallel lists the reader had to
  join by name — the very defect entity-major clauses exist to remove. Now:
  `(hom book-status (dom book) (cod shelf-state))`.
- **LSP hover advertised the dead syntax** — `(instance NAME (of SCHEMA) …)`,
  `(form PATTERN => TEMPLATE…)`, `(map ARROW => ARROW)` — and completion still
  offered `of`. All user-facing; no test covers hover text.
- **Un-migrated input would have been misread rather than refused.** With `=>`
  no longer a token, `(form q => …)` parses as a nullary form whose first
  template is `=>` — a *different* form, accepted in silence. An explicit check
  now names it.
- **A latent bug in `run-tests.sh`**: `has`/`near`/`lacks` passed their needle
  to `grep -F` without `--`, so any needle starting with `-` was read as an
  option. Surfaced when an assertion became `-control quiver`.

## Decisions taken during the run

- **Transitional, then collapsed** — not atomic as the designs specified.
  Changing `decode_instance` breaks 84 sites at once, leaving `make test` red
  for an unbounded stretch, which the per-task gate cannot accept. Both parsers
  read old and new until the corpus had moved; the old spellings were then
  deleted in the same run, so no deprecation debt is left behind.
- **`landing: local`** — pushed, but no PRs opened. Three repos must merge
  together; a PR on `pol` alone would advertise a change that breaks the others.
- **Design stage skipped** — two approved designs already existed.

## Corrections to the designs

Their migration estimates were undercounts, because they counted `.pol` files
only:

| Surface | Design said | Actual |
| --- | --- | --- |
| instance sites | 25 | **84** (25 `.pol` + 59 in OCaml test strings) |
| form sites | 59 | **76** (59 `.pol` + 17 in tests) |

And the schema-top arrow form was **not** free to delete: it had 2 uses in
`tests/unit/test_names.ml`, both covering error paths that cease to exist. Both
were deleted; in-body arrow freshness remains pinned by its own case.

One test changed *meaning* rather than position: "a cell may not be given two
values, across clauses" cannot arise now that all of an entity's slots live in
one clause. It is replaced by the rule that actually catches that shape — the
same entity may not head two clauses.

## Not verified by the offline gate

- **`make install-pol` was not run.** The binary at `~/.local` is still the
  pre-change one; everything here used `_build/default/tooling/cli/pol.exe` with
  `POL_LIB` pointed at the source stdlib. Install before using `pol` on a model.
- **No editor was opened.** `pol-vscode` was not exercised; the LSP changes are
  verified by build and unit tests only, not by hover in a real client.
- **`pol-arch` has no git remote**, so its branch exists locally only.

## Still open, from the same review

Neither is a defect, and neither is in scope here — recorded so the reasoning
is not lost with the working notes.

- **`to` could go too**, taking 26 → 25. Now that every arrow is declared in
  its owner's type body, the source is implied by nesting and
  `(arrow status shelf-state)` is unambiguous. Held because it cuts against
  the rule this change establishes — atoms are entities, lists are slots — and
  because it removes a word rather than an ambiguity. 58 sites.
- **Transitions name entities, not types.** A `some`-bound variable is legal in
  a guard but rejected in an effect, so "any book" is inexpressible and every
  non-trivial model generates its moves with forms. Deliberate: one datum stays
  one rule for edges, and the edge set stays readable from the text. Changing it
  would be an *addition* that grows the language to shrink models.

Closed with reasons during the same review: `do` (the form layer needs an
effect group to be one datum), `when` (dropping it makes a transition name
ambiguous with a nullary guard), `vacate` (`vacant` is not a member of the
target type), `vacatable` (default-vacatable is the sentinel move it replaced,
and inflates the river 54 → 81), and unifying `is`/`set` (that is TLA+, and it
costs determinism and the implicit frame).

## Merge order

`pol` first — the other two need its parser.

```
pol            cae7ffd docs: language-design section, tour, two approved designs
               963b3af parser: accept entity-major clauses and positional header
               61a45f5 migrate pol's models to entity-major instance clauses
               2672c3b expander: accept `form` without `=>`, migrate the corpus
               ecdd391 afk run report (checkpoint)
               6de20d2 migrate inline model text in the OCaml test suite
               9cf34d8 emitters: pol schema and pol control emit entity-major
               bacdf36 remove `of`, `=>`, and the schema-top arrow form
               3277d33 docs and LSP: the language is twenty-six words
pol-problems   8b954d6 migrate models to entity-major instance clauses
               7cd3bb8 migrate forms to the =>-free spelling
               6c6afa1 run-tests: positional quiver header, and fix grep
pol-arch       f8ac0a2 migrate models to entity-major instance clauses
               f28404a migrate forms to the =>-free spelling
```
