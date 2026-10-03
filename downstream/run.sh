#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run the downstream suites against the `writ` on PATH.
#
# Each repository below keeps its own runner and its own assertions. This
# script owns none of them: it only knows where each checkout sits in the image
# and which command is that repository's "all". An assertion that changes
# upstream changes here by itself, because nothing is copied.
#
#   run.sh list        the suites, one per line
#   run.sh NAME        one suite
#   run.sh all         every suite; exits 0 only if every one passed (default)
#
# The same script is a RUN in each check-* stage of downstream/Dockerfile and
# the ENTRYPOINT of the final image, so a build and a `docker run` ask the same
# question.
set -u

root=${DOWNSTREAM:-/downstream}
WRIT=${WRIT:-writ}
export WRIT

problems()   { (cd "$root/writ-problems" && ./run-tests.sh all); }
# The two-implementation oracle: `writ check` against `writ derive` over every
# scenario's properties. It is not part of run-tests.sh's `all`.
crosscheck() { (cd "$root/writ-problems" && ./modality-cross-check.sh); }
arch()       { (cd "$root/writ-arch" && ./run-tests.sh all); }
scheduling() { (cd "$root/writ-scheduling-verification" && ./run.sh all); }
# mgtt2writ's unit suite runs where it is compiled (the OCaml stage). What
# runs here is the end-to-end check: its output read back by the real writ.
# Exit 77 means "skipped, writ not found", which in this image is a failure.
mgtt2writ()  { (cd "$root/mgtt2writ" && MGTT2WRIT=mgtt2writ sh test/pipeline.sh); }

# The editor client: its own suites, and test/engine.test.js, which drives the
# real writ-lsp and the `writ` command lines the extension builds. Required
# here, so a missing server is a failure rather than that test's polite skip.
# A ref from before that test existed still runs the rest, and says so.
vscode() {
  (cd "$root/writ-vscode" || exit 1
   [ -f test/engine.test.js ] \
     || echo "  [note] no test/engine.test.js at this ref: the engine is not exercised"
   WRIT_E2E_REQUIRED=1 scripts/test.sh)
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
