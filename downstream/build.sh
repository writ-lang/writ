#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build the downstream regression image with every downstream branch pinned to
# the commit it points at right now.
#
#   downstream/build.sh                          # every repository at main
#   PROBLEMS_REF=my-branch downstream/build.sh   # one repository elsewhere
#   ARCH_REPO=https://github.com/me/writ-arch.git downstream/build.sh
#   downstream/build.sh --no-cache               # extra args go to docker build
#
# WHY RESOLVE AT ALL. A RUN that clones "main" is cached on the word "main",
# so a rebuild would keep testing against a stale checkout and say nothing.
# Passing the commit makes the cache key the thing that actually matters.
#
# The repositories are read from the ARG lines in downstream/Dockerfile, so a
# repository is added in one place. Each one is NAME_REPO and NAME_REF there,
# and the same names are honoured from the environment here.
set -eu
cd "$(dirname "$0")/.."

dockerfile=downstream/Dockerfile
tag=${DOWNSTREAM_TAG:-writ-downstream}
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
  printf 'downstream: %-11s %s  %s (%s)\n' "$name" "$sha" "$repo" "$ref"
  set -- "$@" --build-arg "${name}_REPO=$repo" --build-arg "${name}_REF=$sha"
done

exec docker build "$@" .
