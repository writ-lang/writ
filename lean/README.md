# writ in Lean

Three things, in one Lean 4 package:

1. **A reference semantics** — what a writ model means, as Lean definitions
   ([`WritCert/Semantics.lean`](WritCert/Semantics.lean)), read clause by clause
   beside `runtime/eval.ml` and `runtime/space.ml`.
2. **A certificate checker, proved sound** — `writ-cert` holds every line of
   `writ check`'s report to the semantics, from the certificate
   `writ check` writes beside every model ([docs/certificates.md](../docs/certificates.md)).
3. **writ inside Lean** — `writ_model` brings a model and its claims in as
   Lean definitions, and `by writ` proves its properties as theorems the kernel
   checks.

## Building

Lean runs in a box, pinned (Lean v4.33.1, elan v4.2.4, the base image by
digest) — nothing is installed on the host:

```sh
make build        # every proof and example; the toolchain image builds once
make check F=river.cert.json   # writ-cert on a certificate
make test         # the fixtures certify, and every tampered certificate is refused
make corpus       # every model in ../tests and the sibling repositories (needs a built writ)
make image        # writ-cert alone, in a slim image that exists only if every proof checked
```

The binary writ's tarball and image ship is the `static` stage of the
[Dockerfile](Dockerfile): fully static, 4 MB, found by `writ check` beside
`writ`. From the repository root, `make writ-cert-bin` builds it and `make
release` puts it in the tarball. [`scripts/static-cc.sh`](scripts/static-cc.sh)
says what a static Lean link takes.

## `writ-cert`

`writ check` runs it on every certificate it writes, and its verdict becomes
the report's last line; writ's image ships it beside `writ`. Run by hand:

```console
$ writ check river.writ --claims river.claims      # writes river.cert.json
$ make check F=river.cert.json
certified    states  — 36 — exactly the reachable situations, pairwise distinct
certified    holds  solvable  — satisfied at #34; witness: a shortest route, 7 moves
…
verdict: every answer certified
```

Each line is **certified** (the checker's own certificate passed, writ agrees),
**DISAGREES** (writ said something the semantics refutes — a bug in writ), or
**uncertified** (the untrusted search found no evidence — a gap in the checker,
not a verdict). Exit 0 / 1 / 3 respectively, 2 for unreadable input.

## `by writ`

```lean
import WritCert
open Writ

writ_model river from "river.writ" claims "river.claims"   -- runs writ (or $WRIT)
-- writ_model river certificate "river.cert.json"          -- no writ needed

theorem river_solvable : river.solvable.Holds river.model := by writ
theorem river_blunders : ¬ river.«no-blunders».Holds river.model := by writ

#print axioms river_solvable   -- [propext, Classical.choice, Quot.sound]
```

`by writ` explores the space and finds a certificate at elaboration time
(untrusted), then closes the goal with `holds_of_check` / `fails_of_check`,
whose premises the **kernel** evaluates. `by writ (native := true)` uses
`native_decide` for spaces too large for the kernel, and `#print axioms`
says so. [`Examples/`](Examples/) has the river and every kind of
`inevitable` evidence.

`writ_model` takes the model writ's front end produced, and nothing else: the
verdicts in the certificate are ignored. The theorems are about
the model, not about what writ said of it.

## What is proved

| Theorem (`Writ.`)  | Says |
|--------------------|------|
| `reach_iff`        | a checked graph lists exactly the reachable situations (§12.3) |
| `count_exact`      | …and, with a checked sorting permutation, `states: N` counts them |
| `checkCert_sound`  | a checked certificate's verdict is the property's truth — `possible`, `never`, `live`, `inevitable` with fairness |
| `route_sound`      | a checked witness is a real route, landing where it says |
| `shortest`, `nearest` | …and no route to its end, or to any situation like it, is shorter |

The definitions they are about — `Reach`, `Possible`, `Live`, `Inevitable`,
`Escapes`, `AvoidsForever` — are the kernel spec's §12 and §16.1, written for a
reader, with no algorithm in them. Fair `inevitable` is the interesting one:
writ decides it with Emerson–Lei deletions, and a certificate records each
deletion as a rank and a set whose local conditions force every fair run to
leave the deleted situations for good (`round_step`); a final strictly falling
rank leaves no infinite run at all.

The proofs use the three standard axioms and no `sorry`.

## Scale

`writ-cert` explores the model itself (the certificate carries no graph), then
runs the checks it proves things about, compiled. Every model in the test suite
and the sibling repositories certifies (`make corpus`); the largest, the
unordered queens, is 118 969 situations and 564 880 edges — a 2.8 MB
certificate — checked in about two and a half minutes. `by writ` evaluates the same
checks in the kernel, which suits the small models a proof is usually about;
`(native := true)` lifts that limit at the price of trusting the compiler.

## Files

| File | |
|------|-|
| `WritCert/Semantics.lean` | the reference semantics — trusted, read it |
| `WritCert/Graph.lean`     | the graph certificate and `reach_iff` |
| `WritCert/Props.lean`     | property certificates and their soundness |
| `WritCert/Routes.lean`    | routes, distances, distinctness |
| `WritCert/Json.lean`      | a strict JSON reader — trusted, a page; Lean's own costs 74 MB |
| `WritCert/Import.lean`    | reading the JSON — trusted, a direct transcription |
| `WritCert/Generate.lean`  | finding certificates — untrusted, unproved |
| `WritCert/Verify.lean`    | holding each line of writ's report to a certificate |
| `WritCert/Tactic.lean`    | `writ_model`, `by writ` |
| `Main.lean`               | `writ-cert` |
