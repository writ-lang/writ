---
name: pol
description: Use when a question is about whether a rule-governed world can reach some situation — deadlock, unreachable states, "can this ever happen", "is there a schedule", scheduling and puzzle feasibility, or checking that a policy cannot be broken. Models the world in Pol and answers by exhaustive search with a concrete witness route, via the pol MCP server.
---

# Answering with Pol

Pol enumerates **every** reachable situation of a small rule-governed world and
answers questions about it by exhaustion. It does not sample, and it does not
approximate: a `holds` comes with the shortest route that makes it true, and a
`fails` comes with the shortest counterexample.

Reach for this when the honest answer needs a **proof over all cases** rather
than an argument. It is the right tool for deadlock, reachability, "can this
ever happen", scheduling feasibility and optimality on small instances, and
"can this policy be broken". It is the wrong tool for anything numeric,
recursive or unbounded — Pol has no arithmetic by design.

## The loop

1. **Write the model** (`.pol`) — the kinds of thing that exist, the typed
   arrows between them, one starting configuration, and the guarded moves.
2. **Write the questions separately** (`.claims`) — a model and the
   interrogation of it are two documents on purpose.
3. **Call `pol_check`** with both. Read the report.
4. If it will not parse, the error carries `file:line:col` and says what it
   wanted. Fix and re-run — do not guess.

## Reading a report

```
states: 51   edges: 87        how big the world turned out to be
gaps: none                    places the rules declare themselves silent
dead ends: 3                  situations with no move left, each with a route
holds  all-finish             true — and the witness route IS the example
  witness: 1. a-enters …
fails  never-stuck            false — with the shortest counterexample
  stuck at: …
```

**A witness under a holding `possible` is the answer, not evidence for it.** If
you asked "is there a schedule", the witness is the schedule. Quote it.

## The three modalities

| | asks |
| --- | --- |
| `possible F` | some reachable situation satisfies F |
| `never F` | no reachable situation does |
| `live F` | from **every** reachable situation, F is still reachable |

`live` is the one people forget and the one that finds traps. "Every job can
finish" is `possible`; "no schedule can paint itself into a corner" is `live`,
and a model can pass the first while failing the second — that is exactly what
a deadlock is.

## Optimising without arithmetic

There is no cost function. Ask for **decreasing N**; the smallest N that holds
is the optimum, and its witness is the optimal plan. Pin it from both sides —
one property that fails and one that holds is a *proof*, where either alone is
only a bound.

Time is a ladder of named ticks walked by an arrow, never a number.

## Tools

- **`pol_check`** — the verb to reach for first. Model, optional claims.
- **`pol_query`** — one named query, optionally at a chosen situation.
- **`pol_derive`** — a relation from a `.rules` file. `why: true` returns the
  **derivation tree**: why the engine believes a fact, down to the model facts
  it rests on. Use it when the answer matters enough to show your working.

A tool that fails answers with the engine's own message rather than dying —
read it, it is usually enough to fix the file.

## Writing a model

See `references/language.md` for the full shape, the keyword list, and worked
examples. Read it before writing your first model; the language is small but it
is not like other languages — laws are *observed*, not enforced, and a move
that cannot fire is *absent* rather than failed.
