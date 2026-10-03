#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build the downstream regression image with every downstream branch pinned to
# its current commit, so the clone cache is keyed on the commit, not "main".
#
#   downstream/build.sh                          # every repository at main
#   PROBLEMS_REF=my-branch downstream/build.sh   # one repository elsewhere
#   ARCH_REPO=https://github.com/me/writ-arch.git downstream/build.sh
#   downstream/build.sh --no-cache               # extra args go to docker build
#   downstream/build.sh --print-args             # NAME=VALUE lines, no build (CI)
#
# The repositories are read from the NAME_REPO / NAME_REF ARG lines in
# downstream/Dockerfile.
set -eu
cd "$(dirname "$0")/.."

dockerfile=downstream/Dockerfile
tag=${DOWNSTREAM_TAG:-writ-downstream}
print_only=0
if [ "${1:-}" = "--print-args" ]; then print_only=1; shift; fi
set --  -f "$dockerfile" -t "$tag" "$@"

for name in $(sed -n 's/^ARG \([A-Z0-9]*\)_REPO=.*/\1/p' "$dockerfile"); do
  repo=$(eval "printf '%s' \"\${${name}_REPO:-}\"")
  [ -n "$repo" ] || repo=$(sed -n "s/^ARG ${name}_REPO=//p" "$dockerfile")
  ref=$(eval "printf '%s' \"\${${name}_REF:-main}\"")
  # A ref that is already a full commit is used as it is; ls-remote cannot
  # resolve a bare SHA.
  if printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
    sha=$ref
  else
    sha=$(GIT_TERMINAL_PROMPT=0 git ls-remote "$repo" "refs/heads/$ref" "refs/tags/$ref" \
          | head -n 1 | cut -f1)
    [ -n "$sha" ] || { echo "downstream: no branch or tag '$ref' in $repo" >&2; exit 2; }
  fi
  printf 'downstream: %-11s %s  %s (%s)\n' "$name" "$sha" "$repo" "$ref" >&2
  if [ "$print_only" = 1 ]; then
    printf '%s_REPO=%s\n%s_REF=%s\n' "$name" "$repo" "$name" "$sha"
  fi
  set -- "$@" --build-arg "${name}_REPO=$repo" --build-arg "${name}_REF=$sha"
done
[ "$print_only" = 0 ] || exit 0

exec docker build "$@" .
