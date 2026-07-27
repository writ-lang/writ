// Drives extension.js's server-binary watcher against a real file on disk.
//
// The watcher is the only part of the client with behaviour of its own, and its
// failure mode is SILENCE — it either fires or it does not, and a watcher that
// never fires looks exactly like a server that is simply up to date. That is
// the bug it exists to fix, so it does not get to go untested. The first
// version of it never fired at all; this file is what caught that.
//
// `vscode` and `vscode-languageclient` do not exist outside the editor, so both
// are stubbed at the module loader. Nothing here needs the real ones: the
// watcher only stats a path and calls `client.restart()`.
//
// Run: node tooling/vscode/test-watcher.js

const Module = require("module");
const fs = require("fs");
const path = require("path");
const os = require("os");

const errors = [];
const origLoad = Module._load;
Module._load = function (req) {
  if (req === "vscode")
    return {
      workspace: {
        workspaceFolders: [],
        getConfiguration: () => ({ get: (_k, d) => d }),
      },
      window: { showErrorMessage: (m) => errors.push(m) },
    };
  if (req === "vscode-languageclient/node")
    return { LanguageClient: class {}, TransportKind: { stdio: 0 } };
  return origLoad.apply(this, arguments);
};

const ext = require(path.join(__dirname, "extension.js"));

const POLL = 40; // fast enough to gate; the shipped default is 2000
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failed = 0;
function check(name, cond) {
  if (!cond) {
    console.log(`FAIL: ${name}`);
    failed++;
  }
}

(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pol-watch-"));
  const bin = path.join(dir, "pol_lsp.exe");
  fs.writeFileSync(bin, "v1");

  let restarts = 0;
  const logs = [];
  ext.__test.setClient({
    restart: async () => {
      restarts++;
    },
  });
  const w = ext.__test.watchServerBinary(bin, (m) => logs.push(m), POLL);

  await sleep(POLL * 6);
  check("an unchanged binary does not restart the server", restarts === 0);

  // Replaced, not edited in place — which is what dune does, and why the stamp
  // carries the inode and not just the mtime.
  fs.rmSync(bin);
  fs.writeFileSync(bin, "v2-different-length");
  await sleep(POLL * 8);
  check("a replaced binary restarts the server", restarts === 1);
  check("and says so in the output channel", logs.length === 2);

  await sleep(POLL * 6);
  check("a settled binary restarts it once, not repeatedly", restarts === 1);

  // A vanished file is a build in progress, not a reason to do anything.
  fs.rmSync(bin);
  await sleep(POLL * 6);
  check("a missing binary is not a restart", restarts === 1);
  check("nothing was reported to the user", errors.length === 0);

  w.dispose();
  const n = 6 - failed;
  console.log(
    failed === 0
      ? `extension watcher tests: ${n} checks passed`
      : `extension watcher tests: ${failed} FAILED`
  );
  process.exit(failed === 0 ? 0 : 1);
})();
