#!/bin/sh
# install.sh — install `pol` from a portable release tarball.
#
# This script ships INSIDE the tarball built by `make release` (as ./install.sh)
# and is meant to be run from the unpacked directory:
#
#     tar xzf pol-<version>-<os>-<arch>.tar.gz
#     cd pol-<version>-<os>-<arch>
#     ./install.sh                 # -> ~/.local
#     ./install.sh /usr/local      # -> a prefix you name (may need sudo)
#
# No opam, no OCaml, no npm on the target machine: the tarball carries a
# prebuilt binary. It does need the same OS/architecture and a compatible libc
# as the machine that built it — see the note printed at the end.
#
# Uninstall is the inverse and equally plain:
#     rm -f  <prefix>/bin/pol <prefix>/bin/pol-lsp <prefix>/bin/pol-mcp
#     rm -rf <prefix>/share/pol
set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix=${1:-${PREFIX:-$HOME/.local}}

[ -x "$here/bin/pol" ] || {
  echo "install.sh: no bin/pol beside this script — is the tarball unpacked?" >&2
  exit 1
}

# The library directory is REPLACED, not merged into: a file dropped from the
# standard library must disappear on upgrade, or an old copy lingers on the
# search path and keeps resolving after it has been removed.
rm -rf "$prefix/share/pol/lib"
mkdir -p "$prefix/bin" "$prefix/share/pol/lib"

# rm first: an already-installed pol is read-only (mode 555), so a plain cp over
# it fails with EACCES.
for exe in pol pol-lsp pol-mcp; do
  [ -f "$here/bin/$exe" ] || continue
  rm -f "$prefix/bin/$exe"
  cp "$here/bin/$exe" "$prefix/bin/$exe"
  chmod 755 "$prefix/bin/$exe"
done

# The .pol standard library goes where the resolver looks: <bin>/../share/pol/lib.
# That is what lets `(load "stdlib.pol")` work from any directory, unset $POL_LIB.
cp "$here/share/pol/lib/"*.pol "$prefix/share/pol/lib/"

echo "installed:"
echo "  $prefix/bin/pol"
[ -f "$prefix/bin/pol-lsp" ] && echo "  $prefix/bin/pol-lsp  (language server)"
[ -f "$prefix/bin/pol-mcp" ] && echo "  $prefix/bin/pol-mcp  (MCP server)"
echo "  $prefix/share/pol/lib/*.pol"

case ":${PATH:-}:" in
*":$prefix/bin:"*) ;;
*) echo; echo "note: $prefix/bin is not on your PATH — add it to run \`pol\`." ;;
esac

echo
echo "try:  pol --help"
