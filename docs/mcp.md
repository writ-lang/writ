# writ for AI assistants (MCP)

`writ-mcp` lets an AI assistant — Claude Code, Claude Desktop, Cursor, any
MCP client — check rule-governed systems with writ instead of reasoning about
them in its head.

## What it gives you

Ask an assistant "can a case ever get stuck?" or "is this migration plan safe
mid-rollout?" and it will usually answer confidently. With writ it writes the
rules down as a model, writ explores **every** reachable situation, and the
answer comes back as a verdict with the route that proves it. The assistant
proposes; writ decides. You get:

- **answers you can check**: `holds` or `fails`, each with a concrete route —
  not a plausible paragraph;
- **"never" that means never**: writ's models are finite by construction, so
  "no situation breaks this rule" is a census, not a search that gave up;
- **an assistant that cannot quietly cheat**. Asked to make a check pass, an
  agent can weaken the model or the question instead of fixing the design.
  writ guards against both:
  - **your questions are pinned** — the server reads `.claims` files from your
    directory, whatever path the assistant passes;
  - **every check reports what the last edit LOST**, including a question made
    unanswerable (`n/a`) by deleting what it asked about;
  - **every answer is certified** by `writ-cert`, a checker proved sound in
    Lean ([certificates.md](certificates.md)).

Here is the second guard at work. The assistant checks the oversight model,
then "simplifies" it by repealing one power. The second reply ends:

```
fails  accountability
  "the docket can always still conclude"
  stuck at: #1 (watchdog.independence=captured prosecutions.independence=independent docket.stage=open docket.judge=∅)
  witness:  1. capture-watchdog   → #1   watchdog.independence: independent → captured
…
revision: against the previous model checked with oversight.claims — a guarantee was LOST
equations:   same-agency          preserved
properties:  conviction-possible  preserved
             accountability       LOST      witness: 1. capture-watchdog
certified: every answer re-derived from the model (writ-cert)
```

The edit cost a guarantee, and the reply says which one and how — so the
assistant cannot present it as done.

## Install

**Claude Code** — install the plugin. It brings the server and a skill that
tells Claude when writ is the right tool. It needs only Docker:

```
/plugin marketplace add writ-lang/writ
/plugin install writ@writ
```

