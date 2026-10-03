# Changelog

Versions follow `dune-project`: what opam publishes, `writ --version` prints and
`make release` names the tarball with.

## Unreleased

**An assistant can author models through MCP with no documentation pasted
in.** `writ-mcp` now teaches the language and accepts what an assistant
writes:

- every file argument also takes inline text (`model_source`,
  `claims_source`, `rules_source`, `old_model_source`, `new_model_source`), so a
  client that cannot write to the server's disk can author; `model_name` keeps
  revision history per inline model;
- `writ_guide` serves the language by topic (syntax, semantics, idioms, five
  worked examples, every error code), also as `writ://guide/<topic>` resources
  and a `writ_model_system` prompt; the server sets `instructions`, and
  `writ_check`'s description carries a complete example;
- `writ_validate` parses and type-checks without building the space and
  summarises what the sources declare, including the most situations they
  allow;
- every error carries a code (`E_UNKNOWN_ARROW`, `E_STATE_LIMIT`, …), position,
  found and expected names, a hint, and, for a misspelt name, the corrected
  line;
- `max_situations` and `timeout_ms` bound a search, and a cut-off search says
  how far it got and which cells drove the growth, and decides nothing.

**Breaking:** a transition with a clause other than `when` and `do` is now an
error: a bare `(set …)` outside `(do …)` used to be dropped silently, leaving a
move that changed nothing. No model in writ, writ-problems, writ-arch or
writ-scheduling-verification has one.

**A failing `inevitable` says how a run avoids the goal.** Under the witness,
`avoids: the run stops at #N` when no move is left, or `loop:` a shortest cycle
back to the stuck situation; under `(fair …)`, `loops among:` the situations a
fair run circles in. Prose only: `--json` and certificates are unchanged.

**Long dead-end lists are readable.** A route over 24 moves keeps its first and
last ten and counts the rest; past 20 dead ends the report says how many more.

**`certified` no longer reads as if n/a claims were checked.** When every
property is `n/a` and no query was asked, the last line is `certified: the
situation count only — every property is n/a, so no claim was checked`, in
`writ check` and `writ_check` alike. The `certification` JSON field is
unchanged.

## 0.4.0 — 2026-10-03

**Upgrading:** `writ check` now exits 1 when a property is `n/a`. A pipeline
that gated on exit 0 while some property was unanswerable will now fail. That
is the intent, but check your claims files for `n/a` before upgrading.

**An n/a property is a finding.** `writ check` exits 1 when a property is
`n/a`, as it does when one fails. An edit that deletes what a question asks
about no longer passes a gate that reads the exit status; `compare` and the
MCP server already treated it this way.

**`compare` reports a law NEW breaks as LOST.** An equation declared alike in
both models used to read `preserved` even when NEW reached a violation of it.
It is now LOST, with NEW's route to the violation, like a property that stops
holding.

**`writ sql` declines `NOT VALID`.** The constraint is still read, but the
clause is declined, so `--strict` fails on it: the model would otherwise claim
the constraint for rows the database never checked. `VALIDATE CONSTRAINT` is
declined with its own reason.

**`.rules` guards compare two paths.** `(is P Q)` with a path on each side is
the kernel's chain-against-chain test, so forms like `differ` over two cells
work in a `.rules` file as in a claims file.

**Pinned questions work with the Claude plugin.** The plugin started
`writ-mcp` with no arguments, so `--claims-dir` — the guard that keeps an
assistant from editing its own questions — could not be turned on. Set
`WRIT_CLAIMS_DIR` and the launcher passes it, mounting the directory into the
container when it lies outside the project. `docs/mcp.md` is new: what the MCP
server gives you, how to install it in any client, and how to use it.

## 0.3.0 — 2026-10-03

**Certificates, checked by a checker proved sound in Lean.** `writ check`
writes `MODEL.cert.json` beside the model (`--certificate FILE` elsewhere,
`--no-certificate` not at all) — the model, the claims and the `--json` report,
without the state graph, which the checker rebuilds (docs/certificates.md). The
report then ends `certified`, `NOT CERTIFIED` (exit 1), or `not certified` when
no `writ-cert` is installed. The image and release tarball ship a static
`writ-cert`, and MCP's `writ_check` is certified too. Building from source does
not need Lean; `make writ-cert-bin` builds the checker in docker.

**`--json` is as fast as the prose report on large spaces.** Witness replay
re-fires each named move instead of scanning every edge, which took a
118 969-situation check from 5 minutes to 40 s.

**Positioning.** The README opens with what writ is for — finite business and
governance systems, where a negative answer is a census — and pairs Appendix
G's domains with worked scenarios.

**Fiber reporting (§17).** `writ check … --fiber gov.regime` answers every
property once per value of the cell, under the whole-space verdict
(`fiber gov.regime=emergency   FAILS   witness: …`). Repeatable for a product of
cells; a failing fiber is a finding; `--json` carries `fibers`.

**The MCP server as a verifier.** New tools `writ_show` and `writ_compare`,
and `json: true` everywhere. `writ-mcp --claims-dir DIR` pins the claims to
files the human owns, and each `writ_check` ends with a `revision:` block of
guarantees lost since the previous model (`n/a` counts as lost).

**`writ sql` cuts a column by its `CHECK` constants.** `CHECK (qty < 500)`
becomes the enumerated domain `(below-500 exactly-500 above-500)` and the law a
membership test — exact, not conservative (`docs/tractability.md` §3). A
`CHECK` comparing two columns, or a non-numeric column, is still declined by
name, as is `UNIQUE`: rules have no inequality on atoms, so "two distinct rows
agree" cannot be written.

