# Changelog

Versions are the one in `dune-project`: what opam publishes, what `pol
--version` prints, and what `make release` names the tarball with.

## 0.1.0 — unreleased

The first packaged version. What exists:

**The language.** All twenty-eight kernel words: `schema` / `type` / `arrow`
with the arrow qualifiers, `instance`, `initial`, `use`, `transition` with
`when` / `do`, `equation`, `accept`, `gap`, `form`, `load`. Forms are hygienic
one-shot macros — no recursion — which is what keeps expansion terminating and
errors pointing at real source positions.

**The interrogator.** Enumerates the finite reachable state space and answers
`.claims` questions by exhaustion: `never`, `possible` and `live`, each with a
shortest witness route, including the solution path under a holding `possible`.
Reports gaps (where the rules are declared silent), dead ends (no move enabled),
and per-equation observation — which move can break a law, where it is violated,
and whether an acknowledgment is unadmitted or stale. Named queries print their
satisfying bindings.

**The tools.** `pol check`, `pol query`, `pol compare` (including `--git`
between two revisions of one model), `pol control` (a model's dynamics emitted
as data, an instance of the standard library's `quiver` schema), `pol derive`,
`pol --help` and `pol --version`. Exit status is the interface: 0 clean, 1 a
finding, 2 unreadable input.

**The relational extension** (`docs/interrogator.md`). A third file type, the
`.rules` file: relation declarations and stratified rules over the model's
already-enumerated universe, including the derived state category itself
(`situation`, `init`, `edge`, `holds`, `gap-edge`). `pol derive MODEL.pol
RULES.rules RELATION` prints the rows; `"(RELATION ARG…)"` binds any position,
so the dynamics run backward as readily as forward; `--why` prints a fact's
derivation tree. A situation is written as its state index, in and out. Every
well-formed question exits 0 — an empty relation is an answer — and an
unreadable rules file or an undeclared relation exits 2. A relation is
declared `(relation NAME ARITY)`, or `(relation NAME (T1 … Tn))` to give a sort
per column — `Situation`, `Edge`, or a schema type — which is what makes rules
writable over a model where two types share an arrow name and the root of a
path therefore cannot be typed from the arrow. Sort inference,
stratification, range restriction and path checking are all read-time
rejections that blame a `line:col`. Every worked example carries a `.rules`
file re-asking its `.claims` properties as derivations, and `make examples`
cross-checks the two implementations against each other: all eleven properties
across the five scenarios get the same verdict from `pol derive` as from
`pol check`.

**Editor support.** A language server and a VS Code client — diagnostics from
the real engine, completion, hover and an outline.

**Packaging.** An opam package installing `pol`, `pol-lsp` and the `.pol`
standard library; a portable release tarball with a statically linked binary,
verified on glibc (Debian 12) and musl (Alpine); and `make install-pol` for a
plain copy into `~/.local`.

The standard library is one file, `stdlib.pol`, and it is the only `.pol` the
tool ships. A **domain** library — a vocabulary for one subject — is ordinary
user code: `politics.lib.pol` now lives beside the models that load it, in
`tests/models/`, leaving `core/stdlib/` the standard library alone.

**One rename.** The standard library's many-to-many form is `span`, not
`relation`. `relation` is how a `.rules` file declares a relation, and forms
expand in every file type, so the form was quietly rewriting those declarations
into junction types. A model of your own that calls `(relation R A B)` must
call `(span R A B)` instead; nothing else about it changed.

Not built yet: the §16.4 schema dictionaries (`functor`, `check … via`) and §17
fiber reporting.
