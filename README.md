# pol

**Partial Olog — an abstract language for modelling real-world domains, and a
tool that proves facts about them.**

A Pol model is a state machine written down: a **schema** (the kinds of things
that exist and the typed arrows between them, plus the laws certain arrow-chains
must obey), an **instance** (one starting configuration), and **transitions**
(guarded moves). `pol` enumerates every reachable situation — a finite space —
and answers the questions you put to it *by exhaustion*, with a concrete route as
evidence.

The whole language is **twenty-seven words**; everything else — ordering,
quantifiers, equality, entire domain vocabularies — is a library of **forms**
over those words. Questions live *apart* from models, in `.claims` files, so one
question suite can be asked of many models, and comparing two versions of a model
is a tool operation.

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
$ pol check river/river.pol --claims river/river.claims
states: 36   edges: 76
gaps: none
dead ends: none
holds  solvable
  witness:  1. cross-goat-LR
            2. cross-empty-RL
            3. cross-wolf-LR
            4. cross-goat-RL
            5. cross-cabbage-LR
            6. cross-empty-RL
            7. cross-goat-LR
fails  no-blunders
  stuck at: (farmer.at=right wolf.at=left goat.at=left cabbage.at=left)
  witness:  1. cross-empty-LR
```

`pol` proves the crossing is possible **and prints one** (a holding `possible`
shows its solution) — the real safe crossing, right down to bringing the goat
*back* on move 4. It also finds the blunder: one careless crossing strands a
predator with its prey, and from there the crossing can never succeed.

## The CLI

| Command | Does |
|---|---|
| `pol check MODEL [--claims F]` | build the model; report size, gaps, dead ends and laws; check the `.claims` properties and queries |
| `pol query MODEL NAME [--at STATE]` | run one named query and print the satisfying bindings |
| `pol compare OLD NEW [--map M]` | report each equation and property **preserved / LOST / gained** across two models |
| `pol compare --git R1 R2 MODEL` | …across two git revisions of one file |
| `pol control MODEL` | emit the move list as an instance of the standard library's `quiver` schema |
| `pol schema MODEL` | emit the model's schema as an instance of the standard library's `olog` schema |
| `pol derive MODEL RULES.rules R` | answer a `.rules` relation over the model's enumerated universe — every row |
| `pol derive MODEL RULES.rules "(R A…)"` | …keeping only the rows that match, ALL-CAPS being a free variable, any position bindable (so the dynamics run backward) |
| `pol derive MODEL RULES.rules --why "(R A…)"` | print one fact's derivation tree instead of rows |
| `pol --help` · `pol --version` | the full reference · the version this binary was built from |

Exit status is the interface: **0** clean · **1** a finding (a failed property; a
violated, unadmitted, or stale law; a lost-in-compare guarantee) · **2**
unreadable input.

## Install

Three ways, all landing the same layout — `bin/` holding `pol`, `pol-lsp` and
`pol-mcp`, plus the `.pol` standard library at `share/pol/lib`, which is where
the resolver looks:

```sh
make install-pol      # from this checkout -> ~/.local  (plain cp; no opam)
make opam-install     # the opam package   -> the current switch
make release          # a portable tarball -> dist/pol-<version>-linux-x86_64.tar.gz
```

**opam.** `pol` is a real package (`pol.opam`, generated from `dune-project`), so
`opam install .` or `opam pin add pol .` on any machine with a switch builds and
installs all three binaries and the stdlib. Note opam builds from your git HEAD —
commit first, or pass `--working-dir`.

**Portable tarball.** For a machine with no OCaml, no opam and no network:
`make release` produces one tarball holding **statically linked** binaries, the
stdlib and an `install.sh`. No libc version floor — the same tarball is verified
to run on Debian 12 (glibc) and Alpine (musl):

```sh
sha256sum -c pol-<version>-linux-x86_64.tar.gz.sha256   # built beside the tarball
tar xzf pol-<version>-linux-x86_64.tar.gz
cd pol-<version>-linux-x86_64 && ./install.sh          # -> ~/.local
                                 ./install.sh /usr/local   # -> a prefix you name
