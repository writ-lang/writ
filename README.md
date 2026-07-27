# pol

**Partial Olog — an abstract language for modelling real-world domains, and a
tool that proves facts about them.**

A Pol model is a state machine written down: a **schema** (the kinds of things
that exist and the typed arrows between them, plus the laws certain arrow-chains
must obey), an **instance** (one starting configuration), and **transitions**
(guarded moves). `pol` enumerates every reachable situation — a finite space —
and answers the questions you put to it *by exhaustion*, with a concrete route as
evidence.

The whole language is **twenty-eight words**; everything else — ordering,
quantifiers, relations, entire domain vocabularies — is a library of **forms**
over those words. Questions live *apart* from models, in `.claims` files, so one
question suite can be asked of many models, and comparing two versions of a model
is a tool operation.

## A taste

The river crossing (`river/` in [pol-problems](https://github.com/sajonaro/pol-problems)):
a farmer must ferry a wolf, a goat and a
cabbage across a river; left alone with its prey, the wolf eats the goat and the
goat eats the cabbage. The questions live beside the model:

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
  witness:  1. cross-goat-LR   2. cross-empty-RL   3. cross-wolf-LR
            4. cross-goat-RL    5. cross-cabbage-LR 6. cross-empty-RL
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
| `pol derive MODEL RULES.rules R` | answer a `.rules` relation over the model's enumerated universe — every row |
| `pol derive MODEL RULES.rules "(R A…)"` | …keeping only the rows that match, ALL-CAPS being a free variable, any position bindable (so the dynamics run backward) |
| `pol derive MODEL RULES.rules --why "(R A…)"` | print one fact's derivation tree instead of rows |
| `pol --help` | the full reference |
| `pol --version` | the version this binary was built from |

Exit status is the interface: **0** clean · **1** a finding (a failed property; a
violated, unadmitted, or stale law; a lost-in-compare guarantee) · **2**
unreadable input.

## Install

Three ways, all landing the same layout — `bin/pol` plus the `.pol` standard
library at `share/pol/lib`, which is where the resolver looks:

```sh
make install-pol      # from this checkout -> ~/.local  (plain cp; no opam)
make opam-install     # the opam package   -> the current switch
make release          # a portable tarball -> dist/pol-<version>-linux-x86_64.tar.gz
```

**opam.** `pol` is a real package (`pol.opam`, generated from `dune-project`), so
`opam install .` or `opam pin add pol .` on any machine with a switch builds and
installs `pol` **and** `pol-lsp` **and** the stdlib. Note opam builds from your
git HEAD — commit first, or pass `--working-dir`.

**Portable tarball.** For a machine with no OCaml, no opam and no network:
`make release` produces one tarball holding a **statically linked** binary, the
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

No opam or npm is needed to *use* `pol`. The bundled stdlib lets `(load
"stdlib.pol")` resolve from any directory (the resolver searches the including
file's dir, `$POL_LIB`, the copy beside the binary, then `./core/stdlib`).
Remove a `make install-pol` with `make uninstall-pol`, an opam install with
`make opam-uninstall`.

## The examples

The worked scenarios live in **[pol-problems](https://github.com/sajonaro/pol-problems)**
now — the models, their questions, and a runner that checks the answers. They
need an installed `pol` rather than this checkout:

```sh
make install-pol                       # pol, pol-lsp and pol-mcp onto PATH
git clone https://github.com/sajonaro/pol-problems && cd pol-problems
./run-tests.sh                         # 80 checks over every scenario
```

What is there:

- **river**, **island** (knights & knaves) — the spec's Prologue puzzles, each
  with its solution path shown.
- **oversight**, **workflow**, **access** — the spec's §3 institutional
  scenarios, exercising `equation` laws, `accept` acknowledgments, `pol compare`,
  a declared `gap`, and a privilege **latch**.
- **queens**, **jobshop-possible**, **jobshop-best** — eight queens in fifteen
  lines over a domain library, and a blocking job shop asked twice: can every
  job finish, and which schedule is shortest.
- **control**, **gitcompare** — `pol control` and `pol compare --git`.
- **crosscheck** — the modality cross-check. Each of the five scenarios above
  also carries a `.rules` file that re-asks its `.claims` properties as
  derivations, and this scenario runs both instruments over all 11 of them:
  `pol check`'s CTL reading against `pol derive`'s rules encoding. Two
  independent implementations of one question, so a disagreement is a bug in
  one of them rather than a number to adjust — the only test here whose oracle
  its author did not choose.

## Editor support

A VS Code extension — syntax highlighting, live diagnostics from the real
engine, completion, hover and an outline, all served by the same code the CLI
runs. It lives in **[pol-vscode](https://github.com/sajonaro/pol-vscode)**:

```sh
make install-pol      # puts pol-lsp on PATH
git clone https://github.com/sajonaro/pol-vscode && cd pol-vscode && ./install.sh
```

The server is `pol-lsp`, built here and installed alongside `pol`. The client
finds it on `PATH` with nothing to configure.

## Use it from an AI assistant

`pol-mcp` is an MCP server over the same engine, installed alongside `pol`. It
exposes three tools — `pol_check`, `pol_query` and `pol_derive` — so an
assistant can model a problem and get an answer with a **witness route** rather
than a plausible guess.

```jsonc
// .mcp.json — this repository ships one already
{ "mcpServers": { "pol": { "command": "pol-mcp" } } }
```

A failing call answers with the parser's own message rather than dying, which
is usually enough for the caller to fix the file and retry. There is a Claude
skill in [`.claude/skills/pol/`](.claude/skills/pol/) that knows when Pol is
the right tool and how to read a report.

## Documentation

- **The language** (normative): [`docs/kernel-spec.md`](docs/kernel-spec.md) — the
  single normative document: the twenty-eight words, the meaning of a model, the
  standard tool interface, and the worked examples in its appendices.
- **The standard library:** [`core/stdlib/stdlib.pol`](core/stdlib/stdlib.pol) —
  42 lines, and the only `.pol` the tool ships. A **domain** library (a
  vocabulary for one subject, e.g.
  [`tests/models/politics.lib.pol`](tests/models/politics.lib.pol)) is ordinary
  user code and lives beside the models that load it.
- **The relational extension:** [`docs/interrogator.md`](docs/interrogator.md) —
  partly built. The `.rules` file, the built-in relations that expose the
  derived state category, and `pol derive` (§0–§2, §4, §5) ship; `pol solve`,
  the search for structure-preserving maps (§3), does not.

## Building from source

```sh
make build   # compile the engine, CLI and language server
make test    # the unit suites
make lint    # ocamlformat check + warnings-as-errors typecheck
```

OCaml + dune, **stdlib only** — no external libraries (the JSON and JSON-RPC for
the language server are hand-written). The layering is enforced by dune's own
dependency graph, split into three libraries: `pol_data` (`core/data/` — the
data model, a leaf with no dependencies), `pol_syntax` (`core/syntax/` — the
front end, depends on `pol_data`), and `pol_runtime` (`runtime/` — the
interrogator, depends on `pol_data` *only*, so it is structurally incapable of
reaching the front end). All three are pure and IO-free; the only IO lives in
the CLI (`tooling/cli/`) and the language-server process (`tooling/lsp/bin/`) —
a rule the dependency graph cannot express, so it is held by convention and by
review. The toolchain is resolved by
`scripts/with-ocaml.sh` (dune on `PATH`, else a central `pol` opam switch).

## Status

Built: the full language (schema / instance / transitions / equations / forms),
the interrogator (state-space enumeration, the three modalities with witnesses,
queries, equation observation), and the tool interface `pol check` / `query` /
`compare` (+ `--git`) / `control` / `derive` — the last being the relational
extension's rules engine over the enumerated universe. Deferred: the §16.4
schema dictionaries (`functor` / `check … via`), §17 fiber reporting, and the
extension's own `pol solve` (its §3), which searches for functors and
simulations rather than deriving facts.

## License

Copyright (C) 2026 Alex Kunich. **GNU Affero General Public License, version 3
or later** ([LICENSE](LICENSE)) — free to run, study, modify and redistribute
for any purpose, including commercially. The condition is reciprocity: a
modified version you distribute **or offer to users over a network** must carry
the same license and make its source available to those users (AGPL §13, which
is what distinguishes the AGPL from the plain GPL). No warranty.

A model you write in Pol is your own work, not a derivative of `pol` — the
license covers the tool, not the `.pol` files it reads.
