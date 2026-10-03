Writ is an explicit-state model checker for finite discrete systems. You write a world down — the kinds of thing in it, the typed arrows between them, one starting configuration, and guarded moves — and writ enumerates **every** reachable situation, then answers your questions by exhaustion: `holds` with the shortest witness route, `fails` with the shortest counterexample. There are no numbers and nothing unbounded; that is what makes `never` a census rather than a search that gave up.

## Workflow

1. Read `syntax.model`, `syntax.claims` and `semantics`; read `idioms` before modelling anything concurrent, retried or timed.
2. Write the model (`model_source`) and the questions (`claims_source`) as two separate texts.
3. `writ_validate`: parse and type-check without building anything. Repeat until `ok`, and read its summary: does the model declare what you meant? Is the situation bound small?
4. `writ_check`: build the space and answer every property.
5. `writ_show` on every `#N` a witness or a `stuck at:` line names; explain the route in the system's own terms.
6. After every edit, `writ_compare` the old model against the new one, or give `writ_check` the same `model_name` each time: either reports any guarantee the edit LOST.

## Topics

| topic | what it holds |
| --- | --- |
| `syntax.model` | the `.writ` grammar: every keyword, types, arrows, instance, moves, laws, forms, the standard library |
| `syntax.claims` | the `.claims` grammar: the four property kinds, fairness, queries, `accept` |
| `syntax.rules` | the `.rules` grammar: relations and rules over the space, for `writ_derive` |
| `semantics` | what each construct means: situations, moves, property kinds, `n/a`, witnesses, indices, compare |
| `idioms` | concurrency, messaging, time, counters, abstraction and size, choosing the property kind, the regression loop |
| `examples.mutex` | a check-then-act race; `never` |
| `examples.webhooks` | two workers, duplicated and reordered webhooks; a history cell; `never` and `live` |
| `examples.consumer` | retries and an idempotency key; a counter ladder; `inevitable` with fairness |
| `examples.commit` | two-phase commit; `some` and `all` |
| `examples.handoff` | a deadlock found by `live`; a fix that LOSES a guarantee, caught by `writ_compare` |
| `errors` | every error code; `errors.<code>` gives a wrong and a right example |

## Limits

- The search stops at `max_situations` (default 200000, at most 2000000) or `timeout_ms` of CPU time (default 60000, at most 600000) and returns `E_STATE_LIMIT`; nothing is decided then. Edges are not limited separately.
- The space is at most the product of every mutable cell's domain: three jobs with a three-valued stage each is 27 situations, ten such cells 59049. `writ_validate` prints this bound; keep it under about 100000.
- Inline sources are at most 256 KB each.

## Five rules that save a retry

1. Start with `(load "stdlib.writ")` if you use `all`, `differ`, `=` or `maybe`; there is no implicit prelude. Loading it reserves the type names `node`, `edge`, `ob`, `hom` and `eqn`.
2. Effects go inside `(do …)`. A property needs a description string; a query has none.
3. A law, `(equation NAME GUARD)`, is reported, not enforced; enforce a rule with a move's `when`.
4. There is no `always` (write `(never (not P))`) and there are no numbers (a counter is a ladder; see `idioms`).
5. A property reported `n/a` is a FAILURE: it names something the model lacks.
