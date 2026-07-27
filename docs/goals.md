## List of project goals:


- **[in progress]** create VS code extension to work with pol individual repo,
  with description and instructions

  The extension no longer needs a checkout: it looks for a built server in each
  workspace folder and then for `pol-lsp` on `PATH`, which is what
  `opam install pol` provides. Description and instructions cover both routes,
  and all three file types. What is left is the separate repository itself,
  which waits on the split below.

- move pol core and stdlib into yet another repo  (pol the cli tool goes here)

- move repo with examples into yet another repo

  Verified separable: the whole example suite (80 checks) runs from a directory
  outside this repo against an installed `pol`, with no checkout and no
  `POL_LIB`. What remains is a git operation and a Dockerfile, not a code
  change.

- **[done]** create custom skill (for claude) using pol available as mcp server

  `pol-mcp` is an MCP server over the same engine the CLI uses — `pol_check`,
  `pol_query`, `pol_derive` — installed alongside `pol`. The skill is
  `.claude/skills/pol/`, and `.mcp.json` wires the server up for this repo.

### Before the two repo splits

Both are blocked on decisions rather than work: repository names, owner and
visibility; whether to preserve history (a subtree split) or start fresh; and
what the examples repo uses to get a `pol` binary — a release tarball, opam, or
a published image. The engine side is already an opam package with
`make install-pol` and `make release`.

They should also wait for the open pull request to merge. Splitting a
repository from a feature branch strands whatever has not landed.
