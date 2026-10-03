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

| Tool | Arguments | Answers |
|---|---|---|
| `writ_check` | `model`, `claims` | every property `holds` / `fails` with a route; laws, gaps, dead ends; what the edit **LOST**; `certified` |
| `writ_show` | `model`, `at` | what a situation is — the one a witness names by `#N` |
| `writ_compare` | `old_model`, `new_model` | which guarantees an edit kept, lost and gained |
| `writ_query` | `model`, `name`, `at` | a named query's matching rows |
| `writ_derive` | `model`, `rules`, `relation`, `why` | a relation from a `.rules` file, or its derivation tree |

Every tool takes `json: true` for the same answer as one JSON object
([json.md](json.md)).

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
