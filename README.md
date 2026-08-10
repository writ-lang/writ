# pol

**Partial Olog — an abstract language for modelling real-world domains, and a
tool that proves facts about them.**

A Pol model is a state machine written down: a **schema** (the kinds of things
that exist and the typed arrows between them, plus the laws certain arrow-chains
must obey), an **instance** (one starting configuration), and **transitions**
(guarded moves). `pol` enumerates every reachable situation — a finite space —
and answers the questions you put to it *by exhaustion*, with a concrete route as
evidence.

The whole language is **twenty-six words**; everything else — ordering,
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

**Want to write one?** [The tour](docs/tour.md) goes from a three-line model to
the whole language in ten runnable steps, and ends in a one-page cheat sheet.
The rest of this page is why the language is shaped the way it is.

## Language design

Four decisions shape the language, and all four answer to one demand: **a model
must denote a finite object the tool can hold entire** — one that can be built,
walked, exported and diffed. Each is worked through in
[kernel-spec §2](docs/kernel-spec.md#2-language-design); in brief:

**The state machine is generated, not written.** Nothing you write is a state,
and nothing you write is an edge. The *schema* decides what a state **is**: an
arrow marked `fixed` is wiring, set once and never varying, and a state is one
filling of all the other arrows at once — so the state set is the product of
their targets, settled before a single move exists. The *instance* says which
state is initial. A *transition* is a guard and a change, **not** an edge: it
contributes one from every state its guard admits, so one datum can mean
thousands of edges, or none. The machine is the initial state closed under
them. The river: 54 arrangements on paper, twelve transitions, 76 edges over
the 36 reachable — and the file names none of those numbers. "Written down"
means *presented*, not enumerated.

**The arrows are partial** — which is what *Partial Olog* records. An olog's
arrows must answer, for every thing; Pol's may be `vacatable` and answer
nothing. The alternative is to totalise — add a member meaning *none* — and the
river prices it: give `bank` a third member `eaten` and `bank` has stopped
meaning a bank, since the *farmer*'s arrow points at the same type and
`farmer.at = eaten` becomes representable; the space grows 54 → 81, the 27 new
arrangements meaning nothing and needing guards to exclude; and in an
institutional model the same move drops a `nobody` into the box marked *a
person*, where it answers `nobody.employer`. Keeping the arrow partial buys
three things a total map cannot state:

- **Absence you can ask about.** A chain through an empty slot has no answer
  from that step on, so with the bench unstaffed `(is docket.judge.employer
  watchdog)` and `(is docket.judge.employer prosecutions)` are *both* false —
  the signature of an empty slot, not a contradiction — while `(defined …)`
  tells the cases apart. "The bench must always be staffable" is then a
  property the tool decides: `(live (defined docket.judge))`.
- **Moves that are undefined, not merely unused.** A guard is a move's *domain
  of definition*; a transition is a partial map of the state space, not a total
  one with a side condition attached.
- **Rules that admit where they run out.** `gap` ends the model rather than
  inventing a successor, so the native who says "I am a knave" is reported as a
  hole with the shortest route in.

Vacancy, non-applicability and silence are the ordinary case in these domains —
an office is empty, a clause does not apply, a statute says nothing. A total map
misreports all three.

**The language stops short of computation.** No numbers, no recursion, no
iteration, no unbounded chains; every list is finite, so termination is a
property of the grammar rather than something a model can lose. What that buys
is the **negative** answer. By Rice's theorem every non-trivial semantic
question about a Turing-complete language is undecidable, leaving a tool two
options: ask the author to supply the proof, or search and report what it found
— and the second cannot tell *no counterexample exists* from *none found within
the bound*. "One lawful move destroys accountability forever" is worth nothing
from a tool that might merely have looked less far. Here `never` is a census and
every verdict carries a route. The cost: no arithmetic, no unbounded
populations, no "for every *n*" — a domain that cannot be honestly reduced to
finitely many named distinctions is one this tool should not be pointed at.

**The notation is s-expressions** because the object written down is a finitely
presented category: labelled nodes, each with a head naming its kind, a body
naming its parts, and containment where one thing belongs to another. `(arrow
independence (to indep-status))` inside `(type bureau …)` does not *encode*
ownership — the nesting **is** the ownership. Hence the kernel can stay at
twenty-six words, a new vocabulary being new heads rather than new grammar;
hence the extension mechanism can be *weaker* than a macro system and therefore
safe — `form` renames and pastes, it cannot compute, so every error still points
at a line you wrote; and hence a model can be **data** for another model, with
`pol control` and `pol schema` emitting its moves and its map as ordinary
instances. That the fit is good is checkable rather than tasteful: `=` moved
from kernel word to library form without the grammar changing by a line; no
construct ever needed an operator or a precedence rule, guards included; the
notation states its own structure; and every worked model's properties are read
twice — once in branching time, once relationally — by two engines that agree.

## What an answer costs

Enumerating *every* situation invites one question ahead of all others: how big
does that get?

**The river's 36 is a product**, counted above: every cell a move can write,
multiplied out to 54 arrangements on paper, of which 36 are reachable.

Products grow fast, and that is the standing worry about exhaustive search. But
it is a worry about one *kind* of model, and there is another kind where the
product never forms at all.

**The other kind: a move commits a choice, and nothing revisits it.** Suppose
three slots to be filled in a fixed order, and suppose the guards leave 2
candidates for the first slot, 3 for the second, 2 for the third. Count the
situations by hand:

| once you have chosen | situations |
| --- | --- |
| nothing yet | 1 |
| the first slot | 2 |
| the first two | 2 × 3 = 6 |
| all three | 2 × 3 × 2 = 12 |

**21 situations in total, of which 12 are finished designs.** Nothing else is
reachable: there is no situation with the second slot filled and the first
empty, because the order forbids one. Every situation is a *prefix* of some
design.

**That generalises.** Write `aᵢ` for how many candidates survive the guards at
step `i`:

```
situations = Σ(k=0..n) Π(i≤k) aᵢ            designs = Π(i≤n) aᵢ
```

The sum's last term **is** the design count, and every earlier term is the one
after it divided by a step's candidate count. So where each step admits two or
more, all the earlier terms together cannot even double the last:

> **situations < 2 × designs** — and never more than `(n+1) ×`, even where some
> step is forced to a single candidate.

**Which inverts the worry.** Adding to the catalogue is free: a part the guards
reject costs one transition and *no situations at all*. Tightening a constraint
makes the search **smaller**. The price is set by how many answers there are —
not by how much vocabulary was on offer.

The practical reading: **a model is too big precisely when its answer set is too
big to have wanted.** A brief admitting a million designs was never a question
enumeration could answer; it was a brief needing more constraints.

Measured rather than argued, in the worked models next door: nineteen components
filling seven stages enumerate 96 designs in 184 situations; forbid one more
coupling and it is 144 in 232; demand one more property of a stage and it is 48
in 94 — each the formula's exact prediction.

**And the river is the other kind** — which is the contrast worth keeping. The
farmer can row back, so a crossing can be undone and made again, and no move
settles anything for good. There the product of the cells is real, and 36 is
what it costs.

## The CLI

| Command | Does |
|---|---|
| `pol check MODEL [--claims F]` | build the model; report size, gaps, dead ends and laws; check the `.claims` properties and queries |
| `pol query MODEL NAME [--at STATE]` | run one named query and print the satisfying bindings |
| `pol compare OLD NEW [--map M]` | report each equation and property **preserved / LOST / gained** across two models |
| `pol compare --git R1 R2 MODEL` | …across two git revisions of one file |
| `pol control MODEL` | emit the move list as an instance of the standard library's `quiver` schema |
| `pol schema MODEL` | emit the model's schema as an instance of the standard library's `olog` schema |
| `pol sql SCHEMA.sql` | read a relational schema as an olog — tables become types, foreign keys arrows, NULL `vacatable`, enums enumerated types, single-row `CHECK`s laws |
| `pol sql MODEL.pol` | …and back: emit the model's schema as `CREATE TABLE` |
| `pol derive MODEL RULES.rules R` | answer a `.rules` relation over the model's enumerated universe — every row |
| `pol derive MODEL RULES.rules "(R A…)"` | …keeping only the rows that match, ALL-CAPS being a free variable, any position bindable (so the dynamics run backward) |
| `pol derive MODEL RULES.rules --why "(R A…)"` | print one fact's derivation tree instead of rows |
| `pol --help` · `pol --version` | the full reference · the version this binary was built from |

Exit status is the interface: **0** clean · **1** a finding (a failed property; a
violated, unadmitted, or stale law; a lost-in-compare guarantee) · **2**
unreadable input.

### Relational schemas

A relational schema **is** a finitely presented category, so `pol sql` is a
reading rather than a translation — and one mapping read in both directions.
The SQL vocabulary arrives as **forms over the 26 words**, generated for the
database at hand rather than shipped, so a column is two tokens:

```lisp
(varchar-255 email)                  ; email varchar(255) NOT NULL
(timestamptz? shipped-at)            ; shipped_at timestamptz
(fk buyer-id customers)              ; a key never UPDATEd — wiring, so not state at all
(bool active)                        ; the one scalar whose values are worth naming
```

A domain type and its column form **share one name**, which is what makes two
tokens possible: a form with slots only expands in list-head position, so the
same word inside `(to …)` stays data.

What crosses is decided by one line: **pol carries a column's value iff the
column has finitely many values worth naming.** `boolean`, enums and `CHECK …
IN` keep their members; `varchar`, `int` and `timestamptz` become arrows into a
**one-member** domain — present, exportable, and *free*, since a total arrow
into a one-member type has exactly one filling. Nullability costs a factor of
two, which is the one distinction pol can decide about a `varchar`: whether it
is there. A primary key emits nothing at all — an entity **is** its identity.

The payoff is what a database cannot do. A `CHECK` becomes an `equation`, and a
law is a claim the world is measured against rather than a filter on it:

```console
$ pol sql schema.sql > shop.pol      # then write the migration's UPDATE as a move
$ pol check shop.pol
equation orders-shipped
  can be broken by: ship   (acknowledge in claims)
```

A database tells you a constraint was violated *at runtime*. `pol` tells you
**which operation can violate it**, by exhaustion, before it ships.

What the DDL says and an olog cannot hold is reported on stderr by line and
reason — never dropped in silence. `UNIQUE` is the interesting one: it is
**unsayable**, not unimplemented, because a pol law ranges over one entity of
its subject type and a bare `some` binder is not comparable, so "two distinct
rows agree" has no spelling. Arithmetic in a `CHECK` is refused for the reason
the whole language is: there are no numbers, and inventing them would cost the
negative answer.

Round-tripping is defined on the **model**, not the text — the export
normalises spellings on purpose — and the two facts SQL cannot state (whether a
key is ever `UPDATE`d, whether a plain column is wiring) travel as `-- pol:`
pragmas the import reads back.

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
./run-tests.sh                         # 98 checks over every scenario
```

Or with nothing installed on the host but Docker — `make image` here tags
`pol:latest`, which is what pol-problems builds from:

```sh
make image                             # in this checkout, once
cd ../pol-problems && docker compose up
```

The spec's Prologue puzzles (river, knights & knaves) and its §3 institutional
scenarios, plus eight queens and a blocking job shop asked twice — can every job
finish, and which schedule is shortest — and `arch`, which turns the tool
around and *designs* rather than checks: a bank of components, a brief, and
every architecture the constraints permit, enumerated. Every scenario also
carries a `.rules` file re-asking its `.claims` properties as derivations, and a
**cross-check** scenario runs both instruments over all twenty: `pol check`'s
CTL reading
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

**It runs in Docker by default**, so installing the plugin installs nothing
native. The image is pinned to the plugin's version, pulled once on first use,
and the tools answer from it exactly as they would from a local build.

It does not bundle a binary: `pol-mcp` is native code, so shipping one would
mean a build per platform kept in step with a version the plugin cannot see,
and a stale one would answer with an old engine. A container has neither
problem.

The container mounts your working directory **at its own path**, read-only, so
absolute and relative paths both resolve. The limit is that mount: a model
*outside* the directory Claude started in is invisible to it. If you have pol
installed and would rather use it, `POL_MCP_NATIVE=1`; `$POL_MCP` names one
particular build; `$POL_IMAGE` names a different image.

A failing call answers with the parser's own `file:line:col` message rather than
dying, which is usually enough for the caller to fix the file and retry. A Claude
skill that knows when Pol is the right tool — and when it is the wrong one —
ships in
[`plugins/pol/skills/pol/`](plugins/pol/skills/pol/), carried by the plugin.

## Documentation

- **Start here:** [`docs/tour.md`](docs/tour.md) — ten steps from a three-line
  model to one using every idea in the language, each step runnable and each
  output the real one, ending in a **one-page cheat sheet**: the 26 words
  grouped, the grammar, the claims vocabulary, and the things that catch
  everyone once.
- **The language** (normative): [`docs/kernel-spec.md`](docs/kernel-spec.md) —
  the twenty-six words, the meaning of a model, the standard tool interface,
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
