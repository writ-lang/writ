## List of project goals — all four done

- **[done]** create VS code extension to work with pol individual repo, with
  description and instructions

  [pol-vscode](https://github.com/sajonaro/pol-vscode). It no longer needs a
  checkout: the client looks in each workspace folder and then for `pol-lsp` on
  `PATH`, which `opam install pol` and `make install-pol` both provide. Its
  installer decides the same way — building from source only when it finds an
  engine beside it. Description and instructions cover both routes and all
  three file types.

- **[done]** move pol core and stdlib into yet another repo (pol the cli tool
  goes here)

  This repository. What is left in it is the language, the engine, the CLI and
  the two servers, plus the standard library and the unit tests. The Dockerfile
  stayed and became a pure engine image; `docker-compose.yml`, `make examples`
  and `make extension` went, because each would now reach into another repo.

- **[done]** move repo with examples into yet another repo

  [pol-problems](https://github.com/sajonaro/pol-problems), split with history.
  Verified the way a reader would: `make install-pol` into a clean prefix, then
  a fresh clone run against only that prefix — 80 checks passed.

- **[done]** create custom skill (for claude) using pol available as mcp server

  `pol-mcp` over the same engine as the CLI — `pol_check`, `pol_query`,
  `pol_derive` — installed alongside `pol`. The skill is `.claude/skills/pol/`,
  and `.mcp.json` wires the server up for this repo.

### The one thing deferred

pol-problems has **no Docker**, and its README says so rather than shipping
instructions that fail. The image those scenarios ran in compiled `pol` from
source in the same tree; from a separate repository it needs a published `pol`
to install instead.

That wants a decision rather than more work: publish the engine image to a
registry (`ghcr.io/sajonaro/pol`) and have pol-problems build `FROM` it, or
attach the release tarball to a GitHub release and fetch it at build time.
Pushing to ghcr needs a token with `write:packages`, which the one here does
not carry.