The first call pulls `ghcr.io/writ-lang/writ` (pinned to the plugin's version).
Your working directory is mounted read-only, so models must live inside it. To
use a writ installed on your machine instead of Docker, set `WRIT_MCP_NATIVE=1`.

**Any other MCP client, with writ installed** (release tarball or
`make install-writ`):

```json
{ "mcpServers": { "writ": { "command": "writ-mcp" } } }
```

**Any other MCP client, with only Docker:**

```json
{ "mcpServers": { "writ": {
    "command": "docker",
    "args": ["run", "--rm", "-i", "-v", "/path/to/project:/path/to/project:ro",
             "-w", "/path/to/project", "--entrypoint", "writ-mcp",
             "ghcr.io/writ-lang/writ:0.3.0"] } } }
```

## Pin your questions

Put your `.claims` files in a directory the assistant does not edit, and point
the server at it:

- **Claude Code plugin**: set `WRIT_CLAIMS_DIR=/path/to/questions` in the
  environment you start Claude Code from.
- **Other clients**: add `"args": ["--claims-dir", "/path/to/questions"]`.

Every check then reads `<basename>.claims` from that directory, and says so:
`claims: /path/to/questions/river.claims   (pinned)`. The model is the
assistant's to change; the questions stay yours.

## Using it

Describe the system and the question in plain words, and say you want it
checked with writ. The assistant writes the model and claims, calls the tools,
and revises the model until your questions hold — or shows you why they cannot.
It needs no Writ documentation from you: the server teaches the language itself
(below).

| Tool | Arguments | Answers |
|---|---|---|
| `writ_guide` | `items` | the language, by topic: syntax, semantics, idioms, worked examples, every error code |
| `writ_validate` | `model`, `claims`, `rules` | parse and type-check only, instantly; what the sources declare, or coded errors |
| `writ_check` | `model`, `claims` | every property `holds` / `fails` with a route; laws, gaps, dead ends; what the edit **LOST**; `certified` |
| `writ_show` | `model`, `at` | what a situation is — the one a witness names by `#N` |
| `writ_compare` | `old_model`, `new_model`, `claims` | which guarantees an edit kept, lost and gained |
| `writ_query` | `model`, `claims`, `name`, `at` | a named query's matching rows |
| `writ_derive` | `model`, `rules`, `relation`, `why` | a relation from a `.rules` file, or its derivation tree |

Every file argument is a path **or** inline text: `model_source`,
`claims_source`, `rules_source` (and `old_model_source`, `new_model_source`),
at most 256 KB each, so an assistant in a chat app that cannot write to your
disk can still author. Give inline models a `model_name` to keep revision
history per name (for as long as the server runs); errors cite the source
as `inline:NAME.writ`, a name no `(load …)` can reach. An inline model's own
`(load …)` is looked up as a path model's is: the server's working directory
first, then the library path. Under
`--claims-dir`, inline claims are refused.

Every tool takes `json: true` for the same answer as one JSON object
([json.md](json.md)).

### How an assistant learns the language

- **`instructions`** on initialize: what writ is, the workflow
  (`writ_validate` → `writ_check` → `writ_show` → `writ_compare`), and that
  `n/a` is a failure. Some clients drop these, so nothing depends on them.
- **`writ_guide`**: topics `index`, `syntax.model`, `syntax.claims`,
  `syntax.rules`, `semantics`, `idioms`, five worked examples
  (`examples.mutex`, `.webhooks`, `.consumer`, `.commit`, `.handoff`, each
  with the failing check, the fix and the compare), and `errors.<code>`. The
  same topics are MCP resources, `writ://guide/<topic>`, and the prompt
  `writ_model_system` walks a description through the workflow. The topics
  live in `tooling/mcp/guide/` and are compiled into the server; a test re-runs
  every example and fails if its output drifts.
- **`writ_check`'s description** carries one complete model and claims, so a
  client sees working syntax before it calls anything.

### Errors and limits

A failed call answers with one block per file in error:

```
error E_UNKNOWN_VALUE in model at inline:shop.writ:8:60
  value runing not in codomain stage-t
  found:    runing
  expected: one of running, done, queued
  hint:     Write `running` for `runing`. Use a value of the arrow's codomain type.
  fix:      (transition go (when (is a.stage queued)) (do (set a.stage running)))
  see:      writ_guide errors.E_UNKNOWN_VALUE
```

With `json: true` the same fields come as objects. `fix` is the corrected line
when the mistake is a misspelt name. A misspelt name in claims, which `writ_check`
would answer `n/a`, is an error in `writ_validate`, and `writ_check` adds a
`why n/a` line naming it.

The search stops at `max_situations` (default 200 000, at most 2 000 000) or
`timeout_ms` of CPU time (default 60 000, at most 600 000). Then the answer is
`E_STATE_LIMIT`: how many situations were explored, the bound (the product of
every mutable cell's domain), each property marked undecided, and the cells
that took the most values, the ones to shrink.

Read a reply's last lines first. `NOT CERTIFIED` means writ itself got
something wrong — report it rather than work around it. A `LOST` guarantee or
an `n/a` property is a failure, even when everything else holds.

## When it does not work

- **"could not pull" / no Docker**: install Docker, or install writ and set
  `WRIT_MCP_NATIVE=1`.
- **A model "not found"** with the plugin: it is outside the directory Claude
  Code started in, which is all the container can see.
- **`not certified: writ-cert is not installed`**: a source-built writ without
  `writ-cert`; the answers stand but are not re-derived. The image and release
  tarballs include it.
