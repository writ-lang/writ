# Solving problems with `pol`

A sequence of end-to-end tests that **use the `pol` tooling to solve real
problems** and check the answers. Each problem is written as a Pol model
(`.pol`) with its questions kept next door (`.claims`), exactly as the spec
prescribes; the test runner calls `pol check` (and, for `oversight`, `pol
compare`) and asserts the verdicts.

The first batch is puzzles: the two from the spec's **Prologue** (Appendices C
and D), faithful to the spec, plus **eight queens**, which is not from the spec
but is the first thing the language could state once `differ` existed, and a
**blocking job shop**, whose deadlock is the trap detector at work on a real
scheduling question. Each
move is given a name so `pol` prints a legible solution path (see *Notes on the
solution path* below). The second batch is the three **§3 scenarios** — institutional architecture, a regulated
workflow, and access & privilege — which exercise `equation` laws, `accept`
acknowledgments and `pol compare`.

## The puzzles, and what `pol` answers

### 1. The river crossing (Appendix C) — `river/`
A farmer must ferry a wolf, a goat and a cabbage across a river; left
unattended with its prey, the wolf eats the goat and the goat eats the cabbage.

`pol check` answers:
- **`holds solvable`** — yes, everything *can* reach the far bank intact, **and
  `pol` prints the crossing** as the witness (the solution the question asked
  for): `cross-wolf-LR → cross-empty-RL → cross-goat-LR → …`.
- **`fails no-blunders`** — but not every path stays safe: there is a reachable
  arrangement from which the crossing can no longer succeed. The witness is the
  blunder — `cross-empty-LR → wolf-eats-goat-L` — and `stuck at:` shows
  `goat.at=∅`, the goat eaten.

### 2. Knights & knaves (Appendix D) — `island/`
Knights always tell the truth, knaves always lie. Reading a native's recorded
claim assigns a consistent kind — but "I am a knave" is consistent with
*neither* kind.

