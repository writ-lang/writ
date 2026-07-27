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

// A relative setting is resolved against the open workspace folders, so the
// default `_build/default/tooling/lsp/bin/pol_lsp.exe` finds the server in a checkout of
// this repository without anyone editing a setting. Returns every path tried,
// so a failure can name them rather than say "not found".
function candidates(configured) {
  if (path.isAbsolute(configured)) return [configured];
  const folders = vscode.workspace.workspaceFolders || [];
  return folders.map((f) => path.join(f.uri.fsPath, configured));
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
    vscode.window.showErrorMessage(
      `Pol: no language server at ${tried.join(", ") || configured}. ` +
        "Run `make build` in the repository root to build it, or set " +
        `\`${SETTING}\` to the pol_lsp executable you want to use.`
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
  setClient: (c) => {
    client = c;
  },
};
