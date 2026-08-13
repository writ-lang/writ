# Changelog

Versions are the one in `dune-project`: what opam publishes, what `writ
--version` prints, and what `make release` names the tarball with.

## 0.1.0 — unreleased

The first packaged version. What exists:

**The language.** Twenty-seven kernel words: `schema` / `type` / `arrow` with
the arrow qualifiers, `instance`, `initial`, `use`, `transition` with `when` /
`do`, `equation`, `gap`, `form`, `load`. Forms are hygienic one-shot macros —
no recursion — which is what keeps expansion terminating and errors pointing at
real source positions.

It was twenty-eight. A law now holds a **guard** rather than a pair of chains
(§8.6), which made `=` expressible as an ordinary standard-library form —
Kleene equality spelled out of strict primitives, so nothing it used to mean
was lost. `differ` joined it there.

Both sides of a comparison and both sides of an assignment may now be
**chains**: `(is a.x b.y)` (§10.2) and `(set a.x b.y)` (§10.3). The second
carries two decisions worth knowing. Every effect reads the situation the move
STARTED from, so a `do` block is a simultaneous assignment and the order of
effects is unobservable — `(do (set a.x b.y) (set b.y a.x))` is a swap. And a
chain with no answer makes the move **absent**, not a no-op: a no-op would
still be an edge, a self-loop, and a stuck situation would quietly stop
reporting as a dead end.

**The interrogator.** Enumerates the finite reachable state space and answers
`.claims` questions by exhaustion: `never`, `possible` and `live`, each with a
shortest witness route, including the solution path under a holding `possible`.
Reports gaps (where the rules are declared silent), dead ends (no move enabled),
and per-equation observation — which move can break a law, where it is violated,
and whether an acknowledgment is unadmitted or stale. Named queries print their
satisfying bindings.

**The tools.** `writ check`, `writ query`, `writ compare` (including `--git`
between two revisions of one model), `writ control` (a model's dynamics emitted
as data, an instance of the standard library's `quiver` schema), `writ derive`,
`writ --help` and `writ --version`. Exit status is the interface: 0 clean, 1 a
finding, 2 unreadable input.

**The relational extension** (`docs/interrogator.md`). A third file type, the
`.rules` file: relation declarations and stratified rules over the model's
already-enumerated universe, including the derived state category itself
(`situation`, `init`, `edge`, `holds`, `gap-edge`). `writ derive MODEL.writ
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
file re-asking its `.claims` properties as derivations, and writ-problems'
runner cross-checks the two implementations against each other: all sixteen
properties get the same verdict from `writ derive` as from `writ check`.

**A SQL bridge.** `writ sql` reads a relational schema as an olog and writes one
back — one verb, one mapping, the direction taken from the extension. Tables
become types, foreign keys arrows, `NULL` `vacatable`, enums and `CHECK … IN`
enumerated types keeping their members, single-row `CHECK`s laws; a primary key
emits nothing, an entity being its identity. Columns writ cannot look inside
cross as arrows into a ONE-member domain, so a `NOT NULL` scalar costs the
state product nothing and a nullable one costs the factor of two that IS the
distinction writ can decide about a `varchar`. The SQL vocabulary arrives as
forms over the 26 words, generated for the database at hand rather than
shipped — the stdlib stays the only `.writ` the tool ships — and a domain type
shares its column form's name, which is legal because a slotted form only
expands in list-head position and is what makes a column two tokens.

The point is what a database cannot do: a `CHECK` becomes an `equation`, so
`writ check` reports not merely that a constraint is violated but WHICH move can
break it. Everything the DDL says and an olog cannot hold is reported by line
and reason, aggregated, never dropped in silence; `--strict` makes that a
finding. `UNIQUE` is declined as unsayable rather than unimplemented — a law
ranges over one entity of its subject type and a bare `some` binder is not
comparable — as is arithmetic in a `CHECK`, for the reason the language has no
numbers at all. pg_dump is the input that matters, so casts, `= ANY (ARRAY[…])`,
`ALTER TABLE … ADD CONSTRAINT` and dollar-quoted function bodies are all read
correctly. Round-tripping is defined on the model rather than the text, and the
two facts SQL cannot state — whether a key is ever `UPDATE`d, whether a plain
column is wiring — travel as `-- writ:` pragmas the import reads back. The
library, `writ_sql`, depends on `writ_data` alone and lives in `tooling/`
beside the other bridges to foreign notations — it is not part of the
language, and the engine cannot tell it exists. The emitted model is
kernel-only: no `(load …)`, no prelude, nothing from the standard library.

**Editor support.** A language server, `writ-lsp` — diagnostics from the real
engine, completion, hover and an outline, over `.writ`, `.claims` and `.rules`.
The VS Code client is its own repository,
[writ-vscode](https://github.com/writ-lang/writ-vscode); it finds `writ-lsp` on
`PATH`, so it needs no checkout of this one.

**An MCP server.** `writ-mcp` exposes `writ_check`, `writ_query` and `writ_derive`
over the same engine, so an assistant can model a problem and get an answer
with a witness route rather than a plausible guess. A tool that fails answers
with the engine's own `file:line:col` message rather than dying, which is
usually enough for the caller to fix the file and retry. A Claude skill that
knows when Writ is the right tool ships in `.claude/skills/writ/`.

**Packaging.** An opam package installing `writ`, `writ-lsp`, `writ-mcp` and the
`.writ` standard library; a portable release tarball with a statically linked
binary, verified on glibc (Debian 12) and musl (Alpine); and `make install-writ`
for a plain copy into `~/.local`. The Docker image carries the CLI and the
standard library.

**Three repositories.** This one is the language, the engine, the CLI and the
servers. The worked scenarios moved to
[writ-problems](https://github.com/writ-lang/writ-problems) and the editor client
to [writ-vscode](https://github.com/writ-lang/writ-vscode); both need an installed
`writ` rather than a checkout, which is what `make install-writ` and
`opam install .` provide.

The standard library is one file, `stdlib.writ`, and it is the only `.writ` the
tool ships. A **domain** library — a vocabulary for one subject — is ordinary
user code: `politics.lib.writ` lives beside the models that load it in
`tests/models/`, and writ-problems keeps its own in `libraries/`, leaving
`core/stdlib/` the standard library alone.

**One rename.** The standard library's many-to-many form is `span`, not
`relation`. `relation` is how a `.rules` file declares a relation, and forms
expand in every file type, so the form was quietly rewriting those declarations
into junction types. A model of your own that calls `(relation R A B)` must
call `(span R A B)` instead; nothing else about it changed.

Not built yet: the §16.4 schema dictionaries (`functor`, `check … via`) and §17
fiber reporting.
