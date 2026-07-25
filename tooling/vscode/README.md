# Pol language support for VS Code

Editor support for **Pol** — *Partial Olog*, an abstract language for modelling
real-world domains — over `.pol` model/library files and `.claims` question
files. Syntax highlighting plus everything the language's own server provides:
diagnostics from the real parser, a document outline, hover, and completion.

The server is `tooling/lsp/bin/pol_lsp.ml` in this repository, compiled by `make build`.
The extension does not bundle it and does not download one: the point of an
OCaml server is that the editor and the checker are the *same code*, so the
extension talks to the binary your checkout produced.

## Install

From the repository root:

```
make extension
```

That is the whole thing. It builds the server, fetches the extension's
dependencies, links the extension into every VS Code extensions directory it
finds, and then **verifies the server actually answers a handshake** — so a
success message means it works, not merely that it compiled.

Then reload the window (<kbd>Ctrl+Shift+P</kbd> → *Developer: Reload Window*).
VS Code only scans its extensions directory at startup, which is the one step a
script cannot do for you.

Re-running is safe. To remove it:

```
./tooling/vscode/install.sh --uninstall
```

The install is a **symlink** into the extensions directory, so editing this repo
updates the extension with no reinstall — and moving or deleting the checkout
breaks it, which is the trade.

### Requirements

`npm` (for `vscode-languageclient`) and an OCaml toolchain. The toolchain is
found by `scripts/with-ocaml.sh`: `dune` on `PATH`, else `$SWITCH`, else a local
`./_opam`. If none is found the script says exactly what to run.

### Doing it by hand instead

```
make build                      # produces _build/default/tooling/lsp/bin/pol_lsp.exe
cd tooling/vscode && npm install
```

then either open `tooling/vscode/` in VS Code and press <kbd>F5</kbd> for an
Extension Development Host, or package it:

```
npx @vscode/vsce package
code --install-extension pol-0.1.0.vsix
```

## The setting

| Setting          | Default                             |
| ---------------- | ----------------------------------- |
| `pol.serverPath` | `_build/default/tooling/lsp/bin/pol_lsp.exe` |

The path to the `pol_lsp` executable to launch. A **relative** path is resolved
against each open workspace folder, which is why the default works with no
configuration when you have the repository open. An **absolute** path is used as
written, for a server built in another switch or installed elsewhere.

If nothing exists at the resolved path the extension says so, naming the paths
it tried and telling you to run `make build`, rather than starting a client
against a binary that is not there.

## What the editor gives you

- **Highlighting** — the grammar in `syntaxes/pol.tmLanguage.json` marks the
  twenty-eight kernel keywords (§8–§11 of the language spec), the guard and
  effect words, and the Part III question vocabulary (`property`, `never`,
  `possible`, `live`, `query`, `where`, `accept`, …) that `.claims` files use.
- **Diagnostics** — the server parses the buffer with the *engine's own* front
  end, so a squiggle is the compiler's verdict, at the exact `line:col`. A
  `.pol` file is checked as a model or a library by its content; a `.claims`
  file is checked against its sibling `MODEL.pol`.
- **Outline, hover, completion** — declarations become document symbols;
  hovering a keyword shows its reference card; completion offers the kernel and
  question vocabularies plus the form-heads of the libraries the file loads.

One honest limit: diagnostics surface **one error at a time** — the front end
stops at the first problem by construction. The wire already carries an array,
so widening this later changes nothing a client sees.
