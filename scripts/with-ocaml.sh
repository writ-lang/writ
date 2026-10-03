#!/usr/bin/env bash
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# Run a command with an OCaml toolchain on PATH.
#
#   scripts/with-ocaml.sh dune build
#
# The first of these that yields a working `dune` wins:
#   1. dune already on PATH
#   2. $SWITCH
#   3. ./_opam                       — a switch local to this checkout
#   4. the global `writ` switch
#   5. ../tryocaml, and the absolute path to it
set -euo pipefail

if ! command -v dune >/dev/null 2>&1; then
  for switch in "${SWITCH:-}" ./_opam writ ../tryocaml /root/docs/projects/tryocaml; do
    # A path switch must exist; a named one is left to `opam env` to reject.
    [ -n "$switch" ] || continue
    case "$switch" in */*|.*) [ -d "$switch" ] || continue ;; esac
    eval "$(opam env --switch="$switch" --set-switch 2>/dev/null)" || continue
    command -v dune >/dev/null 2>&1 && break
  done
fi

if ! command -v dune >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: no OCaml toolchain found — this project needs `dune`.

Either put dune on your PATH, or create a switch in this checkout:

    opam switch create . --deps-only    # or: opam switch create . 5.2.0
    opam install dune ocamlformat

If you already have a switch elsewhere, point at it:

    SWITCH=/path/to/switch make build
EOF
  exit 1
fi

exec "$@"
