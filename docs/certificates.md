# Certificates

Every `writ check` writes `MODEL.cert.json` beside the model (`--certificate
FILE` to put it elsewhere, `--no-certificate` to skip it): everything a second
checker needs to re-derive the report without trusting the engine that
produced it — and then **hands it to that checker at once**. `writ-cert`,
compiled from [`lean/`](../lean/) and shipped in writ's image, re-derives every
answer, and its verdict is the report's last line:

```console
$ writ check river.writ --claims river.claims
…the usual report…
certified: every answer re-derived from the model (writ-cert)
```

A certificate nobody checks protects nobody, which is why the check is not a
separate step. writ still needs nothing: `writ-cert` is looked for
(`$WRIT_CERT`, then beside the `writ` executable, then the `PATH`), and where it
is missing the last line says so — `not certified: writ-cert is not
installed` — rather than passing over it. If it refutes the report, the line
is `NOT CERTIFIED`, the refuted answers follow, and the exit status is 1. With
`--json` the result is the object's `certification` field. [`lean/`](../lean/) is such a
checker, written and proved in Lean 4.

Run by hand, `writ-cert` prints its line-by-line account:

```console
$ writ-cert river.cert.json
writ 0.2.0 — certificate checked against the kernel semantics
certified    states  — 36 — exactly the reachable situations, pairwise distinct
certified    edges  — 76 — every move at every situation, as the semantics gives it
certified    dead ends  — none
certified    gaps  — none
certified    holds  solvable  — satisfied at #34; witness: a shortest route, 7 moves
certified    fails  no-blunders  — #1 is in a closed, F-free set of 26; witness: a shortest route to #1, 1 moves
verdict: every answer certified
```

![Every answer, checked twice: writ check writes a certificate, writ-cert re-derives the answer in Lean, and its verdict is the report's last line](diagrams/certified-check.svg)

## Why

writ's selling point is the negative answer: *no* reachable situation breaks
the law, *every* run decides. Until now that rested on one OCaml engine
saying so. A certificate turns it into a claim another program checks against
the kernel-spec semantics (§10, §12, §16.1), so a bug in the engine — a
dropped edge, a wrong fairness deletion, a witness that is not shortest — is
caught instead of believed.

## What is trusted, and what is not

| Trusted (not re-checked)                         | Checked                                                  |
|--------------------------------------------------|----------------------------------------------------------|
| writ's reader, `load` resolution and form expansion — the certificate's `model` is what they produced | the state space: the checker builds its own and proves it is exactly the reachable one |
| writ's `n/a` decision (a formula naming structure the schema lacks) | every `holds` / `fails` verdict, all four modalities, fairness included |
| the Lean kernel and, for `writ-cert` itself, the Lean compiler | every witness: a real route, landing where writ says, and shortest |
|                                                  | the counts: states (pairwise distinct), edges, law violations, dead ends, gap sites |

The checker does not trust its own search either. The algorithms that find
evidence (breadth-first search, Tarjan, Emerson–Lei) are unproved; the
conditions that evidence must meet are proved sound against the semantics. A
bug in the search can cost an answer (reported `uncertified`), never produce a
wrong one.

## The format (version 2)

One JSON object — the question, and writ's answer:

```json
{
  "format": "writ-certificate", "version": 2, "writ": "0.2.0",
  "model": {
    "types":       [{"name": "bank", "members": ["left", "right"]}],
    "layout":      [{"src": "farmer", "arrow": "at"}],
    "fixed":       [{"src": "docket", "arrow": "investigator", "value": "watchdog"}],
    "initial":     ["left"],
    "transitions": [{"name": "cross-goat-LR", "guard": G, "effects": [E]}],
    "equations":   [{"name": "same-agency", "subject": "case", "body": G}]
  },
  "properties": [{"name": "solvable", "modality": "possible", "fair": [],
                  "formula": G, "applicable": true}],
  "report": { …exactly what `writ check --json` prints (docs/json.md)… }
}
```

- **model** is the kernel model after the front end: forms expanded, loads
  spliced, the instance split into wiring (`fixed`) and the mutable slots
  (`layout`, which fixes the order of every situation's cells). `members` is
  each type's extent as `some` ranges over it. A transition's `name` is the
  label routes carry — its name, or `#i` by position for an unnamed one.
- **Guards** are tagged lists: `["and", G…]`, `["or", G…]`, `["not", G]`,
  `["is", PATH, RHS]`, `["defined", PATH]`, `["some", X, TYPE, G]`. A PATH is
  `[root, step…]`; an RHS is `{"lit": V}` or `{"chain": PATH}`. **Effects** are
  `["set", PATH, RHS]`, `["vacate", PATH]`, `["gap", MSG]`.
- **properties** are the questions, lowered; `applicable` is writ's n/a test.
- **report** is the answer being certified, unchanged.

**There is no state graph in it, on purpose.** The model determines the graph,
and the checker's soundness never rested on who built the graph it checks —
`reach_iff` holds for any candidate that passes. So the checker explores the
model itself, proves its own graph exact, and holds writ's answer to it: the
counts, the verdicts, and every situation a witness names by index (the
checker numbers situations in writ's breadth-first order, so an index means the
same situation to both). Version 1 carried writ's graph as well; it was 83% of
the bytes — 43 MB of a 52 MB certificate on a 119 000-situation space — and
bought only a sharper error message when writ's graph was wrong. Version 2 is
2.8 MB there, and a few KB for most models. The price is the checker's time:
it explores the space as writ did.

## The checker

See [`lean/README.md`](../lean/README.md): the reference semantics, the
soundness theorems, `writ-cert`, and `by writ` — writ properties as Lean
theorems.
