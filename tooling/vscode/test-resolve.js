// Where the client looks for the language server, and in what order.
//
// This is the whole of "the extension works with pol installed separately".
// Until it was written, the only candidate was a path under `_build`, which
// exists ONLY inside a checkout — so on a machine that had run `opam install
// pol` the extension found nothing, even though tooling/lsp/bin/dune installs
// `pol-lsp` precisely so that case works.
//
// The order matters as much as the set: a checkout's own build must win, because
// an OCaml server exists so the editor and the checker are the same code, and
// someone changing the language wants the build in front of them.
//
// Run: node tooling/vscode/test-resolve.js

const Module = require("module");
const path = require("path");

let workspace = [];
const origLoad = Module._load;
Module._load = function (req) {
  if (req === "vscode")
    return {
      workspace: {
        get workspaceFolders() {
          return workspace;
        },
        getConfiguration: () => ({ get: (_k, d) => d }),
      },
      window: { showErrorMessage: () => {} },
    };
  if (req === "vscode-languageclient/node")
    return { LanguageClient: class {}, TransportKind: { stdio: 0 } };
  return origLoad.apply(this, arguments);
};

const { candidates, onPath, INSTALLED } = require(
  path.join(__dirname, "extension.js")
).__test;

let failed = 0;
function check(name, cond) {
  if (!cond) {
    console.log(`FAIL: ${name}`);
    failed++;
  }
}

const DEFAULT = "_build/default/tooling/lsp/bin/pol_lsp.exe";
const folder = (p) => ({ uri: { fsPath: p } });

// 1. In a checkout: the build comes first, the installed server after it.
workspace = [folder("/w/pol")];
let c = candidates(DEFAULT);
check("a checkout's own build is tried first", c[0] === path.join("/w/pol", DEFAULT));
check("and the installed pol-lsp is still a fallback", c.some((p) => p.endsWith(path.sep + INSTALLED)));
check(
  "the build is tried BEFORE anything on PATH",
  c.indexOf(path.join("/w/pol", DEFAULT)) <
    c.findIndex((p) => p.endsWith(path.sep + INSTALLED))
);

// 2. No workspace at all — a lone .pol file, or pol installed without a
//    checkout. This is the case that used to yield an empty list.
workspace = [];
c = candidates(DEFAULT);
check("with no workspace there is still somewhere to look", c.length > 0);
check(
  "and it is pol-lsp on PATH",
  c.every((p) => p.endsWith(path.sep + INSTALLED))
);

// 3. An absolute setting is taken literally: an operator naming a server means
//    that server, and nothing is guessed after it.
workspace = [folder("/w/pol")];
c = candidates("/opt/pol/bin/pol-lsp");
check("an absolute setting is the only candidate", c.length === 1);
check("and it is exactly what was set", c[0] === "/opt/pol/bin/pol-lsp");

// 4. The PATH search uses the INSTALLED name, not the in-checkout file name.
//    `opam install pol` produces `pol-lsp`; `_build` produces `pol_lsp.exe`.
check("the installed name is pol-lsp", INSTALLED === "pol-lsp");
check(
  "every PATH candidate ends in it",
  onPath(INSTALLED).every((p) => path.basename(p).startsWith(INSTALLED))
);
check("PATH is actually searched", onPath(INSTALLED).length > 0);

const n = 10 - failed;
console.log(
  failed === 0
    ? `extension resolve tests: ${n} checks passed`
    : `extension resolve tests: ${failed} FAILED`
);
process.exit(failed === 0 ? 0 : 1);
