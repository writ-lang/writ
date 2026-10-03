#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run the downstream suites against the `writ` on PATH. Each repository owns its
# runner and assertions; this only knows where each checkout sits.
#
#   run.sh list        the suites, one per line
#   run.sh NAME        one suite
#   run.sh all         every suite; exits 0 only if every one passed (default)
set -u

root=${DOWNSTREAM:-/downstream}
WRIT=${WRIT:-writ}
export WRIT

problems()   { (cd "$root/writ-problems" && ./run-tests.sh all); }
# `writ check` against `writ derive`; not part of run-tests.sh's `all`.
crosscheck() { (cd "$root/writ-problems" && ./modality-cross-check.sh); }
arch()       { (cd "$root/writ-arch" && ./run-tests.sh all); }
scheduling() { (cd "$root/writ-scheduling-verification" && ./run.sh all); }
# End-to-end only (the unit suite runs in the OCaml stage). Exit 77, "writ not
# found", is a failure here.
mgtt2writ()  { (cd "$root/mgtt2writ" && MGTT2WRIT=mgtt2writ sh test/pipeline.sh); }

# WRIT_E2E_REQUIRED makes a missing writ-lsp a failure, not a skip. An old ref
# without the test files is skipped, since that is not writ's breakage.
vscode() {
  (cd "$root/writ-vscode" || exit 1
   if [ ! -f scripts/test.sh ]; then
     echo "  [skip] writ-vscode has no scripts/test.sh at this ref: nothing to run"
     exit 0
   fi
   [ -f test/engine.test.js ] \
     || echo "  [note] no test/engine.test.js at this ref: the engine is not exercised"
   WRIT_E2E_REQUIRED=1 sh scripts/test.sh)
}

suites="problems crosscheck arch scheduling mgtt2writ vscode"

run_one() {
  printf '\n######## %s ########\n' "$1"
  "$1"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '######## %s: PASS\n' "$1"
  else
    printf '######## %s: FAIL (exit %s)\n' "$1" "$rc"
  fi
  return "$rc"
}

sel=${1:-all}
case "$sel" in
list) printf '%s\n' $suites ;;
all)
  "$WRIT" --version
  failed=""
  for s in $suites; do run_one "$s" || failed="$failed $s"; done
  echo
  if [ -z "$failed" ]; then
    echo "downstream: every suite passed against $("$WRIT" --version | head -n 1)"
  else
    echo "downstream: FAILED:$failed" >&2
    exit 1
  fi
  ;;
*)
  case " $suites " in
  *" $sel "*) run_one "$sel" ;;
  *) echo "unknown suite: $sel (try: run.sh list)" >&2; exit 2 ;;
  esac
  ;;
esac
