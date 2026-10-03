#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# install.sh — install `writ` from a portable release tarball.
#
# Ships inside the `make release` tarball; run it from the unpacked directory:
#
#     tar xzf writ-<version>-<os>-<arch>.tar.gz
#     cd writ-<version>-<os>-<arch>
#     ./install.sh                 # -> ~/.local
#     ./install.sh /usr/local      # -> a prefix you name (may need sudo)
#
# To uninstall:
#     rm -f  <prefix>/bin/writ <prefix>/bin/writ-lsp <prefix>/bin/writ-mcp <prefix>/bin/writ-cert
#     rm -rf <prefix>/share/writ
set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix=${1:-${PREFIX:-$HOME/.local}}

[ -x "$here/bin/writ" ] || {
  echo "install.sh: no bin/writ beside this script — is the tarball unpacked?" >&2
  exit 1
}

# Replace the library directory, not merge into it, so a removed file does not
# linger on the search path.
rm -rf "$prefix/share/writ/lib"
mkdir -p "$prefix/bin" "$prefix/share/writ/lib"

# rm first: an installed binary may be read-only, so cp over it fails.
# writ-cert goes beside writ, where `writ check` looks for it first.
for exe in writ writ-lsp writ-mcp writ-cert; do
  [ -f "$here/bin/$exe" ] || continue
  rm -f "$prefix/bin/$exe"
  cp "$here/bin/$exe" "$prefix/bin/$exe"
  chmod 755 "$prefix/bin/$exe"
done

# Copied whole, not by extension: ct.rules is a library too.
cp "$here/share/writ/lib/"* "$prefix/share/writ/lib/"

echo "installed:"
echo "  $prefix/bin/writ"
[ -f "$prefix/bin/writ-lsp" ] && echo "  $prefix/bin/writ-lsp  (language server)"
[ -f "$prefix/bin/writ-mcp" ] && echo "  $prefix/bin/writ-mcp  (MCP server)"
[ -f "$prefix/bin/writ-cert" ] && echo "  $prefix/bin/writ-cert  (certificate checker — every \`writ check\` runs it)"
echo "  $prefix/share/writ/lib/"

case ":${PATH:-}:" in
*":$prefix/bin:"*) ;;
*) echo; echo "note: $prefix/bin is not on your PATH — add it to run \`writ\`." ;;
esac

echo
echo "try:  writ --help"
