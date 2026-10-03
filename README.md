# writ

<img src="docs/images/writ-mark-200.png" alt="writ" width="120" align="left" hspace="16" vspace="4">

**Model a rule-governed world; get every consequence back, with the route.**

A model is one page. What it *means* is every situation those rules can
produce — that page writ large, which is where the language gets its name.

writ is a model checker for finite business and governance systems: approval
workflows, entitlements, schema migrations, runbooks, configuration spaces,
protocols. A model is a state machine written down — a **schema** (the kinds of
thing that exist, the typed arrows between them, and laws they must obey), an
**instance** (one starting configuration) and **transitions** (guarded moves).
`writ` enumerates every reachable situation and answers questions by
exhaustion. Because the schema fixes how many situations there are, "no
reachable situation breaks this rule" is a census, not a search that gave up;
and every "yes" comes with the route that proves it.

The language is twenty-six words; everything else — ordering, quantifiers,
equality, domain vocabularies — is a library of **forms** over them. Questions
live apart from models, in `.claims` files, so one suite can be asked of many
models and two versions of a model can be compared.

## A taste

The river crossing: a farmer must ferry a wolf, a goat and a cabbage across a
river; left alone with its prey, the wolf eats the goat and the goat eats the
cabbage. The questions live beside the model:

```lisp
;; river.claims
(property solvable "everything can reach the right bank intact"
  (possible (and (is farmer.at right) (is wolf.at right)
                 (is goat.at right)   (is cabbage.at right))))

(property no-blunders "from every arrangement, the crossing can still succeed"
  (live (and (is farmer.at right) (is wolf.at right)
             (is goat.at right)   (is cabbage.at right))))
```

```console
$ writ check river/river.writ --claims river/river.claims
states: 36   edges: 76
gaps: none
dead ends: none
holds  solvable
  "everything can reach the right bank intact"
  witness:  1. cross-goat-LR      → #3   farmer.at: left → right, goat.at: left → right
            2. cross-empty-RL     → #8   farmer.at: right → left
            3. cross-wolf-LR      → #14   farmer.at: left → right, wolf.at: left → right
            4. cross-goat-RL      → #22   farmer.at: right → left, goat.at: right → left
            5. cross-cabbage-LR   → #30   farmer.at: left → right, cabbage.at: left → right
            6. cross-empty-RL     → #33   farmer.at: right → left
            7. cross-goat-LR      → #34   farmer.at: left → right, goat.at: left → right
fails  no-blunders
  "from every reachable arrangement, the crossing can still succeed"
  stuck at: #1 (farmer.at=right wolf.at=left goat.at=left cabbage.at=left)
  witness:  1. cross-empty-LR   → #1   farmer.at: left → right
```

A holding `possible` prints its solution — here the real crossing, goat
brought *back* on move 4. Each step says where it lands (`writ show --at 3`
renders `#3`) and what it changed. The failing `live` is the blunder: one
careless crossing strands a predator with its prey, and from there the crossing
can never succeed.

To write one, start with [the tour](docs/tour.md): ten runnable steps from a
three-line model to the whole language, ending in a one-page cheat sheet.

## What it is for

