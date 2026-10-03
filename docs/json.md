# The JSON output

Every verb that answers a question answers it as prose by default, and as one
JSON object with `--json`. The object is not a parse of the prose: both are
rendered from the same engine values, by `runtime/report.ml` and
`tooling/report_json/report_json.ml` respectively, so they cannot drift. The
exit status is unchanged, and is also carried inside the object as `exit`,
because a consumer reading a pipe has no status to read.

Three conventions hold everywhere:

- **A route carries landings.** A witness is `[{"move": M, "to": N}, …]`: the
  move's name and the index of the situation it lands in. One numbering runs
  through the whole tool — `to` is what `writ show --at N` renders and
  `writ query --at N` evaluates at — so a witness can be followed without
  counting.
- **A vacant cell is `null`.** The prose prints `∅`; the object never does.
- **Names are the model's.** Moves, cells, properties and rows are spelled
  exactly as the model spells them.

## `writ check MODEL [--claims F] --json`

```json
{
  "states": 36, "edges": 76,
  "gaps":      [{"move": "read-cal", "message": "…", "min_moves": 2}],
  "dead_ends": [{"state": 17, "route": [{"move": "…", "to": 17}]}],
  "equations": [{"name": "same-agency",
                 "breakers": ["capture-watchdog", "restore-watchdog"],
                 "violated": {"count": 4, "witness": [{"move": "capture-watchdog", "to": 3}]}}],
  "unadmitted": [{"move": "…", "law": "…"}],
  "stale":      [{"move": "…", "law": "…"}],
  "properties": [{"name": "no-blunders", "description": "…",
                  "modality": "live", "fair": [],
                  "verdict": "fails",
                  "witness": [{"move": "cross-empty-LR", "to": 1}],
                  "stuck_at": 1}],
  "queries": [{"name": "admins", "at": 0, "rows": [{"a": "mallory"}]}],
  "exit": 1
}
```

- `violated` is `null` when the law is never broken in a reachable situation.
- `verdict` is `"holds"`, `"fails"` or `"n/a"`; an `n/a` carries `reason`.
- A holding `possible` carries its solution as `witness`; the other holding
  modalities carry an empty one.
- `stuck_at` is the index of the situation a failing `live` or `inevitable`
  is stuck at, and `null` otherwise. It equals the last `to` of the witness.
- `fair` lists the moves an `inevitable` assumed are not starved.
- `show` carries the answers of the property's `(show QUERY…)` queries at
  the situation the verdict singles out, each shaped as a query object
  (`{"name", "at", "rows"}`); empty when the property shows nothing or the
  verdict singles out no situation.
- Without `--claims`, `unadmitted`, `stale`, `properties` and `queries` are
  empty lists.

## `writ compare OLD NEW --json`

```json
{
  "equations":  [{"name": "same-agency", "status": "preserved", "witness": []}],
  "properties": [{"name": "accountability", "status": "LOST",
                  "witness": [{"move": "capture-watchdog", "to": 2}]}],
  "exit": 1
}
```

`status` is `"preserved"`, `"LOST"` or `"gained"`, as the prose spells them.
A LOST property's witness runs through the NEW model, and its landings are
indices in the new model's space.

## `writ show MODEL [--at N]… --json`

```json
{"situations": [{
  "index": 3, "initial": false,
  "cells": {"alice.role": "user", "docket.judge": null},
  "route": [{"move": "delegate-alice-to-mallory", "to": 3}],
  "moves": [{"move": "grant-alice-admin", "to": 5},
            {"move": "escalate", "gap": "escalated to a human"}]
}]}
```

A move out that ends at a gap carries `gap` (the message) instead of `to`.

## `writ query MODEL NAME [--at N] --json`

```json
{"name": "captured-bureaus", "at": 7, "rows": [{"b": "watchdog"}]}
```

## `writ graph MODEL [--witness P]… [--states] --json`

```json
{"by": "phase",
 "nodes": [{"id": 0, "size": 12, "initial": true, "final": false,
            "gaps": ["the text is silent"], "lit": true}],
 "edges": [{"from": 0, "to": 3, "moves": ["capture-watchdog"], "lit": true}]}
```

`by` is `"phase"` or `"situation"`. A node's `id` is the index of its
representative situation (the least in its phase) or the situation itself;
`size` counts the situations in a phase; `final` means nothing leads out;
`gaps` lists the messages of gap edges fired from inside. `lit` marks the
nodes and edges a `--witness` route passes through.

## `writ derive MODEL RULES RELATION --json`

```json
{"relation": "reach", "columns": ["situation", "situation"],
 "rows": [["0", "0"], ["0", "1"]]}
```

Cells are strings in every column; a situation column holds its index as a
string, exactly as the prose prints it. `columns` names each column's sort:
`situation`, `edge`, or a schema type.

With `--why`, the derivation tree:

```json
{"fact": ["reach", "0", "2"], "derived": true,
 "premises": [
   {"fact": ["edge", "nabu-speaks", "0", "1"], "premises": []},
   {"fact": ["reach", "1", "2"], "premises": [ … ]},
   {"guard": "is nabu.reports-to mid"},
   {"absent": ["quiet", "mid"]}
 ]}
```

A fact with no `premises` is a leaf read off the model. A fact that does not
hold answers `{"fact": [...], "derived": false}` and exits 0, as the prose
does — it is an answer, not a failure.
