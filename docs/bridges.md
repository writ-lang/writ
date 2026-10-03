# Bridges: reading a foreign artifact as a model

A bridge is a program that reads something people already own — a database
schema, an architecture model, a solver's output, a catalogue of parts — and
emits a `.writ` model of it, so that `writ check` can be put to an artifact
nobody wrote in Writ. Four exist, and each solved the same five problems on
its own:

| bridge | reads | lives |
| --- | --- | --- |
| `writ sql` | a relational schema (DDL, `pg_dump`) | in this repository, `tooling/sql/` |
| [mgtt2writ](https://github.com/mgt-tool/mgtt2writ) | an mgtt architecture model | its own repository |
| `to_writ.py` in [writ-scheduling-verification](https://github.com/writ-lang/writ-scheduling-verification) | a curriculum and a CP-SAT timetable | its own repository |
| `writ-bank` in [writ-arch](https://github.com/writ-lang/writ-arch) | a Markdown catalogue of components | its own repository |

This page is the contract they converged on, written down so that the fifth
bridge starts from here rather than from zero. **A bridge belongs to neither
project.** The pattern is two verbs and a pipe — `bridge INPUT > model.writ`
then `writ check model.writ` — and nothing in the engine knows a bridge
exists. (mgtt's decision record 0001 settled this for the first out-of-tree
bridge; `writ sql` is in-tree only because SQL is a notation, not a product.)

## 1. Cut each quantity by the constants the rules mention

Writ has no numbers, and the honest reduction is not to drop them but to
**quotient** them: a value's range is cut into the regions on which every
predicate in the artifact is constant, and the region becomes a member of an
enumerated type. `connection_count < 500` cuts an integer into two members,
`below-500` and `at-or-above-500`, and nothing is lost, because nothing in the
artifact could ever have told two values in one region apart.
[docs/tractability.md](tractability.md) §3 is the theorem; mgtt2writ's interval
cut and the parked MQTT design's topic atoms are two instances of it.

The line a bridge must not cross: a predicate that **couples two varying
quantities** (`start < end`, `spend <= budget`) has no finite quotient per
quantity. Decline it, and say so.

## 2. Decline out loud, by line and by reason

What the artifact says and the model does not is reported on stderr, every
construct, with its line and why — never dropped in silence. A schema imported
quietly lets "writ proved this safe" be a claim about a schema nobody has.
`--strict` turns a decline into exit 1, which is what a CI gate wants.

Say which way the loss runs. Every decline makes the model **laxer** than the
artifact — it admits configurations the artifact would refuse — so:

- a `never` that holds on the model holds on the artifact (the real space is a
  subset of the modelled one);
- a `possible` or `live` that holds on the model may hold only in the model,
  because its witness may route through a configuration the artifact forbids;
- a found violation is always worth reading, and may be spurious.

Universal claims transfer; existential ones do not. Put that sentence in the
bridge's README.

## 3. Name every move so a witness is a sentence

A witness prints move names. An unnamed transition prints `#7`, and a witness
of `#3, #7, #2` is an answer nobody can act on. A bridge knows what each move
means — *the store fails saturated*, *release r2 is deployed* — so it names
them, in the artifact's own vocabulary, with a convention a reader can
invert. mgtt2writ's `origination_move` / `propagation_move` live in one
module used by the emitter **and** by the rules it generates, because a rules
file that names a move the model lacks derives nothing and reports a clean
bill of health.

## 4. Reserve the names the vocabulary already owns

Names are global across the loaded universe and may not be redeclared (kernel
§7). An artifact's identifier that collides with a type, an arrow, a member or
`vacant` is a parse error the artifact's author did not write; `to_writ.py`
keeps a `RESERVED` set and refuses the collision with the artifact's own name
in the message. Slugify identifiers to Writ's atom syntax, keep the display
label outside the model, and never invent a name that the artifact cannot be
asked about.

## 5. Say where each move and law came from

A report names moves and laws. A bridge can make it name the **source line**
too, with a provenance pragma — a comment the language ignores and the
interrogator reads:

```lisp
  ; writ:origin orders.sql:14
  (equation orders-shipped
    (not (and (is orders.status shipped) (not (defined orders.shipped-at)))))

; writ:origin iam.json: Statement[3]
(transition assume-dev-power
  (when …) (do …))
```

The text after `writ:origin` is free: a `FILE:LINE`, an identifier in the
artifact, a URL. It attaches to the move or law declared by the next datum —
and, above a form invocation, to every move the invocation expands into — and
is echoed in brackets wherever that move or law is named:

```
equation orders-shipped   [orders.sql:14]
  violated in 2 reachable situations   witness: 1. ship → #5
fails  no-unapproved-exfil
  witness:  1. switch-to-auto       → #1   s.mode: ask → auto
            2. assume-dev-power     → #4   dev.assumed: ∅ → power   [iam.json: Statement[3]]
```

and as `origin` on every witness step and equation in `--json`. `writ sql`
emits one above every law it reads from a `CHECK`. Pragmas are read from the
model's own file; a library's comments are its own. Deleting every pragma
changes no verdict.

## What a bridge is not

A bridge is a **reading**, not a checker. It decides as little as it can and
says what it decided: `to_writ.py` decides exactly one thing (which hour of a
subject a lesson is) and the claims file catches it if it decides wrongly.
The questions stay in a `.claims` file the bridge does not write, so that the
verdict is about the artifact and not about the bridge's opinion of it.
