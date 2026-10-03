# The JSON output

With `--json`, every verb that answers a question prints one JSON object
instead of prose. Both are rendered from the same engine values
(`runtime/report.ml` and `tooling/report_json/report_json.ml`). The exit status
is unchanged and also carried as `exit`.

Everywhere:

- **A route carries landings.** A witness is `[{"move": M, "to": N}, …]`: the
  move's name and the index of the situation it lands in — the index `writ
  show --at N` and `writ query --at N` take.
- **A vacant cell is `null`** (the prose prints `∅`).
- **Names are the model's**, spelled exactly as the model spells them.
- **Provenance rides along.** A witness step and an equation carry `origin`:
  the text of the `; writ:origin …` pragma above the move or law
  ([bridges.md](bridges.md) §5), or `null`.

`writ check … --certificate FILE` writes this object into a certificate,
alongside the model, for a second checker to re-derive
([certificates.md](certificates.md)).

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
- `stuck_at` is where a failing `live` or `inevitable` is stuck (the last `to`
  of its witness), else `null`.
- `fair` lists the moves an `inevitable` assumes are not starved.
- `fibers`, with `--fiber CELL`: one object per value the cell takes —
  `{"cells": {"gov.regime": "normal"}, "verdict", "witness", "stuck_at"}` —
  the property asked of the situations holding that value (kernel §17).
- `show` holds the answers of the property's `(show QUERY…)` queries at the
  situation the verdict singles out, as query objects (`{"name", "at",
  "rows"}`); empty if there is none.
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

`status` is `"preserved"`, `"LOST"` or `"gained"`. A LOST property's witness
runs through the new model, with indices in its space.

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

`by` is `"phase"` or `"situation"`. A node's `id` is its situation's index (for
a phase, the least in it); `size` counts a phase's situations; `final` means
nothing leads out; `gaps` lists the gap messages fired from inside; `lit` marks
what a `--witness` route passes through.

## `writ derive MODEL RULES RELATION --json`

```json
{"relation": "reach", "columns": ["situation", "situation"],
 "rows": [["0", "0"], ["0", "1"]]}
```

Cells are strings, a situation as its index. `columns` names each column's
sort: `situation`, `edge`, or a schema type.

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

A fact with no `premises` is read off the model. A fact that does not hold
answers `{"fact": [...], "derived": false}` and exits 0.
