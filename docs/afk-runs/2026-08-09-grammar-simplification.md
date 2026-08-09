# AFK run — grammar simplification

*2026-08-09 · branch `afk/grammar-simplification` in all three repos ·
**checkpoint, run incomplete**.*

Implements
[entity-major instance clauses](../superpowers/specs/2026-08-09-entity-major-instances-design.md)
and [grammar removals](../superpowers/specs/2026-08-09-grammar-removals-design.md).

## Status

**The language change is done and verified. The documentation is not.**
Both new spellings are accepted, the whole corpus is migrated, every gate is
green — but the old spellings are still accepted too, so nothing has actually
been *removed* yet. That last step is blocked on the OCaml test suite, which
embeds model text inline.

| Task | State |
| --- | --- |
| T1 parser: entity-major clauses + positional header | **done** |
| T2 migrate pol's 17 models | **done** |
| T3 expander: `form` without `=>` | **done** |
| T4 migrate all `.pol` forms, 3 repos | **done** |
| T5 migrate pol-problems (9) + pol-arch (1) | **done** |
| T2b migrate 59 inline instance + 17 form strings in OCaml tests | **not started** |
| T6 delete old spellings; drop top-level arrow alternative | blocked on T2b |
| T7 emitters (`schema_data`, `control`) + LSP completion | not started |
| T8 rewrite kernel-spec (App. A/B, §2.5, §8.3, §9.1, §11.1, §16.4, §17, §4, C, D) | not started |
| T9 README + tour: 27 → 26 words, remove the status banner | not started |

Until T6 lands, **the 27 words are still 27** — `of` is accepted, not removed.

## Gates

Re-run after every task. Final state:

```
make build   PASS
make test    PASS
make lint    PASS
pol-problems/run-tests.sh   98 checks passed, 0 failed
```

`run-tests.sh` was run against the freshly built binary with the migrated
corpus, which is the only way it proves anything here.

## Acceptance

`pol check` output compared byte-for-byte against a baseline captured **before
any edit** (36 source models, all three repos; `_build` copies excluded).

**33 of 36 byte-identical. All 3 deviations are position-only and explained:**

| Model | Baseline | Now | Cause |
| --- | --- | --- | --- |
| `no_prelude.pol` | `17:1` | `16:1` | migration folded a clause away, file one line shorter |
| `politics.lib.pol` | `74:22` | `74:19` | `=> ` removed — exactly 3 columns |
| `recurse.pol` | `6:20` | `6:17` | `=> ` removed — exactly 3 columns |

Same error text, same meaning, in every case. No semantic difference was found
in any model.

## Two bugs the acceptance test caught

Both would have shipped silently without it.

1. **The migrator commented out a closing paren.** Deleting a valuation clause
   could leave a trailing `; …` comment as a list's last child; the `)` was then
   emitted on the comment's line and swallowed, so `rules_base.pol` became
   `unbalanced parenthesis: list never closed`. Fixed by never closing a list on
   a line with an open comment.
2. **The migrator rewrote a deliberately malformed fixture.** `garbage.pol`
   exists to produce a specific parse error; rewriting it changed which error it
   tested. Fixed with a round-trip guard — the migrator now refuses any file it
   cannot reproduce byte-for-byte. 35 of 36 models round-trip; `garbage.pol` is
   the only refusal, by design.

## Decisions taken during the run

- **Transitional, not atomic.** The designs said delete-and-migrate in one step.
  That was wrong at this scale: changing `decode_instance` breaks 84 sites at
  once, leaving `make test` red for an unbounded stretch, which the per-task gate
  cannot accept. Both parsers now read old and new; the old goes in T6, within
  the same run, so no deprecation debt is left behind.
- **`landing: local`.** Nothing pushed, no PR opened. Three repos must merge
  together — a PR on `pol` alone would advertise a change that breaks the other
  two.
- **Design stage skipped.** Two approved designs already existed.

## Corrections to the design docs

The designs' migration estimates were **wrong, and undercounted** — they counted
`.pol` files only:

| Surface | Design said | Actual |
| --- | --- | --- |
| instance sites | 25 | **84** (25 `.pol` + 59 in OCaml test strings) |
| form sites | 59 | **76** (59 `.pol` + 17 in tests) |

Also: the top-level arrow alternative is **not** zero-cost to delete. It has 2
uses in `tests/unit/test_names.ml`, both testing error paths that cease to exist
once it is gone — they must be deleted, and in-body arrow freshness needs
confirming as still covered.

## Not verified by the offline gate

- **The LSP and both emitters are untouched.** `pol schema` and `pol control`
  still emit `(of SCHEMA)` headers and arrow-major `dom`/`cod` lists. Their
  output currently parses only because the old spelling is still accepted; it
  will break at T6. No test covers this — it was found by reading, not by a
  failing gate.
- **No editor was opened.** `pol-vscode` was not exercised.
- **`make install-pol` was not run**, so the installed binary at `~/.local` is
  still the pre-change one. Everything above used
  `_build/default/tooling/cli/pol.exe` with `POL_LIB` pointed at the source
  stdlib.
- **The docs now disagree with the code.** `kernel-spec.md` documents the old
  syntax throughout; `docs/tour.md` documents the new. The tour's banner saying
  its listings "will not parse" is now false — they do.

## Commits

```
pol            cae7ffd docs: language-design section, tour, two approved designs
               963b3af parser: accept entity-major clauses and positional header
               61a45f5 migrate pol's models to entity-major instance clauses
               2672c3b expander: accept `form` without `=>`, migrate the corpus
pol-problems   8b954d6 migrate models to entity-major instance clauses
               7cd3bb8 migrate forms to the =>-free spelling
pol-arch       f8ac0a2 migrate models to entity-major instance clauses
               f28404a migrate forms to the =>-free spelling
```

Merge order matters: `pol` first, then the other two.
