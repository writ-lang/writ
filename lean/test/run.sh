#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# The checker's suite (`make test`): proofs build, fixtures certify clean, and
# every tampered certificate is refused (exit 1).
set -eu
lake build
cert=./.lake/build/bin/writ-cert
work=$(mktemp -d)
pass=0

for m in test/*.writ; do
  c="${m%.writ}.claims"
  set -- "$m"; [ -f "$c" ] && set -- "$m" --claims "$c"
  st=0; writ check "$@" --certificate "$work/cert.json" > /dev/null || st=$?
  [ "$st" -le 1 ] || { echo "FAIL: writ check $m exited $st"; exit 1; }
  "$cert" "$work/cert.json" > "$work/out" || { cat "$work/out"; echo "FAIL: $m"; exit 1; }
  pass=$((pass + 1))
done

for f in Examples/*.cert.json; do
  "$cert" "$f" > "$work/out" || { cat "$work/out"; echo "FAIL: $f"; exit 1; }
  pass=$((pass + 1))
done

for f in test/tampered/*.json; do
  st=0; "$cert" "$f" > "$work/out" || st=$?
  [ "$st" -eq 1 ] || { cat "$work/out"; echo "FAIL: $f was not refused (exit $st)"; exit 1; }
  pass=$((pass + 1))
done

# the certificate reader: escapes, surrogates, and what it must refuse
lake env lean test/Json.lean
pass=$((pass + 1))

# writ_model … from: writ runs during elaboration
lake env lean test/From.lean
pass=$((pass + 1))

echo "writ-cert tests: $pass passed"
