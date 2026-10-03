# writ

<img src="docs/images/writ-mark-200.png" alt="writ" width="120" align="left" hspace="16" vspace="4">

**Model a rule-governed world; get every consequence back, with the route.**

writ is a small language and a model checker for finite, rule-governed
systems: approval workflows, access rights, schema migrations, protocols,
institutional rules. You describe the world — what exists, how things point at
each other, which moves are allowed — and writ enumerates **every situation
those rules can produce**. Then it answers your questions by exhaustion: *yes,
and here is the route*, or *no, and none exists*.

<br clear="left">

## A taste

The river crossing: a farmer ferries a wolf, a goat and a cabbage; left alone,
the wolf eats the goat and the goat eats the cabbage. The model lives in
`river.writ`; the questions live beside it:

```lisp
;; river.claims
(property solvable
  "everything can reach the right bank intact"
  (possible (and (is farmer.at right) (is wolf.at right)
                 (is goat.at right)   (is cabbage.at right))))

(property no-blunders
  "from every reachable arrangement, the crossing can still succeed"
  (live (and (is farmer.at right) (is wolf.at right)
             (is goat.at right)   (is cabbage.at right))))
```

```console
$ writ check river.writ --claims river.claims
states: 36   edges: 76
regime: reversible — 28 of 36 situations lie on cycles
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
certified: every answer re-derived from the model (writ-cert)
```

The crossing is possible, and writ prints it — goat brought *back* on move 4.
But one careless first move strands a predator with its prey, and from there
nothing can be saved. The last line says a second, independent checker agreed.

**To write your own, start with [the tour](docs/tour.md)**: ten runnable steps
from a three-line model to the whole language.

## Why writ

Model checkers like Alloy or TLC search up to a size *you* choose, so "no
counterexample" always means "none within that bound". In writ the bound comes
from the model itself: the language has no numbers, no recursion and no
unbounded chains, so the set of situations is finite by construction. "No
reachable situation breaks this rule" is therefore a census, not a search that
gave up.

That restriction fits more domains than it sounds: anything with a fixed cast,
where moves set a slot to a name and quantities are compared against
constants. [docs/tractability.md](docs/tractability.md) is the test, and
[writ-problems](https://github.com/writ-lang/writ-problems) has worked models —
access and privilege, case-work, institutional design, two-phase commit,
schema migrations, scheduling, puzzles.

And every answer is checked twice: `writ check` writes a certificate, and
`writ-cert` — a checker proved sound in Lean — re-derives the answer from the
model ([docs/certificates.md](docs/certificates.md)).

## Install

**Release tarball** — static binaries for Linux x86_64 and aarch64, nothing
else needed:

```sh
v=writ-<version>-linux-$(uname -m)       # see the releases page
curl -fLO https://github.com/writ-lang/writ/releases/latest/download/$v.tar.gz
tar xzf $v.tar.gz && $v/install.sh       # -> ~/.local; or install.sh /usr/local
```

**Docker**

```sh
docker run --rm -v "$PWD":/w -w /w ghcr.io/writ-lang/writ check model.writ
```

**From source** — OCaml ≥ 4.14 and dune, nothing else:

```sh
opam pin add writ git+https://github.com/writ-lang/writ.git   # or, in a checkout:
make install-writ                                             # -> ~/.local
```

Every route installs `writ`, the language server `writ-lsp`, the MCP server
`writ-mcp` and the standard library. The tarball and image also carry
`writ-cert`; source builds add it with `make writ-cert-bin` (needs Docker).
Without it, reports end `not certified`.

## Using it

| Command | What it answers |
|---|---|
| `writ check MODEL [--claims F]` | size, gaps, dead ends, law violations; each property `holds` / `fails` with a route |
| `writ show MODEL --at N` | what situation N is, how to reach it, every move out |
| `writ compare OLD NEW` | which guarantees an edit kept, **LOST** and gained (`--git R1 R2 MODEL` across revisions) |
| `writ query MODEL NAME` | a named query's matching bindings |
| `writ derive MODEL RULES R` | a relation from a `.rules` file; `--why` shows the derivation ([docs/interrogator.md](docs/interrogator.md)) |
| `writ graph MODEL` | the state space as a picture (D2, DOT or JSON) |
| `writ sql SCHEMA.sql` | a database schema read as a model — and `writ sql MODEL` back to DDL |

`writ help VERB` has the details; `--json` gives any answer as one object
([docs/json.md](docs/json.md)). Exit status: **0** clean, **1** a finding,
**2** unreadable input.

**In an editor**: `writ-lsp` gives diagnostics, completion, hover and an
outline. The [VS Code client](https://github.com/writ-lang/writ-vscode) finds
it on `PATH`.

**From an AI assistant**: `writ-mcp` lets an assistant check its own model and
answer with a route instead of a guess. Install the Claude plugin, which runs
the server in Docker:

```
/plugin marketplace add writ-lang/writ
/plugin install writ@writ
```

Two things keep the assistant honest. With `writ-mcp --claims-dir DIR` the
questions are read from your directory, not from wherever the assistant points.
And every check reports which guarantees the latest edit **LOST** — including a
property turned `n/a` by deleting what it asked about.

## Documentation

- [docs/tour.md](docs/tour.md) — learn the language, step by step.
- [docs/kernel-spec.md](docs/kernel-spec.md) — the language, normative.
- [docs/tractability.md](docs/tractability.md) — whether a problem fits.
- [docs/interrogator.md](docs/interrogator.md) — `.rules` and `writ derive`.
- [docs/certificates.md](docs/certificates.md) and [lean/](lean/) — the certificate checker.
- [docs/json.md](docs/json.md), [docs/bridges.md](docs/bridges.md) — the JSON
  output, and how to import from another format.

## Developing

```sh
make build    # the engine, CLI and servers
make test     # the unit suites
make lint     # formatting and warnings-as-errors
```

Plain OCaml and dune, standard library only. The engine is three layered
libraries — data model, front end, interrogator — and only the three
executables (`tooling/cli`, `tooling/lsp/bin`, `tooling/mcp/bin`) do I/O.
Patches, the CLA and the release procedure: [CONTRIBUTING.md](CONTRIBUTING.md).

Not yet built: schema dictionaries (kernel spec §16.4) and `writ solve`.

## License

Copyright (C) 2026 Alex Kunich. [AGPL-3.0-or-later](LICENSE): if you
distribute a modified writ, or offer it to users over a network, its source
must be available under the same license. Your models are your own:
[LICENSE.exception](LICENSE.exception) covers them, everything the tool
emits, and the bundled standard library.