**Provenance pragmas and the bridge contract.** A `; writ:origin TEXT` comment
above a `transition`, `equation` or form invocation is echoed beside the move
or law in every report (`[orders.sql:14]`; `origin` in `--json`). `writ sql`
emits one per `CHECK`, so a violation names the DDL line. **`docs/bridges.md`**
writes down the contract the four bridges share, for the next one.

**`regime:` in the build report**: `committing — no move can be undone` or
`reversible — 36 of 36 situations lie on cycles`, measured from the phase
partition (`regime` in `--json`). It tells you whether adding vocabulary is
free. **`docs/tractability.md`** (new) gives the four conditions under which a
domain fits Writ.

**`writ graph`** draws the state space in D2, DOT or JSON as its phases —
classes of mutually reachable situations joined by one-way moves — which stays
readable where the raw space does not. `--states` draws every situation (up to
400); `--witness P` highlights a property's route.

**`(show QUERY…)` on a property** answers the named queries at the situation
the verdict singles out — the stuck one of a failing `live`/`inevitable`, the
violating one of a failing `never`, the satisfying one of a holding
`possible` — so a failure reports who is affected. Unknown names are refused
on read; `show` in `--json`. Kernel §16.1.

**Witnesses show where each step lands and what it changed**:
`1. grant-breakglass-admin   → #2   mallory.role: user → admin`. `stuck at:`
leads with the same index, and a property's description prints under its
verdict. The move name stays in place, so existing scripts keep working.

**`--json`** on `check`, `query`, `compare`, `show` and `derive`: the same
answer as one JSON object, rendered from the same values as the prose, with
vacant cells as `null` and the exit status as `exit`. Schema in `docs/json.md`;
prose stays the default.

## 0.2.0 — 2026-09-06

The first released version. It is 0.2.0 because `v0.1.0` and
`ghcr.io/writ-lang/writ:0.1.0` already name an older commit, and re-cutting
that tag would move it under anyone who pinned it.

**The language.** Its twenty-six kernel words: `schema` / `type` / `arrow` with its
qualifiers, `instance`, `initial`, `use`, `transition` with `when` / `do`,
`equation`, `gap`, `form`, `load`. Forms are hygienic, non-recursive macros, so
expansion terminates and errors point at real source.

- A law holds a **guard** rather than a pair of chains (§8.6), so `=` is now a
  standard-library form, joined by `differ`.
- Both sides of `is` (§10.2) and `set` (§10.3) may be **chains**. Effects read
  the situation the move started from, so a `do` block is a simultaneous
  assignment (`(do (set a.x b.y) (set b.y a.x))` swaps). A chain with no answer
  makes the move absent rather than a self-loop, so dead ends still report.

**The interrogator.** Enumerates the reachable state space and answers
`.claims` by exhaustion: `never`, `possible` and `live`, each with a shortest
witness. Reports gaps, dead ends, and per-equation observation (which move can
break a law, where it is violated, unadmitted or stale acknowledgments). Named
queries print their bindings.

**The tools.** `writ check`, `query`, `compare` (with `--git` across
revisions), `control` (the dynamics as a `quiver` instance), `derive`, `--help`
and `--version`. Exit status: 0 clean, 1 a finding, 2 unreadable input.

**The relational extension** (`docs/interrogator.md`). `.rules` files hold
stratified rules over the enumerated universe, state category included.
`writ derive MODEL.writ RULES.rules RELATION` prints rows, `"(RELATION ARG…)"`
binds any position (so dynamics run backward), and `--why` prints a derivation
tree. Errors are reported at read time with a `line:col`, and writ-problems
cross-checks `derive` against `check`.

**A SQL bridge.** `writ sql` converts between a relational schema and an
olog: tables become types, foreign keys arrows, `NULL` `vacatable`, enums
enumerated types, single-row `CHECK`s laws — so `writ check` names the move
that can break a constraint. What an olog cannot hold (`UNIQUE`, arithmetic) is
reported by line; `--strict` makes that a finding. It reads pg_dump output and
round-trips through `-- writ:` pragmas.

**Editor support.** `writ-lsp`: diagnostics from the engine, completion, hover
and an outline for `.writ`, `.claims` and `.rules`. The VS Code client is
[writ-vscode](https://github.com/writ-lang/writ-vscode) and finds `writ-lsp` on
`PATH`.

**An MCP server.** `writ-mcp` exposes `writ_check`, `writ_query` and
`writ_derive`; errors come back as `file:line:col` so an assistant can retry. A
Claude skill ships in `.claude/skills/writ/`.

**Packaging.** An opam package (`writ`, `writ-lsp`, `writ-mcp`, the standard
library); a static release tarball verified on glibc and musl;
`make install-writ` into `~/.local`; and a Docker image.

**Releases from a tag.** A version tag builds and smoke-tests tarballs for
`x86_64` and `aarch64`, attaches them to a GitHub release, and pushes a
multi-arch `ghcr.io/writ-lang/writ`. `scripts/check-release-tag.sh` refuses a
tag that disagrees with `dune-project` or goes backwards.

**Three repositories.** Scenarios moved to
[writ-problems](https://github.com/writ-lang/writ-problems) and the editor
client to [writ-vscode](https://github.com/writ-lang/writ-vscode); both need
only an installed `writ`. Domain libraries are user code; `stdlib.writ` is the
only one shipped.

**One rename.** The many-to-many form is `span`, not `relation`, which now
belongs to `.rules` declarations. Replace `(relation R A B)` with
`(span R A B)` in your models.

Not built yet: the §16.4 schema dictionaries (`functor`, `check … via`) and §17
fiber reporting.
