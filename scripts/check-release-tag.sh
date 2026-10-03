#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# check-release-tag.sh — a release tag has to mean what it says.
#
#     scripts/check-release-tag.sh v0.2.0
#     scripts/check-release-tag.sh v0.2.0 v0.1.0 0.2.0   # nothing read from git
#
# Checks three things:
#   1. the shape is vX.Y.Z (a tag without `v` never fires the release workflows);
#   2. the tag equals `(version …)` in dune-project, which every artifact takes
#      its version from — nothing reads the tag;
#   3. the tag is strictly greater than the highest existing release tag.
# The size of the step (patch, minor, major) is not checked.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)

new=${1:-}
[ -n "$new" ] || {
  echo "usage: $0 <new tag> [previous tag] [declared version]" >&2
  exit 2
}

# `${3-…}`, not `${3:-…}`: the self-test passes "" to mean "no earlier
# release" without falling back to git.
declared=${3-$(sed -n 's/^(version \(.*\))/\1/p' "$root/dune-project")}

# The highest existing release tag, excluding the one being checked: in CI the
# tag already exists, and comparing it with itself would refuse every release.
# The cost is that a deleted and re-created tag passes.
highest_tag() {
  git -C "$root" tag --list 'v*' 2>/dev/null | while read -r t; do
    [ "$t" = "$new" ] && continue
    case $t in
      v[0-9]*.[0-9]*.[0-9]*) printf '%s %s\n' "$(key "$t")" "$t" ;;
    esac
  done | sort -k1,1n | tail -n 1 | cut -d' ' -f2
}

# A sortable integer, so 0.10.0 sorts above 0.9.0.
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
