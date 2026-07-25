#!/usr/bin/env bash
# Install the .pol language support into VS Code.
#
#   ./tooling/vscode/install.sh              # build, install, verify
#   ./tooling/vscode/install.sh --uninstall  # remove it again
#
# Safe to re-run. Installs as a symlink into every VS Code extensions directory
# it finds, so editing this repo updates the extension with no reinstall.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
ext_id="pol.pol-0.1.0"
server="$repo/_build/default/tooling/lsp/bin/pol_lsp.exe"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Every VS Code flavour keeps extensions somewhere different, and a Remote/WSL
# window reads .vscode-server rather than .vscode. Install into all that exist
# so the script does not have to guess which window you will open.
find_extension_dirs() {
  local found=()
  for d in "$HOME/.vscode/extensions" \
           "$HOME/.vscode-server/extensions" \
           "$HOME/.vscode-insiders/extensions" \
           "$HOME/.vscode-server-insiders/extensions" \
           "$HOME/.cursor/extensions" \
           "$HOME/.vscodium/extensions"; do
    [ -d "$d" ] && found+=("$d")
  done
  printf '%s\n' "${found[@]:-}"
}

mapfile -t ext_dirs < <(find_extension_dirs)
[ -n "${ext_dirs[0]:-}" ] || die "no VS Code extensions directory found.
Open this folder in VS Code once (which creates it), then re-run this script."

# ---------------------------------------------------------------- uninstall --
if [ "${1:-}" = "--uninstall" ]; then
  for d in "${ext_dirs[@]}"; do
    if [ -e "$d/$ext_id" ] || [ -L "$d/$ext_id" ]; then
      rm -rf "$d/$ext_id"
      say "removed $d/$ext_id"
    fi
  done
  say "done — reload your VS Code window to finish."
  exit 0
fi

# -------------------------------------------------------------------- build --
say "building the language server"
"$repo/scripts/with-ocaml.sh" dune build --root "$repo" 2>&1 | sed 's/^/    /' || \
  die "the build failed — fix that first, the extension is useless without the server."
[ -x "$server" ] || die "build reported success but $server is missing."

# ------------------------------------------------------------ dependencies --
command -v npm >/dev/null 2>&1 || die "npm is required to install the extension's
dependencies (vscode-languageclient). Install Node.js, then re-run."

say "installing extension dependencies"
if [ -f "$here/package-lock.json" ]; then
  (cd "$here" && npm ci --no-audit --no-fund 2>&1 | sed 's/^/    /')
else
  (cd "$here" && npm install --no-audit --no-fund 2>&1 | sed 's/^/    /')
fi

# ------------------------------------------------------------------ install --
for d in "${ext_dirs[@]}"; do
  rm -rf "$d/$ext_id"
  ln -s "$here" "$d/$ext_id"
  say "linked into $d"
done

# ------------------------------------------------------------------- verify --
# Prove the server actually answers, rather than trusting that it built. A
# handshake here is the difference between "installed" and "works".
say "verifying the server responds"
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
exit_msg='{"jsonrpc":"2.0","method":"exit"}'
reply=$(printf 'Content-Length: %d\r\n\r\n%sContent-Length: %d\r\n\r\n%s' \
          "${#init}" "$init" "${#exit_msg}" "$exit_msg" \
        | "$server" 2>/dev/null | tr -d '\r' || true)

case "$reply" in
  *documentSymbolProvider*completionProvider*|*completionProvider*documentSymbolProvider*)
    say "server answered with its capabilities" ;;
  *)
    warn "the server did not answer a handshake as expected. The extension is
    installed, but check: $server" ;;
esac

cat <<EOF

$(say "installed")

  Last step, which this script cannot do for you:
    Reload the window — Ctrl+Shift+P → "Developer: Reload Window"
    VS Code only scans its extensions directory at startup.

  Then open any tests/models/*.pol file. To confirm the server is live, change a
  value to something outside its declared domain and watch it get underlined.

  If nothing happens, check View → Output → "Pol Language Server".
  If your workspace root is not this repo, set "pol.serverPath" to:
    $server

  Uninstall with: $0 --uninstall
EOF
