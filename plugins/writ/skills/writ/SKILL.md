---
name: writ
description: Use when a question is about whether a rule-governed world can reach some situation — deadlock, unreachable states, "can this ever happen", "is there a schedule", scheduling and puzzle feasibility, or checking that a policy cannot be broken. Models the world in Writ and answers by exhaustive search with a concrete witness route, via the writ MCP server.
---

# Answering with Writ

Writ enumerates **every** reachable situation of a small rule-governed world and
answers by exhaustion: a `holds` comes with the shortest route that makes it
true, a `fails` with the shortest counterexample.

Use it when the answer needs a proof over all cases: deadlock, reachability,
"can this ever happen", scheduling feasibility and optimality on small
instances, "can this policy be broken". Do not use it for anything numeric,
recursive or unbounded — Writ has no arithmetic. A domain fits
(`docs/tractability.md` in the writ repository) when it has a fixed cast,
quantities compared only against constants, moves that set a slot to a named
value, and an answer set small enough to want.

## The loop

1. **Write the model** (`.writ`): the kinds of thing, the typed arrows between
   them, one starting configuration, the guarded moves.
2. **Write the questions** in a separate `.claims` file.
3. **Call `writ_check`** with both and read the report.
4. A parse error carries `file:line:col` and says what it wanted. Fix and
   re-run; do not guess.

## Reading a report

```
states: 51   edges: 87        how big the world turned out to be
gaps: none                    places the rules declare themselves silent
dead ends: 3                  situations with no move left, each with a route
holds  all-finish             true — and the witness route IS the example
  witness: 1. a-enters   → #1   m1.held-by: ∅ → a
           2. …                 each step: where it lands, what it changed
fails  never-stuck            false — with the shortest counterexample
  stuck at: #7 (…)            the index is what `writ_show` / `show --at` take
```

**The witness of a holding `possible` is the answer.** If you asked "is there a
schedule", the witness is the schedule. Quote it.

**`dead ends` is a count, not a finding.** Some endings are the goal (the job
finished) and some are the world seizing up; only you know which. Say it as
`(inevitable F)`: an ending that does not satisfy F then fails with a route,
and the designed endings stay silent.

## The four modalities

| | asks |
| --- | --- |
| `possible F` | some reachable situation satisfies F |
| `never F` | no reachable situation does |
| `live F` | from **every** reachable situation, F is still reachable |
| `inevitable F` | …and no whole run avoids it |
| `inevitable F (fair M…)` | …assuming those moves are not starved for ever |

`live` finds traps: "every job can finish" is `possible`, "no schedule can
paint itself into a corner" is `live`, and passing the first while failing the
second is a deadlock.

`inevitable` asks whether the goal is unavoidable, not just still available —
what "does this terminate" means. Use it wherever parties act independently: a
protocol that retransmits a lost message passes `live` but fails `inevitable`
if a run can lose the message every time. Ask `live` for a capability the model
must not lose, `inevitable` for an outcome it must deliver.

`(fair MOVE…)` ignores runs in which a named move is offered for ever and never
taken — *it terminates, provided the network does not refuse to deliver for
ever*. The assumption lives in the claims file and both verdicts print it. It
cannot rescue a deadlock: a run that stops starves nothing.

## Optimising without arithmetic

There is no cost function. Ask for **decreasing N**; the smallest N that holds
is the optimum, and its witness is the optimal plan. Pin it from both sides —
one property that fails and one that holds is a proof; either alone is a bound.
Time is a ladder of named ticks walked by an arrow, never a number.

## Tools

- **`writ_check`** — the verb to reach for first. Model, optional claims. When
  the same claims file was checked before in this session, the reply ends with
  a `revision:` block listing the guarantees this model **LOST** against the
  previous one; read it before calling an edit done. The last line is
  `certified` when a checker proved sound in Lean re-derived every answer;
  `NOT CERTIFIED` means writ itself got it wrong — report that to the human, do
  not work around it.
- **`writ_show`** — what a situation is, by the index a witness step or
  `stuck at:` line names.
- **`writ_compare`** — which guarantees an edit kept, LOST and gained, the old
  model's claims put to both. Price your own edit with it.
- **`writ_query`** — one named query, optionally at a chosen situation.
- **`writ_derive`** — a relation from a `.rules` file; `why: true` returns the
  derivation tree down to the model facts it rests on.
- Every tool takes `json: true` to answer as the object `writ … --json` prints.
- **Newer servers** also list `writ_guide` (the language by topic, with worked
  examples and every error code) and `writ_validate` (parse and type-check,
  instantly). When `writ_guide` is listed, read its `index` before writing a
  model; when `writ_validate` is listed, run it before `writ_check`. Every file
  argument then also takes inline text (`model_source`, `claims_source`).

An index (`#17`, or a rules row's `17`) is not an answer: one numbering runs
through the whole tool, so follow it with `writ_show` and quote the situation,
not the number. A failing tool answers with the engine's own message; read it.

**Two rules the verifier holds you to.** A property reported `n/a` names
structure the model lacks — an arrow you deleted, a value you renamed — and it
is a **failure**, never a pass; do not make a check green by making its
question unaskable. And the questions are not yours to edit: when the server
runs with `--claims-dir`, every claims file is read from that directory by
its basename whatever path you pass, and the reply says which file it read.
Change the model until the human's questions hold.

## Writing a model

Read `references/language.md` before writing your first model: the full shape,
the keywords and worked examples. The language is small but unusual — laws are
*observed*, not enforced, and a move that cannot fire is *absent*, not failed.
