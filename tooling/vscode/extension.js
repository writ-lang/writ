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

let client;

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
  return client.start();
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
