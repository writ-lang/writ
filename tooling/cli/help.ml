(* The `pol --help` text, as a plain string constant printed by the CLI.

   It is a sibling module of [Pol] in tooling/cli/: the executable is named
   [pol], and because the engine now lives in the separate libraries pol_data /
   pol_syntax / pol_runtime (not a library named [pol]), the exe may carry more
   than one module without [Pol] shadowing a library. This is IO-free data (no
   print here; pol.ml prints it), so it crosses no layer or io-only gate. Keep it
   in sync with the command dispatch in pol.ml. *)

let text =
  {help|pol — Partial Olog: an abstract language for modelling real-world domains.

A Pol model is a state machine written down: a SCHEMA (the kinds of things that
exist and the typed arrows between them, plus the laws certain arrow-chains must
obey), an INSTANCE (one starting configuration), and TRANSITIONS (guarded moves).
`pol` enumerates every reachable situation — a finite space — and answers
questions about it by exhaustion, with a concrete route as evidence.

USAGE
  pol check    MODEL.pol [--claims FILE.claims]
  pol query    MODEL.pol NAME [--at STATE]
  pol compare  OLD.pol NEW.pol [--map MAP.pol]
  pol compare  --git REV1 REV2 MODEL.pol [--map MAP.pol]
  pol control  MODEL.pol
  pol schema   MODEL.pol
  pol derive   MODEL.pol RULES.rules RELATION | "(RELATION ARG…)"
  pol derive   MODEL.pol RULES.rules --why "(RELATION ARG…)"
  pol --help | -h
  pol --version | -V

COMMANDS
  check    Build the model and print the report — the reachable state count and
           edges; the gaps (points where the rules are declared silent); the
           dead ends (situations with no move enabled); and, per equation,
           whether a move can break the law and where it is violated. With
           --claims it also checks each property and prints:
             holds NAME   — the property is true (a holding `possible` prints its
                            shortest satisfying route: the solution/example)
             fails NAME   — with `stuck at:` and a numbered witness route
             n/a   NAME   — the property names structure the schema lacks
           plus query answers and law acknowledgments (unadmitted / stale).

  query    Run one named query from the model's sibling .claims file and print
           the satisfying variable bindings. --at STATE addresses a situation by
           its state index (default: the initial situation, index 0).

  compare  Build two models and report each equation and property as
           `preserved`, `LOST`, or `gained` across the pair (properties come
           from OLD's sibling .claims). --map carries `(map X => Y)` renames when
           the two schemas differ. The --git form compares two revisions of one
           file (`git show REV:MODEL`).

  control  Emit the model's move list as an instance of the standard library's
           `quiver` schema — the dynamics as re-usable, checkable data.

  schema   Emit the model's SCHEMA as an instance of the standard library's
           `olog` schema — the map as data, the sibling of `control` one level
           up. Types become `ob`, arrows `hom` with `dom`/`cod`, laws `eqn`
           entities by name; a law's body is not encoded (kernel §17).

  derive   Answer a .rules file's relations over the model's enumerated
           universe (the relational extension, docs/interrogator.md). A bare
           RELATION prints every row; a "(RELATION ARG…)" datum keeps only the
           rows matching the arguments given, ALL-CAPS being a free variable.
           Any position may be bound, so the dynamics run backward — "(reach X
           2)" asks which situations reach state 2 — as readily as forward. A
           situation is written as its state index, in and out; an entity by
           name; an edge by its transition name. --why prints the derivation
           tree of one fact whose arguments are all given, two spaces per
           level, down to the extensional facts, ground guard checks and
           completed-stratum negations it rests on. Every well-formed question
           exits 0, an empty answer set included — an empty relation is an
           answer — and an unreadable rules file or an undeclared relation
           exits 2. This verb never exits 1. A relation is declared
           `(relation NAME ARITY)`, or `(relation NAME (T1 … Tn))` to give a
           sort per column (Situation, Edge, or a schema type) — needed when a
           column's sort cannot be inferred, as it cannot for a variable
           rooted in an arrow name that two types share.

OPTIONS
  --claims FILE    the questions to ask (properties, queries, accepts)
  --at STATE       address a situation by its state index (query only)
  --why "(R A…)"   print one fact's derivation tree instead of rows (derive)
  --map MAP.pol    `(map X => Y)` renames for comparing differing schemas
  --git R1 R2 M    compare git revisions R1 and R2 of model M

EXIT STATUS  (the interface — scriptable)
  0   clean — the model built and nothing failed
  1   a finding — a failed property; a violated, unadmitted, or stale law; or a
      guarantee lost in a comparison
  2   unreadable input — a missing file, a parse error, or a bad command line

FILES
  A .pol file is a MODEL (exactly one `use` and one `initial`, plus transitions)
  or a LIBRARY (declarations only). `(load "FILE")` pulls a library in; there is
  no implicit prelude. A model's questions live beside it in MODEL.claims. A
  .rules file is the third file type: relation declarations and rules, read by
  the same reader and form expander, named on the `derive` command line.

  `(load "FILE")` resolves in order: the including file's directory; $POL_LIB;
  the stdlib bundled beside the binary (../share/pol/lib); then ./core/stdlib. So
  the shipped `stdlib.pol` resolves from any directory. A DOMAIN library — a
  vocabulary for one subject — is not standard and is not shipped: keep it beside
  the models that load it, where the first rule of the search order finds it.

  That first rule cuts both ways: a `stdlib.pol` lying beside a model REPLACES
  the installed one, silently and by design. Set POL_TRACE_LOADS=1 to print
  which file each load resolved to, and which candidates were skipped — the
  question to ask whenever an edit to a library appears to have no effect.

INSTALLING  (all three land bin/pol + share/pol/lib, which is what the resolver
             above expects — see the README)
  make install-pol    from a checkout, into ~/.local — plain cp, no opam
  opam install .      the opam package: pol + pol-lsp + the stdlib into a switch
  make release        a tarball with a static binary + stdlib + install.sh, for
                      a machine with no OCaml, no opam and no network

EXAMPLES
  pol check   tests/models/any_model.pol --claims tests/models/any_model.claims
  pol query   tests/models/any_model.pol captured --at 7
  pol compare old.pol new.pol
  pol compare --git HEAD~1 HEAD model.pol
  pol control model.pol
  pol schema  model.pol
  pol derive  model.pol org.rules subordinate
  pol derive  model.pol org.rules "(subordinate nabu X)"
  pol derive  model.pol org.rules --why "(subordinate nabu cabinet)"

The language is specified in docs/kernel-spec.md. Worked examples that solve real
problems (the river crossing, knights & knaves, institutional scenarios) are
in github.com/sajonaro/pol-problems — clone it and run ./run-tests.sh.

Copyright (C) 2026 Alex Kunich.  License AGPL-3.0-or-later: GNU Affero GPL
version 3 or later <https://gnu.org/licenses/agpl.html>.  This is free software:
you are free to change and redistribute it, and a version you offer to users over
a network must offer them its source.  There is NO WARRANTY, to the extent
permitted by law.  The full text ships with the program, at
<prefix>/doc/pol/LICENSE.
|help}
