#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# check-versions.sh — every copy of the version must be the same copy.
#
#     sh scripts/check-versions.sh
#
# The version is `(version …)` in dune-project. These files cannot read it and
# keep a hand-written copy, which this checks on every pull request:
#
#   writ.opam                              generated but committed
#   plugins/writ/.claude-plugin/plugin.json  what Claude Code shows as installed
#   plugins/writ/bin/writ-mcp              the image tag the plugin pulls; a
#                                          stale one fails silently
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

want=$(sed -n 's/^(version \(.*\))/\1/p' dune-project)
[ -n "$want" ] || {
  echo "check-versions: dune-project has no (version …) line" >&2
  exit 2
}

fail=0

# check <file> <what it is> <extracted value> [how to fix it]
check() {
  file=$1 what=$2 got=$3 fix=${4:-}
  if [ -z "$got" ]; then
    printf '  %s: no version found — has %s changed shape?\n' "$file" "$what" >&2
    fail=1
  elif [ "$got" != "$want" ]; then
    printf '  %s: says %s, dune-project says %s\n' "$file" "$got" "$want" >&2
    [ -n "$fix" ] && printf '    %s\n' "$fix" >&2
    fail=1
  fi
}

check writ.opam \
  "the generated opam file" \
  "$(sed -n 's/^version: "\(.*\)"/\1/p' writ.opam)" \
  "generated from dune-project — run \`make build\` and commit it"

check plugins/writ/.claude-plugin/plugin.json \
  "the Claude plugin manifest" \
  "$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
       plugins/writ/.claude-plugin/plugin.json)" \
  "edit the \"version\" field by hand"

check plugins/writ/bin/writ-mcp \
  "the pinned image tag" \
  "$(sed -n 's|.*ghcr\.io/writ-lang/writ:\([0-9][^}"[:space:]]*\).*|\1|p' \
       plugins/writ/bin/writ-mcp | head -n 1)" \
  "edit WRIT_IMAGE — the plugin would keep pulling the older image"

if [ "$fail" != 0 ]; then
  printf '\n  The version is (version %s) in dune-project. These files hold a copy\n' "$want" >&2
  printf '  because nothing substitutes into them; bump them in the same commit.\n' >&2
  exit 1
fi

printf '  version %s, and every copy of it agrees\n' "$want"