`pol check` answers:
- **`gaps: 1`** — the rules run out exactly once: reading cal (who said "I am a
  knave") is a declared hole ("the island's rules are silent").
- **`fails census-completable`** — so *not* everyone can be classified.
- **`holds abe-can-be-knight` / `holds bea-can-be-knight` / `fails
  cal-can-be-knight`** — abe and bea (who each said "knight") could each be a
  knight; cal could be *nothing at all*. That is the paradox, made mechanical.

Each `pol check` **exits 1** — not because anything is broken, but because it
*has a finding to report* (a possible blunder; an unclassifiable native). The
tests assert exit 1 as the correct outcome.

### 3. Eight queens — `queens/`
Eight queens on a board, none attacking another.

`pol check` answers **`holds solvable`**, and the witness *is* a solution —
the eight moves that place the queens. All 92 complete boards appear as dead
ends, a full board having no move left.

It earns its place for two reasons beyond the puzzle. It is the first thing
Pol can state that it could not before: a row clash is
`(differ q1.row q2.row)`, which had no spelling until §8.6 let a law hold a
guard and `differ` joined the standard library. And it carries the clearest
measurement here of *which* optimisation matters — the same puzzle without
one ordering conjunct has 118 969 situations instead of 2 057 and does not
finish in ten minutes, while an engine-level change that looked obviously
right measured to nothing. Both are written up in
[`queens/README.md`](queens/README.md).

Diagonals cannot be computed — `|Δrow| = |Δcol|` is arithmetic and Pol has
none — but they need not be enumerated either: rows are **entities on a
ladder** with `next`/`prev`, so the square a queen *d* columns away attacks
is `R.next` walked *d* times, and a form names that test once per distance.
Twenty literal conjuncts per move became nine that read. The models are still
generated, there being one move per (column, row), but that is the move set's
doing rather than the arithmetic's.

### 4. A blocking job shop — `jobshop/`
Three jobs, three machines, routed in a cycle, with no buffers: a job holds the
machine it is on until it has *acquired* the next one.

`pol check` answers **`holds all-finish`** — some schedule finishes every job —
and then **`fails never-stuck`**, naming a three-move circular deadlock in
full: `a-enters, b-enters, c-enters`, after which each job holds the machine
the next one is waiting for.

The pair is the lesson. A `possible` that holds says a good schedule exists and
says nothing about the bad ones you can walk into first; `live` is the
Prologue's wish 8, and it is the question a scheduler actually needs. Durations
and makespan are deliberately absent — those are arithmetic — but the classical
hard question about a *blocking* shop is whether a schedule exists at all,
which is pure reachability.

See [`jobshop/README.md`](jobshop/README.md).

## The spec's §3 scenarios

Three institutional models, each exercising machinery the Prologue puzzles do
not: **`equation` laws + `accept` acknowledgments** (§8.6, §15, §16.3) and
**`pol compare`** (§17).

### 5. Institutional architecture (§3 / §4 running example) — `oversight/`
The kernel-spec's own running example: two oversight agencies, one case
(`docket`), a possibly-vacant judge, and the structural law `same-agency` (the
investigating and prosecuting agencies must stand on equal footing). Schema,
instance, equation and moves are transcribed from §4; a single guard token is
changed (see the honest note below).

`pol check` answers:
- **`equation same-agency` / `can be broken by: capture-watchdog,
  restore-watchdog`** — the tool's guard-and-effect analysis names exactly which
  of our own powers can violate our own declared law (both write
  `watchdog.independence`, an arrow both routes of the law traverse). The
  `.claims` file **`accept`s both**, so neither is reported `unadmitted`;
  accepting a non-breaker (`conclude`, `assign-judge`) would be reported `stale`.
  Reachable violations are still listed.
- **`holds conviction-possible`** — the docket can conclude, and `pol` prints the
  concluding move as the witness.
- **`holds accountability`** — `(live (is docket.stage concluded))`: from every
  reachable situation the case can *still* conclude, because `restore-watchdog`
  can always undo a capture.

`oversight-repeal.pol` is the same model with `restore-watchdog` **deleted** —
an amendment that looks procedural. `pol compare oversight.pol
oversight-repeal.pol` reports its true cost:
```
properties:  accountability       LOST      witness: 1. capture-watchdog
```
and **exits 1**. One lawful capture now permanently destroys accountability: the
watchdog can never be restored, the investigation stalls, and the docket can
never conclude from that situation. `same-agency` and `conviction-possible` stay
`preserved` — the loss is precisely accountability.

> **Honest note.** In §4 *as printed*, `conclude` guards on the *prosecutor*'s
> independence while the capture power targets the *watchdog* (investigator) — so
> the two are decoupled and deleting `restore-watchdog` costs nothing (verified:
> the compare stays `preserved`, exit 0). To make the amendment's cost real —
> and keep the `same-agency` breaker list exactly `{capture-watchdog,
> restore-watchdog}` — `conclude` here guards on `docket.investigator.independence`
> (the bureau the capture power actually targets). That is the only departure
> from §4; capturing the prosecutor instead would add two more breakers.

### 6. Regulated workflow — KYC / claims (§3) — `workflow/`
A case wired (fixed) to a reviewing officer and its unit of record, a mutable
approving `officer`, and a vacatable `assignee` slot. The law `officer-in-unit`
(`(= case.officer.unit case.unit)`) demands the approving officer belong to the
unit of record.

`pol check` answers:
- **`gaps: 1` — `escalate`** — the automated process settles a case that has an
  assignee; where there is none it ends at a declared `gap` ("escalated to a
  human"). That is the boundary where automation stops and a person takes over.
- **`can be broken by: reassign-to-fraud, reassign-to-kyc`** — the reassignment
  moves are the law's breakers (both write `case.officer`); the `.claims`
  **`accept`s both**, so nothing is `unadmitted`.
- **`holds settle-able`** — `(live (is case.stage settled))`: **no case ever gets
  stuck**. Even in the escalation state (no assignee) the case can be assigned
  and then settled, so a settled situation stays reachable from everywhere.

### 7. Access & privilege (§3) — `access/`
Accounts with a `role` (user | admin), a `sponsor` (who vouches for them), and a
fixed `source` of authority. The law `traces-to-root`
(`(= account.sponsor.source account.source)`) demands each account inherit its
authority from its sponsor — the chain back to the security root.

`pol check` answers:
- **`can be broken by: delegate-alice-to-mallory`** — the one grant that rewires
  a `sponsor` to an externally-sourced account breaks the root-tracing law; the
  `.claims` **`accept`s** it (the role grants write `role`, off the law's route,
  so accepting them would be `stale`).
- **`fails revocation-possible`** — `(live (not (some (a account) (is a.role
  admin))))`: revocation is **not** always possible. `grant-breakglass-admin` is
  a **designed latch** — an emergency admin with no revoke move — so once it
  fires, `mallory` is admin forever and a "nobody is admin" situation can never
  be reached again. `pol` prints the stuck state and the single latching move as
  the witness (`1. grant-breakglass-admin`). §3 asks the model to say whether an
  irreversible grant is a latch or a defect; here the model declares it a latch.
- **`query admins`** — the accounts holding admin now (empty at the baseline).

## The remaining §17 surfaces — `control/`, `gitcompare/`

Two thin tests that exercise the last of the §17 command line on the models
above (no new model files).

### 8. `pol control` — dynamics as data — `control`
`pol control oversight.pol` emits the model's **move list** as an instance of the
standard library's `quiver` schema: one `node`, one `edge` per transition. The
test asserts it is a `(of quiver)` instance and then **wraps and re-checks it**,
proving the export is real Pol data that builds with the same machinery — the
seam toward simulation maps between two models' move lists.

### 9. `pol compare --git` — an amendment across commits — `gitcompare`
The `oversight` repeal, but as *history* rather than two files. The test spins up
a throwaway git repo, commits the law, then commits the repeal to the same path,
and runs `pol compare --git HEAD~1 HEAD law.pol` — reporting `accountability
LOST` across the two commits, exactly as `pol compare OLD NEW` did on the two
files. (Needs `git`; the Docker image installs it, and the local runner skips
this one gracefully if `git` is absent.)

## Run it

### With Docker (reproducible — builds `pol` from source)
```sh
docker compose build          # compile pol in a container, once
docker compose up             # run every puzzle; each service exits 0 iff its checks pass
docker compose run --rm river # just one
```
The image installs `pol` at `/usr/local/bin/pol` with the stdlib bundled at
`/usr/local/share/pol/lib`, so `(load "stdlib.pol")` resolves anywhere.

### Locally (needs `pol` on PATH — `make install` from the repo root)
```sh
./examples/run-tests.sh            # all puzzles
./examples/run-tests.sh river      # just the river
POL=/path/to/pol ./examples/run-tests.sh
```

## Adding a puzzle
1. Create `examples/<name>/<name>.pol` (the model) and `<name>.claims` (the
   questions). A `pol compare` scenario also ships a second `.pol` (see
   `oversight/oversight-repeal.pol`).
2. Add a `<name>()` function to `run-tests.sh` — run `pol check` (and
   `pol compare` if the scenario needs it, on absolute paths under `$here`) and
   assert the answers with `has …` / `near …` / `lacks …` / `exit_is …` — plus a
   case in the dispatch and the `all` runner at the bottom.
3. Add a service to `docker-compose.yml` (copy the `river` block, change the
   name + `command`).

## Notes on the solution path
- **A holding `possible` now prints its witness — the solution.** `possible F`
  asks "can this happen"; when it holds, `pol` shows the shortest path to an
  F-situation, which *is* the answer (the river's crossing; the reading that
  makes abe a knight). This matches the spec's Appendix C.
- **The moves are named.** A bare `form` produces *unnamed* transitions, which
  §10.1 renders only by position (`#0`, `#8`); a `form` can't synthesise a name.
  So each move here takes an explicit name slot (`cross-goat-LR`, `abe-is-knight`,
  `read-cal`), and the solution path reads as prose — faithful to the named moves
  Appendix C's own report shows.
