#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# install.sh — install `writ` from a portable release tarball.
#
# This script ships INSIDE the tarball built by `make release` (as ./install.sh)
# and is meant to be run from the unpacked directory:
#
#     tar xzf writ-<version>-<os>-<arch>.tar.gz
#     cd writ-<version>-<os>-<arch>
#     ./install.sh                 # -> ~/.local
#     ./install.sh /usr/local      # -> a prefix you name (may need sudo)
#
# No opam, no OCaml, no npm on the target machine: the tarball carries a
# prebuilt binary. It does need the same OS/architecture and a compatible libc
# as the machine that built it — see the note printed at the end.
#
# Uninstall is the inverse and equally plain:
#     rm -f  <prefix>/bin/writ <prefix>/bin/writ-lsp <prefix>/bin/writ-mcp
#     rm -rf <prefix>/share/writ
set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix=${1:-${PREFIX:-$HOME/.local}}

[ -x "$here/bin/writ" ] || {
  echo "install.sh: no bin/writ beside this script — is the tarball unpacked?" >&2
  exit 1
}

# The library directory is REPLACED, not merged into: a file dropped from the
# standard library must disappear on upgrade, or an old copy lingers on the
# search path and keeps resolving after it has been removed.
rm -rf "$prefix/share/writ/lib"
mkdir -p "$prefix/bin" "$prefix/share/writ/lib"

# rm first: an already-installed writ is read-only (mode 555), so a plain cp over
# it fails with EACCES.
for exe in writ writ-lsp writ-mcp; do
  [ -f "$here/bin/$exe" ] || continue
  rm -f "$prefix/bin/$exe"
  cp "$here/bin/$exe" "$prefix/bin/$exe"
  chmod 755 "$prefix/bin/$exe"
done

# The standard library goes where the resolver looks: <bin>/../share/writ/lib.
# That is what lets `(load "stdlib.writ")` work from any directory, unset $WRIT_LIB.
# Copied whole rather than by extension: `ct.rules` is a library too, and the
# resolver matches a load on the NAME, never on the suffix.
cp "$here/share/writ/lib/"* "$prefix/share/writ/lib/"

echo "installed:"
echo "  $prefix/bin/writ"
[ -f "$prefix/bin/writ-lsp" ] && echo "  $prefix/bin/writ-lsp  (language server)"
[ -f "$prefix/bin/writ-mcp" ] && echo "  $prefix/bin/writ-mcp  (MCP server)"
echo "  $prefix/share/writ/lib/"

case ":${PATH:-}:" in
*":$prefix/bin:"*) ;;
*) echo; echo "note: $prefix/bin is not on your PATH — add it to run \`writ\`." ;;
esac

echo
echo "try:  writ --help"
