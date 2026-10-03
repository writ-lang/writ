# writ in Lean

A Lean 4 package with three parts:

1. **A reference semantics** of writ models
   ([`WritCert/Semantics.lean`](WritCert/Semantics.lean)), to read beside
   `runtime/eval.ml` and `runtime/space.ml`.
2. **`writ-cert`, a certificate checker proved sound**, which holds every line
   of `writ check`'s report to the semantics ([docs/certificates.md](../docs/certificates.md)).
3. **writ inside Lean**: `writ_model` imports a model and its claims, and
   `by writ` proves its properties as kernel-checked theorems.

## Building

Lean runs in Docker, pinned (Lean v4.33.1, elan v4.2.4):

```sh
make build        # every proof and example; the toolchain image builds once
make check F=river.cert.json   # writ-cert on a certificate
make test         # the fixtures certify, and every tampered certificate is refused
make corpus       # every model in ../tests and the sibling repositories (needs a built writ)
make image        # writ-cert alone, in a slim image that exists only if every proof checked
```

writ's tarball and image ship the fully static binary from the `static` stage
of the [Dockerfile](Dockerfile) (see [`scripts/static-cc.sh`](scripts/static-cc.sh)).
From the repository root, `make writ-cert-bin` builds it and `make release`
puts it in the tarball.

## `writ-cert`

`writ check` runs it on every certificate it writes; its verdict is the
report's last line. By hand:

```console
$ writ check river.writ --claims river.claims      # writes river.cert.json
$ make check F=river.cert.json
certified    states  — 36 — exactly the reachable situations, pairwise distinct
certified    holds  solvable  — satisfied at #34; witness: a shortest route, 7 moves
…
verdict: every answer certified
```

Each line is **certified** (writ agrees with a checked certificate),
**DISAGREES** (the semantics refutes writ — a bug in writ), or **uncertified**
(no evidence found — a gap in the checker). Exit 0 / 1 / 3 respectively, 2 for
unreadable input.

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

`by writ` finds a certificate at elaboration time (untrusted) and closes the
goal with `holds_of_check` / `fails_of_check`, whose premises the kernel
evaluates. `by writ (native := true)` uses `native_decide` for large spaces,
visible in `#print axioms`. `writ_model` takes only the model from writ, not its
verdicts. [`Examples/`](Examples/) has the river and every kind of
`inevitable` evidence.

## What is proved

| Theorem (`Writ.`)  | Says |
|--------------------|------|
| `reach_iff`        | a checked graph lists exactly the reachable situations (§12.3) |
| `count_exact`      | …and, with a checked sorting permutation, `states: N` counts them |
| `checkCert_sound`  | a checked certificate's verdict is the property's truth — `possible`, `never`, `live`, `inevitable` with fairness |
| `route_sound`      | a checked witness is a real route, landing where it says |
| `shortest`, `nearest` | …and no route to its end, or to any situation like it, is shorter |

The definitions they are about (`Reach`, `Possible`, `Live`, `Inevitable`, …)
are the kernel spec's §12 and §16.1, with no algorithm in them. The proofs use
the three standard axioms and no `sorry`.

## Scale

`writ-cert` explores the model itself and runs the proved checks compiled; the
largest corpus model (about 119 000 situations) takes a few minutes. `by writ`
runs the same checks in the kernel, which suits small models;
`(native := true)` lifts that limit at the price of trusting the compiler.

## Files

| File | |
|------|-|
| `WritCert/Semantics.lean` | the reference semantics — trusted, read it |
| `WritCert/Graph.lean`     | the graph certificate and `reach_iff` |
| `WritCert/Props.lean`     | property certificates and their soundness |
| `WritCert/Routes.lean`    | routes, distances, distinctness |
| `WritCert/Json.lean`      | a strict JSON reader — trusted |
| `WritCert/Import.lean`    | reading the JSON — trusted, a direct transcription |
| `WritCert/Generate.lean`  | finding certificates — untrusted, unproved |
| `WritCert/Verify.lean`    | holding each line of writ's report to a certificate |
| `WritCert/Tactic.lean`    | `writ_model`, `by writ` |
| `Main.lean`               | `writ-cert` |
