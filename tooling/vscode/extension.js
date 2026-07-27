// The VS Code client. It does one thing: find the server this repository built
// and hand it to vscode-languageclient over stdio.
//
// There is no compile step and no TypeScript here on purpose. Every LSP request
// the editor answers is answered by the OCaml server, so a build pipeline would
// exist to typecheck sixty lines of glue.

const fs = require("fs");
const path = require("path");
const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

const SETTING = "pol.serverPath";
const POLL_MS = 2000;

let client;
let watcher;

// Restart the server when its binary is replaced.
//
// WHY THIS EXISTS. `make build` writes a NEW inode over the server, and the
// process already running keeps the old one — `/proc/PID/exe` reads
// "(deleted)". Nothing surfaces that. The editor keeps answering, confidently,
// with a language that is one build out of date, and the symptom is a squiggle
// on code the CLI accepts. That has cost real debugging time more than once,
// and it is worst exactly when the language itself is being changed, because
// then the stale answer is *plausible*.
//
// Polling rather than [createFileSystemWatcher]: the default server path is
// under `_build`, which is routinely listed in `files.watcherExclude`, and a
// watcher that silently never fires would be a worse version of this same bug.
// One stat every two seconds is not a cost worth optimising.
function watchServerBinary(serverPath, log, pollMs = POLL_MS) {
  let known = stampOf(serverPath);
  let pending = null;

  const id = setInterval(async () => {
    const now = stampOf(serverPath);
    if (now === null) return; // mid-build: the file is briefly gone
    if (now === known) {
      pending = null; // nothing new, or a change that reverted
      return;
    }
    if (pending !== now) {
      // Seen a change, but act only once it has stopped moving, so a
      // multi-second link step restarts the server once and not four times.
      pending = now;
      return;
    }
    known = now;
    pending = null;
    log(`server binary changed on disk — restarting (${serverPath})`);
    try {
      await client.restart();
      log("server restarted; diagnostics are from the current build");
    } catch (e) {
      vscode.window.showErrorMessage(
        `Pol: the language server changed on disk but would not restart: ${e}. ` +
          "Reload the window to pick it up."
      );
    }
  }, pollMs);

  return { dispose: () => clearInterval(id) };
}

// Identity of the file as built, not merely its name: dune replaces the
// executable, so the inode changes even when a rebuild lands within the same
// mtime granularity.
function stampOf(p) {
  try {
    const s = fs.statSync(p);
    return `${s.ino}:${s.mtimeMs}:${s.size}`;
  } catch {
    return null;
  }
}

// The name `opam install pol` puts on PATH (tooling/lsp/bin/dune's
// public_name). NOT the same as the in-checkout file name, which is
// `pol_lsp.exe` under _build.
const INSTALLED = "pol-lsp";

function onPath(exe) {
  const dirs = (process.env.PATH || "").split(path.delimiter).filter(Boolean);
  const names = process.platform === "win32" ? [exe + ".exe", exe] : [exe];
  return dirs.flatMap((d) => names.map((n) => path.join(d, n)));
}

// Where to look for the server, in order. Returns every path tried, so a
// failure can name them rather than say "not found".
//
// TWO AUDIENCES, and the order is which one gets served first. A CHECKOUT of
// this repository builds its own server, and that one must win — the whole
// point of an OCaml server is that the editor and the checker are the same
// code, so a developer changing the language wants the build in front of them
// and not whatever is installed. Everyone ELSE has run `opam install pol` (or
// unpacked a release) and has no checkout at all; for them the relative default
// resolves to nothing, and `pol-lsp` on PATH is the only server there is.
//
// Serving only the first audience is what this did until now, which meant the
// extension could not be used with pol installed separately — the case
// tooling/lsp/bin/dune installs `pol-lsp` for in the first place.
//
// An ABSOLUTE setting is taken literally and nothing is guessed after it: an
// operator who names a server means that server.
function candidates(configured) {
  if (path.isAbsolute(configured)) return [configured];
  const folders = vscode.workspace.workspaceFolders || [];
  const inWorkspace = folders.map((f) => path.join(f.uri.fsPath, configured));
  return [...inWorkspace, ...onPath(INSTALLED)];
}

function activate(context) {
  const configured = vscode.workspace
    .getConfiguration()
    .get(SETTING, "_build/default/tooling/lsp/bin/pol_lsp.exe");
  const tried = candidates(configured);
  const found = tried.find((p) => fs.existsSync(p));

  if (!found) {
    // Silence here would look like a server that starts and answers nothing,
    // which is the same symptom as a broken server and much harder to chase.
    //
    // The PATH candidates are summarised rather than listed: naming forty
    // directories buries the one thing worth reading, which is that `pol-lsp`
    // was not in any of them.
    const inWorkspace = tried.filter((p) => !onPath(INSTALLED).includes(p));
    const where = inWorkspace.length
      ? `not at ${inWorkspace.join(", ")}, and \`${INSTALLED}\` is not on PATH`
      : `\`${INSTALLED}\` is not on PATH`;
    vscode.window.showErrorMessage(
      `Pol: no language server — ${where}. ` +
        "In a checkout of the pol repository, run `make build`. Otherwise " +
        "install pol (`opam install pol`, or a release tarball) so " +
        `\`${INSTALLED}\` is on PATH — or set \`${SETTING}\` to an absolute ` +
        "path to the server you want."
    );
    return;
  }

  const serverOptions = {
    command: found,
    args: [],
    transport: TransportKind.stdio,
  };

  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "pol" }],
    outputChannelName: "Pol Language Server",
  };

  client = new LanguageClient(
    "pol",
    "Pol Language Server",
    serverOptions,
    clientOptions
  );

  context.subscriptions.push(client);
  const started = client.start();

  const log = (m) => client.outputChannel.appendLine(`[client] ${m}`);
  log(`server: ${found}`);
  watcher = watchServerBinary(found, log);
  context.subscriptions.push(watcher);

  return started;
}

function deactivate() {
  if (watcher) watcher.dispose();
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };

// Exposed for tooling/vscode/test-watcher.js, which drives the watcher against a
// real file on disk. The watcher is the one part of this glue with behaviour of
// its own, and a watcher that silently never fires is the bug it exists to fix.
module.exports.__test = {
  watchServerBinary,
  stampOf,
  candidates,
  onPath,
  INSTALLED,
  setClient: (c) => {
    client = c;
  },
};
