#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# Export a certificate for every model under DIR... (with its sibling .claims,
# if any), then check them all. Files writ cannot build are skipped and counted.
#
#   sh scripts/corpus.sh WRIT_BINARY OUTDIR DIR...    (inside the box: make corpus)
set -eu
writ=$1; out=$2; shift 2
mkdir -p "$out"
n=0; skipped=0
for m in $(find "$@" -name '*.writ' -not -path '*/_build/*' -not -path '*/.lake/*' | sort); do
  c="${m%.writ}.claims"
  id=$(echo "$m" | tr '/' '_' | sed 's/^[._]*//')
  if [ -f "$c" ]; then set -- --claims "$(basename "$c")"; else set --; fi
  # exit 1 is a finding; the certificate is written either way
  if (cd "$(dirname "$m")" && timeout 600 "$writ" check "$(basename "$m")" "$@" \
        --certificate "$out/.partial" > /dev/null 2>&1; [ $? -le 1 ]) && [ -s "$out/.partial" ]; then
    mv "$out/.partial" "$out/$id.json"; n=$((n + 1))
  else
    skipped=$((skipped + 1))
  fi
done
echo "exported $n certificate(s); $skipped file(s) did not build"

cert=./.lake/build/bin/writ-cert
ok=0; bad=0
for f in "$out"/*.json; do
  if "$cert" "$f" > "$out/.result"; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1)); echo "== $(basename "$f")"; grep -v '^certified' "$out/.result"
  fi
done
echo "certified $ok; not certified $bad"
[ "$bad" -eq 0 ]
