# Bridges: reading a foreign artifact as a model

A bridge reads something people already own — a database schema, an
architecture model, a solver's output, a parts catalogue — and emits a `.writ`
model of it, so `writ check` can be put to an artifact nobody wrote in Writ.
Four exist:

| bridge | reads | lives |
| --- | --- | --- |
| `writ sql` | a relational schema (DDL, `pg_dump`) | in this repository, `tooling/sql/` |
| [mgtt2writ](https://github.com/mgt-tool/mgtt2writ) | an mgtt architecture model | its own repository |
| `to_writ.py` in [writ-scheduling-verification](https://github.com/writ-lang/writ-scheduling-verification) | a curriculum and a CP-SAT timetable | its own repository |
| `writ-bank` in [writ-arch](https://github.com/writ-lang/writ-arch) | a Markdown catalogue of components | its own repository |

This page is the contract they share. A bridge is two verbs and a pipe —
`bridge INPUT > model.writ`, then `writ check model.writ` — and the engine
knows nothing of it. (`writ sql` is in-tree only because SQL is a notation, not
a product.)

## 1. Cut each quantity by the constants the rules mention

Writ has no numbers, so a bridge **quotients** them: cut a value's range into
the regions on which every predicate in the artifact is constant, and make each
region a member of an enumerated type. `connection_count < 500` gives
`below-500` and `at-or-above-500`, and nothing is lost, because nothing in the
artifact could tell two values in one region apart
([tractability.md](tractability.md) §3).

A predicate that couples two varying quantities (`start < end`, `spend <=
budget`) has no such quotient. Decline it.

## 2. Decline out loud, by line and by reason

Report everything the artifact says and the model does not on stderr, each with
its line and reason; a schema imported quietly makes "writ proved this safe" a
claim about a schema nobody has. `--strict` turns a decline into exit 1 for CI.

Every decline makes the model **laxer** than the artifact — with one
exception the importer flags rather than hides: SQL's `NOT VALID` adds a
constraint the existing rows were never checked against, and the model reads
it as holding for every row, which is stricter. `writ sql` keeps the
constraint and declines the clause, so `--strict` fails on it. Otherwise:

- a `never` that holds on the model holds on the artifact;
- a `possible` or `live` that holds may hold only in the model, since its
  witness may pass through a configuration the artifact forbids;
- a found violation is always worth reading, and may be spurious.

Universal claims transfer; existential ones do not. Put that sentence in the
bridge's README.

## 3. Name every move so a witness is a sentence

An unnamed transition prints as `#7`, and a witness of `#3, #7, #2` is an
answer nobody can act on. Name moves in the artifact's vocabulary — *the store
fails saturated*, *release r2 is deployed* — with a convention a reader can
invert. If the bridge also generates rules, derive move names from one shared
function: a rules file naming a move the model lacks derives nothing and
reports a clean bill of health.

## 4. Reserve the names the vocabulary already owns

Names are global across the loaded universe and cannot be redeclared (kernel
§7), so an artifact identifier that collides with a type, arrow, member or
`vacant` becomes a parse error its author never wrote. Keep a reserved set and
refuse a collision with the artifact's own name in the message
(`to_writ.py`'s `RESERVED`). Slugify identifiers to Writ's atom syntax, keep
display labels outside the model, and never invent a name the artifact cannot
be asked about.

## 5. Say where each move and law came from

A provenance pragma — a comment the language ignores and the interrogator
reads — makes a report name the source line:

```lisp
  ; writ:origin orders.sql:14
  (equation orders-shipped
    (not (and (is orders.status shipped) (not (defined orders.shipped-at)))))

; writ:origin iam.json: Statement[3]
(transition assume-dev-power
  (when …) (do …))
```

The text after `writ:origin` is free: `FILE:LINE`, an identifier, a URL. It
attaches to the move or law declared by the next datum (above a form
invocation, to every move it expands into) and is echoed in brackets wherever
that move or law is named:

```
equation orders-shipped   [orders.sql:14]
  violated in 2 reachable situations   witness: 1. ship → #5
fails  no-unapproved-exfil
  witness:  1. switch-to-auto       → #1   s.mode: ask → auto
            2. assume-dev-power     → #4   dev.assumed: ∅ → power   [iam.json: Statement[3]]
```

and as `origin` in `--json`. Pragmas are read from the model's own file, not
from loaded libraries, and never change a verdict. `writ sql` emits one above
every law it reads from a `CHECK`.

## A bridge is a reading

A bridge decides as little as it can and says what it decided — `to_writ.py`
decides only which hour of a subject a lesson is, and the claims catch it if
that is wrong. The questions stay in a `.claims` file the bridge does not
write, so the verdict is about the artifact, not the bridge's opinion of it.