The same six shapes of question — a trap, a law violation, a vacancy, a
silence, a comparison, an embedding — asked of different domains.
[Appendix G](docs/kernel-spec.md#appendix-g--problems-tractable-with-writ)
lists the questions per domain; the worked models live in
[writ-problems](https://github.com/writ-lang/writ-problems):

| domain | the question it is usually asked | worked |
| --- | --- | --- |
| access and privilege | is there a grant sequence after which some privilege can never be revoked? | `access/` |
| regulated case-work | can a case reach a state that is neither settleable nor closable? | `workflow/` |
| constitutional and institutional design | can lawful moves alone permanently disable the oversight pipeline? | `oversight/`, `gotha/` |
| protocols and agreement | can the parties finish disagreeing, or be left waiting for ever? | `two-phase-commit/` |
| schema migrations and runbooks | is this plan safe at every instant, including mid-rollout? | `db-migration-problems/` |
| system design from a parts bank | which architectures satisfy the brief, and what does the brief fail to say? | `arch/` |
| scheduling and allocation | does a valid schedule exist, and is the one a solver produced acceptable? | `jobshop-*/`, `timetable/` |
| economic arrangements | which guarantees does one rule's repeal cost? | `calculation/` |
| games and puzzles | is it solvable, and is there a first-move blunder? | `river/`, `island/`, `queens/` |
| safety interlocks, clinical protocols, succession, incident runbooks | see Appendix G | — |

Whether a domain fits is a test, stated in
[docs/tractability.md](docs/tractability.md): a fixed cast; quantities compared
against constants, never against each other; moves that set a slot to a name;
an answer set small enough to want.

## Language design

Every design decision serves one demand: a model must denote a finite object
the tool can hold entire.
[Kernel-spec §2](docs/kernel-spec.md#2-language-design) works each through; in
brief:

- **The state machine is generated.** The schema fixes what a state is (one
  filling of every non-`fixed` arrow); a transition is a guard and a change
  that contributes an edge from every state its guard admits. The river's
  twelve transitions yield 76 edges over 36 reachable situations.
- **Arrows are partial.** A `vacatable` arrow may have no answer, so "the
  office is empty" needs no invented `nobody`, and "the bench must always be
  staffable" is `(live (defined docket.judge))`. `gap` marks where the rules
  run out instead of inventing a successor.
- **The language stops short of computation.** No numbers, recursion or
  unbounded chains, so every model terminates by its grammar — which is what
  lets a negative answer mean *none exists* rather than *none found within the
  bound*. Counting becomes naming (two signatures are two slots); calculating
  becomes writing down (a payment carries `band → large`, not `amount →
  12,400`).
- **The notation is s-expressions**, because a model is a finitely presented
  category and nesting *is* ownership. A new vocabulary is new heads, not new
  grammar; `form` renames and pastes but cannot compute, so every error points
  at a line you wrote.

The bound is what sets writ apart
([Appendix H](docs/kernel-spec.md#appendix-h--design-notes-neighbouring-languages)
has the full comparison):

| | the space searched | "no counterexample" means |
| --- | --- | --- |
| Alloy, TLC, bounded SMT | a scope or depth the **user** chose | none within that scope — a hedge that never goes away |
| writ | every situation the **schema** admits | none exists — a census |

**What an answer costs.** The river's 36 is a product of its cells, real
because the farmer can row back. Where every move commits a choice nothing
revisits, each situation is a prefix of a finished design, so situations stay
under twice the number of designs and a tighter constraint makes the search
smaller: a model is too big exactly when its answer set is too big to want.
`writ check` reports which regime a model is in (`regime: committing — no move
can be undone` or `regime: reversible — 36 of 36 situations lie on cycles`);
[docs/tractability.md](docs/tractability.md) §6 has the arithmetic.

## The CLI

| Command | Does |
|---|---|
| `writ check MODEL [--claims F]` | build the model; report size, gaps, dead ends and laws; check the `.claims` properties and queries |
| `writ query MODEL NAME [--at STATE] [--claims F]` | run one named query and print the satisfying bindings |
| `writ compare OLD NEW [--map M]` | report each equation and property **preserved / LOST / gained** across two models |
| `writ compare --git R1 R2 MODEL` | …across two git revisions of one file |
| `writ control MODEL` | emit the move list as an instance of the stdlib's `quiver` schema |
| `writ schema MODEL` | emit the model's schema as an instance of the stdlib's `olog` schema |
| `writ sql SCHEMA.sql` · `writ sql MODEL.writ` | read a relational schema as a model, or emit a model's schema as `CREATE TABLE` |
| `writ derive MODEL RULES.rules R` | every row of a `.rules` relation over the model's situations |
| `writ derive MODEL RULES.rules "(R A…)"` | …only matching rows; ALL-CAPS is a free variable, any position bindable |
| `writ derive MODEL RULES.rules --why "(R A…)"` | one fact's derivation tree |
| `writ show MODEL [--at STATE]…` | a situation's cells, the fewest moves to it, and every move out |
| `writ graph MODEL [--witness P] [--states] [--d2\|--dot\|--json]` | draw the state space — by default one node per class of mutually reachable situations — with a property's witness lit; `--states` draws every situation, under a cap |
| `… --json` | on `check`, `query`, `compare`, `show` and `derive`: the answer as one JSON object ([docs/json.md](docs/json.md)) |
| `writ help VERB` · `writ VERB --help` | one verb's reference |
| `writ --help` · `writ --version` | the full reference · the version |

Exit status: **0** clean · **1** a finding (a failed property; a violated,
unadmitted or stale law; a guarantee lost in `compare`) · **2** unreadable
input. Any verb that takes a model reads it from stdin with `--stdin`.

### Relational schemas

`writ sql` reads a database schema (DDL or `pg_dump`) as a model, or writes a
model's schema back as `CREATE TABLE`; the file extension picks the direction:

```console
$ writ sql shop.sql > shop.writ        # a database, read as a model
$ writ check shop.writ                 # ask it something
$ writ sql shop.writ > back.sql        # and write it out again as CREATE TABLE
$ writ sql shop.sql | writ check --stdin   # or pipe it straight in
```

Tables become types, foreign keys arrows, `NULL` `vacatable`, enums enumerated
types, and a single-row `CHECK` an `equation` — a law observed, not enforced —
so once a migration's `UPDATE` is written as a move, `writ check` names the
operation that can break it, before it ships:

```console
$ writ check shop.writ
equation orders-shipped
  can be broken by: ship   (acknowledge in claims)
```

What cannot cross (`UNIQUE`, a `CHECK` comparing two columns) is declined on
stderr by line and reason; `--strict` makes a decline exit 1, and `--with-data`
reads `INSERT`s as seed rows. Each imported law carries a `; writ:origin
shop.sql:14` pragma, so a violation names its DDL line. `writ sql --help` has
the full mapping; [docs/bridges.md](docs/bridges.md) is the contract for
writing a bridge of your own.

## Install

Every route installs `writ`, `writ-lsp` and `writ-mcp` under `bin/` and the
standard library under `share/writ/lib`. The tarball and the image also carry
`writ-cert`, the Lean checker that re-derives every `writ check` answer
([docs/certificates.md](docs/certificates.md)); without it a report ends `not
certified`. Source builds skip it unless you run `make writ-cert-bin` (docker)
before `make install-writ`.

**A released tarball** — static binaries for `linux-x86_64` and
`linux-aarch64` on the [releases page](https://github.com/writ-lang/writ/releases),
no toolchain needed:

```sh
v=writ-<version>-linux-$(uname -m)      # the version from the releases page
curl -fLO https://github.com/writ-lang/writ/releases/latest/download/$v.tar.gz
curl -fLO https://github.com/writ-lang/writ/releases/latest/download/$v.tar.gz.sha256
sha256sum -c $v.tar.gz.sha256
tar xzf $v.tar.gz && cd $v && ./install.sh     # -> ~/.local
```

**With opam** — writ is not in opam-repository, so pin it:

```sh
opam pin add writ git+https://github.com/writ-lang/writ.git
eval $(opam env)          # if this is the first thing in the switch
writ --version
```

or, from a checkout (opam builds git HEAD, so commit first or pass
`--working-dir`):

```sh
opam install .            # build and install into the current switch
opam pin add writ .        # …and keep it pinned to this directory
make opam-install         # the same thing, through the Makefile
```

Remove with `opam remove writ` (or `make opam-uninstall`) and `opam pin remove
writ`. The only dependencies are `ocaml >= 4.14` and `dune >= 3.0`.

**Without opam** — needs OCaml and dune; `make uninstall-writ` undoes it:

```sh
make install-writ      # from this checkout -> ~/.local  (plain cp; no opam)
make install-writ PREFIX=/usr/local          # …or a prefix you name
make release          # a portable tarball -> dist/writ-<version>-linux-x86_64.tar.gz
```

### Portable tarball

`make release` builds the same static tarball a release publishes, for any
commit. It runs on any Linux of its architecture (verified on Debian 12 and
Alpine):

```sh
sha256sum -c writ-<version>-linux-x86_64.tar.gz.sha256   # built beside the tarball
tar xzf writ-<version>-linux-x86_64.tar.gz
cd writ-<version>-linux-x86_64 && ./install.sh          # -> ~/.local
                                 ./install.sh /usr/local   # -> a prefix you name
```

Building it needs a static libc and docker. On macOS use `make release
STATIC=0 CERT=0`: a binary that only travels between similar machines and
certifies nothing.

`(load "stdlib.writ")` resolves from any directory — the resolver searches the
including file's directory, `$WRIT_LIB`, the copy beside the binary, then
`./core/stdlib`. `WRIT_TRACE_LOADS=1` prints which file each load resolved to.

## Three repositories

This one holds the language, the engine, the CLI, both servers, `writ-cert`
(`lean/`) and the standard library.
[writ-problems](https://github.com/writ-lang/writ-problems) holds the worked
models and a runner that checks their answers;
[writ-vscode](https://github.com/writ-lang/writ-vscode) is the VS Code client.
Both need an installed `writ`, not a checkout of this one.

### The examples

```sh
make install-writ
git clone https://github.com/writ-lang/writ-problems && cd writ-problems
./run-tests.sh                         # 222 checks over every scenario
```

or with only Docker (`make image` tags `writ:latest`, which writ-problems
builds from):

```sh
make image                             # in this checkout, once
cd ../writ-problems && docker compose up
```

Every scenario also re-asks its properties as `.rules` derivations, and a
cross-check compares `writ check`'s CTL reading with `writ derive`'s over all
of them: two independent implementations of one question.

### Editor support

Highlighting, live diagnostics, completion, hover and an outline, served by
`writ-lsp`; the client finds it on `PATH`:

```sh
make install-writ      # puts writ-lsp on PATH
git clone https://github.com/writ-lang/writ-vscode && cd writ-vscode && ./install.sh
```

### From an AI assistant

`writ-mcp` is an MCP server exposing `writ_check`, `writ_show`,
`writ_compare`, `writ_query` and `writ_derive` (each takes `json: true`), so
an assistant answers with a witness route instead of a guess.

```jsonc
// .mcp.json — this repository ships one already
{ "mcpServers": { "writ": { "command": "writ-mcp" } } }
```

`writ-mcp --claims-dir DIR` reads every claims file from DIR by basename,
whatever path a call names: the model is the assistant's, the questions are
yours. Each `writ_check` ends with a `revision:` block naming the guarantees
lost since the last model checked against the same claims, including a
property made `n/a`.

The Claude plugin in [`plugins/writ/`](plugins/writ/) registers the server and
a skill that knows when writ is the right tool:

```
/plugin marketplace add writ-lang/writ
/plugin install writ@writ
```

It runs `writ-mcp` in Docker, from an image pinned to the plugin's version,
with your working directory mounted read-only at its own path — so a model
outside that directory is invisible. `WRIT_MCP_NATIVE=1` uses an installed
writ instead; `$WRIT_MCP` names a particular build and `$WRIT_IMAGE` another
image.

## Documentation

- [`docs/tour.md`](docs/tour.md) — **start here**: ten runnable steps and a
  one-page cheat sheet.
- [`docs/kernel-spec.md`](docs/kernel-spec.md) — the language, normative.
- [`core/stdlib/stdlib.writ`](core/stdlib/stdlib.writ) — the standard library,
  the only `.writ` the tool ships. Domain libraries (e.g.
  [`tests/models/politics.lib.writ`](tests/models/politics.lib.writ)) live
  beside the models that load them.
- [`docs/interrogator.md`](docs/interrogator.md) — the relational extension:
  `.rules` and `writ derive` (§0–§2, §4, §5) ship; `writ solve` (§3) does not.
- [`docs/tractability.md`](docs/tractability.md),
  [`docs/json.md`](docs/json.md), [`docs/certificates.md`](docs/certificates.md),
  [`docs/bridges.md`](docs/bridges.md) — what fits, the JSON output, the
  certificate checker, and how to write a bridge.

## Building from source

```sh
make build   # compile the engine, the CLI, and the two servers
make test    # the unit suites
make lint    # ocamlformat check + warnings-as-errors typecheck
make dev     # build + test, then refresh the installed binaries
```

`make build` does not install, so `make dev` is the edit loop. (A symlinked
dev install does not work: the stdlib is found relative to the resolved
binary, which lies inside `_build`.)

OCaml and dune, standard library only; JSON, JSON-RPC and MCP are
hand-written. Dune enforces three engine layers: `writ_data` (`core/data/`,
the data model, a leaf); `writ_syntax` (`core/syntax/`, the front end, on
`writ_data`); and `writ_runtime` (`runtime/`, the interrogator, on `writ_data`
only, so it cannot reach the front end). Around them sit `writ_loadpath`, `writ_json`, and the server libraries
`writ_lsp` and `writ_mcp`. All are IO-free; IO lives only in `tooling/cli/`,
`tooling/lsp/bin/` and `tooling/mcp/bin/`, which two fitness gates check.
`scripts/with-ocaml.sh` resolves the toolchain.

## Cutting a release

The version lives only in `(version …)` in `dune-project`; the git tag just
triggers the workflows, so bump the version first:

```sh
# 1. bump the one line, and regenerate the opam file it feeds
$EDITOR dune-project              # (version 0.3.0)
make build                        # rewrites writ.opam
git commit -am "writ 0.3.0"

# 2. check the tag before pushing it — this is what CI will ask
sh scripts/check-release-tag.sh v0.3.0

# 3. annotate the tag: its subject becomes the first line of the release notes
git tag -a v0.3.0 -m "what this release is for, in one line"
git push origin main v0.3.0
```

`release.yml` builds the tarball on `x86_64` and `aarch64`, installs and runs
each (down to a `certified` check), and attaches them to a GitHub release.
`image-publish.yml` pushes `ghcr.io/writ-lang/writ` for both architectures.
Both refuse a tag that disagrees with `dune-project`. Every pull request runs
`ci.yml` plus the same tarball and image builds.

## Status

Built: the full language, the interrogator, `writ check` (with §17 fibers and
certificates) / `query` / `compare` / `control` / `schema` / `sql` / `derive` /
`show` / `graph`, the two servers, and writ-cert. Deferred: the §16.4 schema
dictionaries (`functor` / `check … via`) and `writ solve`.

## License

Copyright (C) 2026 Alex Kunich. **GNU Affero General Public License, version 3
or later** ([LICENSE](LICENSE)). A modified version you distribute **or offer
to users over a network** must carry the same license and make its source
available (AGPL §13). No warranty.

Your models are your own work, not derivatives of `writ`:
[`LICENSE.exception`](LICENSE.exception) grants this under AGPL §7, covering
your models, everything the tool emits, and the bundled standard library.

Patches are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md).
