# writ

<img src="docs/images/writ-mark-200.png" alt="writ" width="120" align="left" hspace="16" vspace="4">

**Model a rule-governed world; get every consequence back, with the route.**

A model is one page. What it *means* is every situation those rules can
produce — that page writ large, which is where the language gets its name.

A writ model is a state machine written down: a **schema** (the kinds of things
that exist and the typed arrows between them, plus the laws certain arrow-chains
must obey), an **instance** (one starting configuration), and **transitions**
(guarded moves). `writ` enumerates every reachable situation — a finite space —
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
$ writ check river/river.writ --claims river/river.claims
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

`writ` proves the crossing is possible **and prints one** (a holding `possible`
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

**The arrows are partial.** An olog's arrows must answer, for every thing; a
writ arrow may be `vacatable` and answer nothing. The alternative is to totalise — add a member meaning *none* — and the
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

At first almost every domain looks like it needs arithmetic: payments have
amounts, a timetable has hours, a shelf has a height. But numbers tend to
arrive in a model in only two ways — as *how many of something there are*, and
as *how one thing compares with another* — and each has a substitution that
gets rid of it. **Counting becomes naming. Calculating becomes writing down.**
Those two are what give the language its range. Take a payment waiting on
sign-off:

- **Counting becomes naming.** "A payment needs two signatures" is
  not the number two — it is two slots, either of which may be empty:

  ```
  payment 4471    first-sign  → nobody
                  second-sign → nobody
  ```

  *Fully signed* is both slots answering: a question about things, with
  nothing to add up.

- **Calculating becomes writing down.** "Is this over the limit?"
  is arithmetic. What the rules turn on is only which side of the limit the
  payment falls on, so that is what the model carries:

  ```
  payment 4471    band → large            not:   amount → 12,400
  ```

  Any calculation with finitely many answers can be written down instead of
  performed. In Writ, what you write it down as is arrows.

**The notation is s-expressions** because the object written down is a finitely
presented category: labelled nodes, each with a head naming its kind, a body
naming its parts, and containment where one thing belongs to another. `(arrow
independence (to indep-status))` inside `(type bureau …)` does not *encode*
ownership — the nesting **is** the ownership. Hence the kernel can stay at
twenty-six words, a new vocabulary being new heads rather than new grammar;
hence the extension mechanism can be *weaker* than a macro system and therefore
safe — `form` renames and pastes, it cannot compute, so every error still points
at a line you wrote; and hence a model can be **data** for another model, with
`writ control` and `writ schema` emitting its moves and its map as ordinary
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
| `writ check MODEL [--claims F]` | build the model; report size, gaps, dead ends and laws; check the `.claims` properties and queries |
| `writ query MODEL NAME [--at STATE] [--claims F]` | run one named query and print the satisfying bindings; questions come from the sibling `.claims` unless `--claims` names another |
| `writ compare OLD NEW [--map M]` | report each equation and property **preserved / LOST / gained** across two models |
| `writ compare --git R1 R2 MODEL` | …across two git revisions of one file |
| `writ control MODEL` | emit the move list as an instance of the standard library's `quiver` schema |
| `writ schema MODEL` | emit the model's schema as an instance of the standard library's `olog` schema |
| `writ sql SCHEMA.sql` | read a relational schema as an olog — tables become types, foreign keys arrows, NULL `vacatable`, enums enumerated types, single-row `CHECK`s laws |
| `writ sql MODEL.writ` | …and back: emit the model's schema as `CREATE TABLE` |
| `writ derive MODEL RULES.rules R` | answer a `.rules` relation over the model's enumerated universe — every row |
| `writ derive MODEL RULES.rules "(R A…)"` | …keeping only the rows that match, ALL-CAPS being a free variable, any position bindable (so the dynamics run backward) |
| `writ derive MODEL RULES.rules --why "(R A…)"` | print one fact's derivation tree instead of rows |
| `writ show MODEL [--at STATE]…` | print what a situation is — its cells, the fewest moves to it, and every move out |
| `writ help VERB` · `writ VERB --help` | one verb's reference — usage, options, examples, exit status |
| `writ --help` · `writ --version` | the full reference · the version this binary was built from |

Exit status is the interface: **0** clean · **1** a finding (a failed property; a
violated, unadmitted, or stale law; a lost-in-compare guarantee) · **2**
unreadable input.

### Relational schemas

**One verb, both directions — the direction is the extension.** Output goes to
stdout, like `writ schema` and `writ control`, so the ordinary use is a redirect:

```console
$ writ sql shop.sql > shop.writ        # a database, read as a model
$ writ check shop.writ                 # ask it something
$ writ sql shop.writ > back.sql        # and write it out again as CREATE TABLE
```

| | |
|---|---|
| `writ sql SCHEMA.sql` | read the DDL; print a model on stdout, the declines on stderr |
| `writ sql MODEL.writ` | print `CREATE TABLE` for the model's schema |
| `--with-data` | also read `INSERT`s, as the initial instance — **seed rows**, not a table dump |
| `--strict` | exit 1 if anything was declined (the shape a CI check wants) |
| `writ sql --help` | this, in the terminal |

Nothing is installed or loaded: the emitted model is **kernel-only** — no
`(load …)`, no prelude, nothing from the standard library.

Any verb that takes a model will read one from stdin instead, with `--stdin`:

```sh
writ sql schema.sql | writ check --stdin
```

The model is read once, so `--stdin` names one model per invocation. Errors in
a piped model report against `<stdin>`, and a `(load "lib.writ")` inside one
resolves against the current directory first.

**The payoff is what a database cannot do.** A `CHECK` becomes an `equation`,
and a law is a claim the world is measured against rather than a filter on it —
so once you write the migration's `UPDATE` as a move, `writ check` answers a
question the database never could:

```console
$ writ check shop.writ
equation orders-shipped
  can be broken by: ship   (acknowledge in claims)
```

A database tells you a constraint was violated *at runtime*. `writ` tells you
**which operation can violate it**, by exhaustion, before it ships.

**Why it is a reading rather than a translation.** A relational schema *is* a
finitely presented category, so the olog was already in the DDL, spelled in a
notation that cannot be interrogated:

| SQL | Writ |
|---|---|
| table | `(type T …)` |
| foreign key, `NOT NULL` / `NULL` | `(fk c T)` / `(fk? c T)` |
| `PRIMARY KEY` | nothing — an entity **is** its identity |
| `boolean`, enum, `CHECK … IN` | an enumerated type, members intact |
| `varchar`, `int`, `timestamptz` | an arrow into a **one-member** domain |
| single-row `CHECK` | `(equation …)` |

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

What crosses is decided by one line: **writ carries a column's value iff the
column has finitely many values worth naming.** A `varchar` becomes an arrow
into a one-member type, which is *free* — a total arrow into a one-member type
has exactly one filling, so a `NOT NULL` scalar column costs the state space
nothing. Nullability costs a factor of two, which is the one distinction writ
can decide about a `varchar`: whether it is there.

**What is declined is said out loud**, by line and reason, on stderr — never
dropped in silence, because a schema imported quietly would let "writ proved
this safe" be a claim about a schema nobody has. `UNIQUE` is the interesting
one: it is **unsayable**, not unimplemented, because a writ law ranges over one
entity of its subject type and a bare `some` binder is not comparable, so "two
distinct rows agree" has no spelling. Arithmetic in a `CHECK` is refused for
the reason the whole language is: there are no numbers, and inventing them
would cost the negative answer.

pg_dump is the input that matters, so casts, `= ANY (ARRAY[…])`, `ALTER TABLE …
ADD CONSTRAINT` and dollar-quoted function bodies all read correctly.

Round-tripping is defined on the **model**, not the text — the export
normalises spellings on purpose — and the two facts SQL cannot state (whether a
key is ever `UPDATE`d, whether a plain column is wiring) travel as `-- writ:`
pragmas the import reads back.

## Install

`writ` is a real opam package (`writ.opam`, generated from `dune-project`), and it
also installs without opam at all. Every route lands the same layout — `bin/`
holding `writ`, `writ-lsp` and `writ-mcp`, plus the `.writ` standard library at
`share/writ/lib`, which is where the resolver looks.

### With opam

**It is not in opam-repository**, so there is nothing to `opam install writ`.
Pin it — this needs no checkout, opam does the cloning:

```sh
opam pin add writ git+https://github.com/writ-lang/writ.git
eval $(opam env)          # if this is the first thing in the switch
writ --version
```

From a checkout, any of these:

```sh
opam install .            # build and install into the current switch
opam pin add writ .        # …and keep it pinned to this directory
make opam-install         # the same thing, through the Makefile
```

Two things to know. opam builds from your **git HEAD**, so uncommitted work is
invisible to it — commit first, or pass `--working-dir`. And a pin follows the
branch it was taken from; `opam upgrade writ` re-reads it. Remove with `opam
remove writ` (or `make opam-uninstall`), and drop the pin with `opam pin remove
writ`.

The package depends on `ocaml >= 4.14` and `dune >= 3.0` and **nothing else** —
the engine is OCaml stdlib only, JSON, JSON-RPC and the MCP protocol included.

### Without opam

```sh
make install-writ      # from this checkout -> ~/.local  (plain cp; no opam)
make install-writ PREFIX=/usr/local          # …or a prefix you name
make release          # a portable tarball -> dist/writ-<version>-linux-x86_64.tar.gz
```

`make install-writ` needs OCaml and dune to build, but no opam package
machinery, and installs all three binaries — the editor client looks for
`writ-lsp` on `PATH`, and an MCP client is pointed at `writ-mcp` by name, so
installing only `writ` leaves both with nothing to talk to. Undo it with `make
uninstall-writ`.

### Portable tarball

For a machine with no OCaml, no opam and no network: `make release` produces
one tarball holding **statically linked** binaries, the stdlib and an
`install.sh`. No libc version floor — the same tarball is verified
to run on Debian 12 (glibc) and Alpine (musl):

```sh
sha256sum -c writ-<version>-linux-x86_64.tar.gz.sha256   # built beside the tarball
tar xzf writ-<version>-linux-x86_64.tar.gz
cd writ-<version>-linux-x86_64 && ./install.sh          # -> ~/.local
                                 ./install.sh /usr/local   # -> a prefix you name
```

Building the tarball needs a static libc (`libc.a`) on the *build* host; where
there is none — macOS — use `make release STATIC=0` and accept a binary that
only travels between similar machines. `make release` prints what the binary
actually requires, so the portability claim is checked, not assumed.

Nothing external is needed to *use* `writ`. The bundled stdlib lets `(load
"stdlib.writ")` resolve from any directory (the resolver searches the including
file's dir, `$WRIT_LIB`, the copy beside the binary, then `./core/stdlib`); set
`WRIT_TRACE_LOADS=1` to print which file each load actually resolved to.

## Three repositories

| | |
|---|---|
| **writ** (this one) | the language, the engine, the CLI, `writ-lsp`, `writ-mcp`, the standard library |
| **[writ-problems](https://github.com/writ-lang/writ-problems)** | worked models — puzzles, scheduling, institutional scenarios — and a runner that checks the answers |
| **[writ-vscode](https://github.com/writ-lang/writ-vscode)** | the VS Code client |

The other two need an installed `writ`, not a checkout of this one.

### The examples

```sh
make install-writ
git clone https://github.com/writ-lang/writ-problems && cd writ-problems
./run-tests.sh                         # 222 checks over every scenario
```

Or with nothing installed on the host but Docker — `make image` here tags
`writ:latest`, which is what writ-problems builds from:

```sh
make image                             # in this checkout, once
cd ../writ-problems && docker compose up
```

The spec's Prologue puzzles (river, knights & knaves) and its §3 institutional
scenarios, plus eight queens and a blocking job shop asked twice — can every job
finish, and which schedule is shortest — and `arch`, which turns the tool
around and *designs* rather than checks: a bank of components, a brief, and
every architecture the constraints permit, enumerated. Every scenario also
carries a `.rules` file re-asking its `.claims` properties as derivations, and a
**cross-check** scenario runs both instruments over all thirty-one: `writ
check`'s CTL reading against `writ derive`'s rules encoding. Two independent implementations of one
question, so a disagreement is a bug in one of them rather than a number to
adjust — the only test whose oracle its author did not choose.

### Editor support

Syntax highlighting, live diagnostics from the real engine, completion, hover
and an outline — all served by `writ-lsp`, the same code the CLI runs.

```sh
make install-writ      # puts writ-lsp on PATH
git clone https://github.com/writ-lang/writ-vscode && cd writ-vscode && ./install.sh
```

The client finds the server on `PATH` with nothing to configure.

### From an AI assistant

`writ-mcp` is an MCP server over the same engine, exposing `writ_check`,
`writ_query` and `writ_derive` — so an assistant can model a problem and get an
answer with a **witness route** rather than a plausible guess.

```jsonc
// .mcp.json — this repository ships one already
{ "mcpServers": { "writ": { "command": "writ-mcp" } } }
```

**Or install it as a plugin**, which brings the skill and the server together:

```
/plugin marketplace add writ-lang/writ
/plugin install writ@writ
```

A *skill* is prose — it cannot install anything. A **plugin** can: it carries
skills and an `.mcp.json` in one manifest, so installing it registers the tools
and teaches the model when to reach for them in a single step. The plugin lives
in [`plugins/writ/`](plugins/writ/).

**It runs in Docker by default**, so installing the plugin installs nothing
native. The image is pinned to the plugin's version, pulled once on first use,
and the tools answer from it exactly as they would from a local build.

It does not bundle a binary: `writ-mcp` is native code, so shipping one would
mean a build per platform kept in step with a version the plugin cannot see,
and a stale one would answer with an old engine. A container has neither
problem.

The container mounts your working directory **at its own path**, read-only, so
absolute and relative paths both resolve. The limit is that mount: a model
*outside* the directory Claude started in is invisible to it. If you have writ
installed and would rather use it, `WRIT_MCP_NATIVE=1`; `$WRIT_MCP` names one
particular build; `$WRIT_IMAGE` names a different image.

A failing call answers with the parser's own `file:line:col` message rather than
dying, which is usually enough for the caller to fix the file and retry. A Claude
skill that knows when Writ is the right tool — and when it is the wrong one —
ships in
[`plugins/writ/skills/writ/`](plugins/writ/skills/writ/), carried by the plugin.

## Documentation

- **Start here:** [`docs/tour.md`](docs/tour.md) — ten steps from a three-line
  model to one using every idea in the language, each step runnable and each
  output the real one, ending in a **one-page cheat sheet**: the 26 words
  grouped, the grammar, the claims vocabulary, and the things that catch
  everyone once.
- **The language** (normative): [`docs/kernel-spec.md`](docs/kernel-spec.md) —
  the twenty-six words, the meaning of a model, the standard tool interface,
  and worked examples in its appendices.
- **The standard library:** [`core/stdlib/stdlib.writ`](core/stdlib/stdlib.writ) —
  25 lines of code, and the only `.writ` the tool ships. A **domain** library (a
  vocabulary for one subject, e.g.
  [`tests/models/politics.lib.writ`](tests/models/politics.lib.writ)) is ordinary
  user code and lives beside the models that load it.
- **The relational extension:** [`docs/interrogator.md`](docs/interrogator.md) —
  partly built. The `.rules` file, the built-in relations that expose the
  derived state category, and `writ derive` (§0–§2, §4, §5) ship; `writ solve`,
  the search for structure-preserving maps (§3), does not.

## Building from source

```sh
make build   # compile the engine, the CLI, and the two servers
make test    # the unit suites
make lint    # ocamlformat check + warnings-as-errors typecheck
make dev     # build + test, then refresh the installed binaries
```

`make build` does not install, which is right — a build should not touch your
`$PREFIX` — and is also how the `writ` on your PATH becomes a different program
from the one you just tested. `make dev` is the edit loop: build, test,
install. It leaves `lint` out on purpose, since `dune build` already compiles
with warnings-as-errors and a formatting check that fails on every
half-finished edit is a check you start skipping.

(A symlinked dev install would need no remembering, and does not work here:
dune's `_build/install/default/bin/writ` is itself a symlink into
`_build/default/tooling/cli/writ.exe`, `Sys.executable_name` resolves through
it, and the stdlib search is relative to the binary — so `../share/writ/lib`
lands inside `_build`.)

OCaml + dune, **stdlib only** — no external libraries (JSON, JSON-RPC and the
MCP protocol are hand-written). The layering is enforced by dune's own
dependency graph. Three **engine** libraries, each a strict layer:

| | |
|---|---|
| `writ_data` (`core/data/`) | the data model — a leaf, no dependencies |
| `writ_syntax` (`core/syntax/`) | the front end — depends on `writ_data` |
| `writ_runtime` (`runtime/`) | the interrogator — depends on `writ_data` **only**, so it is structurally incapable of reaching the front end |

Around them: `writ_loadpath` (the `(load …)` search order, shared so the CLI and
both servers can never disagree about where a library lives), `writ_json`, and a
pure library per server — `writ_lsp` and `writ_mcp`, each a function from messages
to messages.

All of those are IO-free. IO lives in exactly three executables — `tooling/cli/`,
`tooling/lsp/bin/` and `tooling/mcp/bin/` — a rule the dependency graph cannot
express, so two fitness gates check it instead — one over the engine
libraries, one over the servers and the shared JSON. The toolchain is resolved by
`scripts/with-ocaml.sh` (dune on `PATH`, else a central `writ` opam switch).

## Status

Built: the full language (schema / instance / transitions / equations / forms),
the interrogator (state-space enumeration, the four modalities with witnesses,
queries, equation observation), the tool interface `writ check` / `query` /
`compare` (+ `--git`) / `control` / `schema` / `derive` — the last being the
relational extension's rules engine over the enumerated universe — and two
servers, `writ-lsp` and `writ-mcp`.

Deferred: the §16.4 schema dictionaries (`functor` / `check … via`), §17 fiber
reporting, and the extension's own `writ solve` (its §3), which searches for
functors and simulations rather than deriving facts.

## License

Copyright (C) 2026 Alex Kunich. **GNU Affero General Public License, version 3
or later** ([LICENSE](LICENSE)) — free to run, study, modify and redistribute
for any purpose, including commercially. The condition is reciprocity: a
modified version you distribute **or offer to users over a network** must carry
the same license and make its source available to those users (AGPL §13, which
is what distinguishes the AGPL from the plain GPL). No warranty.

A model you write in Writ is your own work, not a derivative of `writ` — the
license covers the tool, not the `.writ` files it reads. That is not just an
opinion in a README: [`LICENSE.exception`](LICENSE.exception) grants it as an
additional permission under AGPL §7, covering your models, everything the tool
emits, and the bundled standard library. The kernel's syscall note is the same
construct for the same reason.

Patches are welcome — [`CONTRIBUTING.md`](CONTRIBUTING.md) explains the one-click
contributor agreement, which leaves you owning your work.