```

Building the tarball needs a static libc (`libc.a`) on the *build* host; where
there is none — macOS — use `make release STATIC=0` and accept a binary that
only travels between similar machines. `make release` prints what the binary
actually requires, so the portability claim is checked, not assumed.

Nothing external is needed to *use* `pol`. The bundled stdlib lets `(load
"stdlib.pol")` resolve from any directory (the resolver searches the including
file's dir, `$POL_LIB`, the copy beside the binary, then `./core/stdlib`); set
`POL_TRACE_LOADS=1` to print which file each load actually resolved to. Remove a
`make install-pol` with `make uninstall-pol`, an opam install with
`make opam-uninstall`.

## Three repositories

| | |
|---|---|
| **pol** (this one) | the language, the engine, the CLI, `pol-lsp`, `pol-mcp`, the standard library |
| **[pol-problems](https://github.com/sajonaro/pol-problems)** | worked models — puzzles, scheduling, institutional scenarios — and a runner that checks the answers |
| **[pol-vscode](https://github.com/sajonaro/pol-vscode)** | the VS Code client |

The other two need an installed `pol`, not a checkout of this one.

### The examples

```sh
make install-pol
git clone https://github.com/sajonaro/pol-problems && cd pol-problems
./run-tests.sh                         # 80 checks over every scenario
```

Or with nothing installed on the host but Docker — `make image` here tags
`pol:latest`, which is what pol-problems builds from:

```sh
make image                             # in this checkout, once
cd ../pol-problems && docker compose up
```

The spec's Prologue puzzles (river, knights & knaves) and its §3 institutional
scenarios, plus eight queens and a blocking job shop asked twice — can every job
finish, and which schedule is shortest. Every scenario also carries a `.rules`
file re-asking its `.claims` properties as derivations, and a **cross-check**
scenario runs both instruments over all sixteen: `pol check`'s CTL reading
against `pol derive`'s rules encoding. Two independent implementations of one
question, so a disagreement is a bug in one of them rather than a number to
adjust — the only test whose oracle its author did not choose.

### Editor support

Syntax highlighting, live diagnostics from the real engine, completion, hover
and an outline — all served by `pol-lsp`, the same code the CLI runs.

```sh
make install-pol      # puts pol-lsp on PATH
git clone https://github.com/sajonaro/pol-vscode && cd pol-vscode && ./install.sh
```

The client finds the server on `PATH` with nothing to configure.

### From an AI assistant

`pol-mcp` is an MCP server over the same engine, exposing `pol_check`,
`pol_query` and `pol_derive` — so an assistant can model a problem and get an
answer with a **witness route** rather than a plausible guess.

```jsonc
// .mcp.json — this repository ships one already
{ "mcpServers": { "pol": { "command": "pol-mcp" } } }
```

**Or install it as a plugin**, which brings the skill and the server together:

```
/plugin marketplace add sajonaro/pol
/plugin install pol@pol
```

A *skill* is prose — it cannot install anything. A **plugin** can: it carries
skills and an `.mcp.json` in one manifest, so installing it registers the tools
and teaches the model when to reach for them in a single step. The plugin lives
in [`plugins/pol/`](plugins/pol/).

It does **not** bundle a binary. `pol-mcp` is native code, so shipping it would
mean one build per platform kept in step with a version the plugin cannot see —
and a stale one would answer with an old engine. The plugin's launcher finds the
`pol-mcp` you already installed (or `$POL_MCP`), and if there is none it says so
on stderr rather than failing silently.

A failing call answers with the parser's own `file:line:col` message rather than
dying, which is usually enough for the caller to fix the file and retry. A Claude
skill that knows when Pol is the right tool — and when it is the wrong one —
ships in [`.claude/skills/pol/`](.claude/skills/pol/).

## Documentation

- **The language** (normative): [`docs/kernel-spec.md`](docs/kernel-spec.md) —
  the twenty-seven words, the meaning of a model, the standard tool interface,
  and worked examples in its appendices.
- **The standard library:** [`core/stdlib/stdlib.pol`](core/stdlib/stdlib.pol) —
  25 lines of code, and the only `.pol` the tool ships. A **domain** library (a
  vocabulary for one subject, e.g.
  [`tests/models/politics.lib.pol`](tests/models/politics.lib.pol)) is ordinary
  user code and lives beside the models that load it.
- **The relational extension:** [`docs/interrogator.md`](docs/interrogator.md) —
  partly built. The `.rules` file, the built-in relations that expose the
  derived state category, and `pol derive` (§0–§2, §4, §5) ship; `pol solve`,
  the search for structure-preserving maps (§3), does not.

## Building from source

```sh
make build   # compile the engine, the CLI, and the two servers
make test    # the unit suites
make lint    # ocamlformat check + warnings-as-errors typecheck
```

OCaml + dune, **stdlib only** — no external libraries (JSON, JSON-RPC and the
MCP protocol are hand-written). The layering is enforced by dune's own
dependency graph. Three **engine** libraries, each a strict layer:

| | |
|---|---|
| `pol_data` (`core/data/`) | the data model — a leaf, no dependencies |
| `pol_syntax` (`core/syntax/`) | the front end — depends on `pol_data` |
| `pol_runtime` (`runtime/`) | the interrogator — depends on `pol_data` **only**, so it is structurally incapable of reaching the front end |

Around them: `pol_loadpath` (the `(load …)` search order, shared so the CLI and
both servers can never disagree about where a library lives), `pol_json`, and a
pure library per server — `pol_lsp` and `pol_mcp`, each a function from messages
to messages.

All of those are IO-free. IO lives in exactly three executables — `tooling/cli/`,
`tooling/lsp/bin/` and `tooling/mcp/bin/` — a rule the dependency graph cannot
express, so two fitness gates check it instead — one over the engine
libraries, one over the servers and the shared JSON. The toolchain is resolved by
`scripts/with-ocaml.sh` (dune on `PATH`, else a central `pol` opam switch).

## Status

Built: the full language (schema / instance / transitions / equations / forms),
the interrogator (state-space enumeration, the three modalities with witnesses,
queries, equation observation), the tool interface `pol check` / `query` /
`compare` (+ `--git`) / `control` / `schema` / `derive` — the last being the
relational extension's rules engine over the enumerated universe — and two
servers, `pol-lsp` and `pol-mcp`.

Deferred: the §16.4 schema dictionaries (`functor` / `check … via`), §17 fiber
reporting, and the extension's own `pol solve` (its §3), which searches for
functors and simulations rather than deriving facts.

## License

Copyright (C) 2026 Alex Kunich. **GNU Affero General Public License, version 3
or later** ([LICENSE](LICENSE)) — free to run, study, modify and redistribute
for any purpose, including commercially. The condition is reciprocity: a
modified version you distribute **or offer to users over a network** must carry
the same license and make its source available to those users (AGPL §13, which
is what distinguishes the AGPL from the plain GPL). No warranty.

A model you write in Pol is your own work, not a derivative of `pol` — the
license covers the tool, not the `.pol` files it reads.
