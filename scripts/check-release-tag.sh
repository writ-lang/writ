#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# check-release-tag.sh — a release tag has to mean what it says.
#
#     scripts/check-release-tag.sh v0.2.0
#     scripts/check-release-tag.sh v0.2.0 v0.1.0 0.2.0   # nothing read from git
#
# THREE THINGS ARE CHECKED, and the second is the one this repository actually
# needs.
#
#   1. THE SHAPE.  vX.Y.Z, and nothing else. This repository already carries a
#      tag `0.1.0` without its `v` — created by hand, pointing at a different
#      commit from `v0.1.0` — which is exactly the confusion a shape check
#      removes: `on: push: tags: ["v*"]` never fired for it, so it named a
#      release that was never built.
#
#   2. THE TAG AND dune-project MUST AGREE.  The version lives in ONE place,
#      `(version …)` in dune-project: opam publishes it, `writ --version`
#      prints it (tooling/cli/dune generates the module from it), `make release`
#      names the tarball with it and image-publish.yml reads it with sed to tag
#      the image. NOTHING reads the git tag. So tagging v0.2.0 without bumping
#      dune-project publishes an image tagged 0.1.0, a tarball named 0.1.0 and
#      a binary that reports 0.1.0, under a release called v0.2.0 — every
#      artifact quietly disagreeing with the release that carries it. That is
#      not a hypothetical: it is the default outcome of tagging, because the
#      bump is a separate act nothing forces.
#
#   3. THE TAG MUST GO FORWARD.  Strictly greater than the highest release tag
#      that already exists, so a release cannot be re-cut under a version that
#      has already been published or handed a number below one.
#
# WHAT IT DELIBERATELY DOES NOT DO: rule on how big the step is. Patch, minor
# and major bumps are all allowed, because which one a change deserves is a
# judgement about the change, and a script that made it would be overruled by
# hand the first time it was wrong.
#
# Run from CI before anything is built or pushed, so a wrong tag costs nothing.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)

new=${1:-}
[ -n "$new" ] || {
  echo "usage: $0 <new tag> [previous tag] [declared version]" >&2
  exit 2
}

# The declared version, read from the single place that holds it. Passed
# explicitly only by the self-test, which checks the rule rather than this
# checkout. `${3-…}` and not `${3:-…}`: an argument given as the empty string
# means "there is none", which is how the self-test says "no earlier release"
# without this script quietly falling back to what git happens to hold today.
declared=${3-$(sed -n 's/^(version \(.*\))/\1/p' "$root/dune-project")}

# The highest release tag that already exists, NOT COUNTING THE ONE BEING
# CHECKED. That exclusion is the whole subtlety, and it cost a release to find:
# this runs in CI on a tag push, where the tag has by definition already been
# created, so without the exclusion every tag is compared against itself and
# every release is refused for not coming after itself. v0.2.0 failed exactly
# that way.
#
# What the exclusion gives up: it can no longer tell that a version was
# ALREADY released — delete v0.2.0, re-tag it elsewhere, and this passes. That
# case is unreachable from CI anyway (the tag is always present there), so the
# alternative was not "catch it" but "refuse everything", and a check that
# refuses everything is one that gets deleted.
#
# "Highest", not "the one before this": comparing against the highest is what
# makes a tag BELOW an existing release fail rather than pass unnoticed.
highest_tag() {
  git -C "$root" tag --list 'v*' 2>/dev/null | while read -r t; do
    [ "$t" = "$new" ] && continue
    case $t in
      v[0-9]*.[0-9]*.[0-9]*) printf '%s %s\n' "$(key "$t")" "$t" ;;
    esac
  done | sort -k1,1n | tail -n 1 | cut -d' ' -f2
}

# A sortable integer for a tag, so `sort -n` orders 0.10.0 above 0.9.0 —
# ordering them as text does not, and 9-to-10 is precisely where a hand-written
# comparison goes wrong.
key() {
  v=${1#v}
  x=${v%%.*}; rest=${v#*.}; y=${rest%%.*}; z=${rest#*.}
  printf '%d\n' $((x * 1000000 + y * 1000 + z))
}

fail=0
say() { printf '  %s\n' "$1" >&2; fail=1; }

# 1. shape
case $new in
  v[0-9]*.[0-9]*.[0-9]*)
    # The glob above admits v1.2.3.4 and v1.2.x; pin it properly.
    if ! printf '%s' "$new" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
      say "$new is not a release tag. The shape is vX.Y.Z — for example v0.2.0."
    fi
    ;;
  *)
    say "$new is not a release tag. The shape is vX.Y.Z — for example v0.2.0."
    ;;
esac
[ "$fail" = 0 ] || { printf '\n' >&2; exit 1; }

# 2. agreement with dune-project
if [ "${new#v}" != "$declared" ]; then
  say "the tag says ${new#v}; dune-project says $declared."
  say "Bump (version $declared) to ${new#v} in dune-project, commit that, and"
  say "tag the commit — the tarball, the image tag and \`writ --version\` all"
  say "come from dune-project, and none of them look at the tag."
fi

# 3. forward
prev=${2-$(highest_tag)}
if [ -n "$prev" ]; then
  if [ "$(key "$new")" -le "$(key "$prev")" ]; then
    say "$new does not come after $prev, the highest release tag there is."
  fi
elif [ "${new##*.}" != 0 ]; then
  say "$new would be the first release, so it should end in .0."
fi

if [ "$fail" != 0 ]; then
  printf '\n  The rule is in %s, which is where it lives.\n' "scripts/check-release-tag.sh" >&2
  exit 1
fi

printf '  %s: version %s, after %s\n' "$new" "$declared" "${prev:-(no earlier release)}"
