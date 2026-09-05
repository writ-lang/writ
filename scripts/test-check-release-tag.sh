#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# The release-tag rule, checked. Run: sh scripts/test-check-release-tag.sh
#
# Every case passes the previous tag and the declared version explicitly, so
# nothing here reads dune-project or git: the rule is tested, not this
# checkout's current state. That matters — the rule has to keep holding after
# the repository's own version moves.
set -u

here=$(cd "$(dirname "$0")" && pwd)
check="$here/check-release-tag.sh"
fails=0

# ok <expected: pass|fail> <label> <tag> <prev> <declared>
ok() {
  want=$1 label=$2
  shift 2
  if sh "$check" "$@" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    printf 'ok  : %s\n' "$label"
  else
    printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$want" "$got"
    fails=$((fails + 1))
  fi
}

ok pass "a tag matching dune-project, after the last one" v0.2.0 v0.1.0 0.2.0
ok pass "a patch bump is allowed — the size of the step is not this rule's call" v0.1.1 v0.1.0 0.1.1
ok pass "a major bump is allowed for the same reason" v1.0.0 v0.9.0 1.0.0
ok pass "the first release, ending .0" v0.1.0 "" 0.1.0

# The check this repository actually needs: nothing but dune-project decides
# what the artifacts are called, so a tag that disagrees with it ships a release
# whose every asset carries a different number.
ok fail "a tag ahead of dune-project" v0.2.0 v0.1.0 0.1.0
ok fail "a tag behind dune-project" v0.1.0 "" 0.2.0

ok fail "a tag without its v — the shape that never fires the workflow" 0.2.0 v0.1.0 0.2.0
ok fail "a two-component tag" v0.2 v0.1.0 0.2
ok fail "a four-component tag" v0.2.0.1 v0.1.0 0.2.0.1
ok fail "a tag that is not a version at all" latest v0.1.0 0.1.0

# The rule refuses a tag that does not exceed the one it is given. The git
# lookup never hands it the tag being checked (see check-release-tag.sh), so
# this is the rule's behaviour, not a claim that a re-cut release is caught.
ok fail "a tag that does not exceed the previous one" v0.1.0 v0.1.0 0.1.0
ok fail "going backwards" v0.1.0 v0.2.0 0.1.0

# 9 is not a carry digit. Comparing tags as text puts v0.9.0 above v0.10.0,
# which would refuse the correct tag and accept a repeat — so the comparison is
# numeric, and this is the case that says so.
ok pass "v0.10.0 comes after v0.9.0" v0.10.0 v0.9.0 0.10.0
ok fail "v0.9.0 does not come after v0.10.0" v0.9.0 v0.10.0 0.9.0

ok fail "a first release not ending in .0" v0.1.3 "" 0.1.3

# ---------------------------------------------------------------- the git path
#
# Everything above passes the previous tag explicitly, which is what makes it a
# test of the RULE. It is also what let the bug through: the release of v0.2.0
# failed because the lookup that finds the previous tag counted the tag being
# checked among the tags that already exist, and refused it for not coming
# after itself. No case above could see that, because no case above uses the
# lookup.
#
# So this stages a repository — the script, a dune-project, and tags — and asks
# it the question CI asks, in the state CI asks it in: after the tag exists.
git_path() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/scripts"
  cp "$check" "$tmp/scripts/"
  printf '(lang dune 3.0)\n(name writ)\n(version 0.2.0)\n' > "$tmp/dune-project"
  (
    cd "$tmp"
    git init -q .
    git add -A
    git -c user.email=t@example.com -c user.name=t commit -qm t
    git -c user.email=t@example.com -c user.name=t tag -a v0.1.0 -m one
    git -c user.email=t@example.com -c user.name=t tag -a v0.2.0 -m two
  ) >/dev/null 2>&1

  # v0.2.0 EXISTS here, which is the situation on a tag push.
  if sh "$tmp/scripts/check-release-tag.sh" v0.2.0 >/dev/null 2>&1; then
    printf 'ok  : %s\n' "a tag that already exists passes — it is being released"
  else
    printf 'FAIL: %s\n' "a tag that already exists is refused (the v0.2.0 bug)"
    fails=$((fails + 1))
  fi

  # …and the lookup must still see v0.1.0, so a tag below it is refused.
  printf '(lang dune 3.0)\n(name writ)\n(version 0.0.9)\n' > "$tmp/dune-project"
  if sh "$tmp/scripts/check-release-tag.sh" v0.0.9 >/dev/null 2>&1; then
    printf 'FAIL: %s\n' "a tag below the highest existing release is accepted"
    fails=$((fails + 1))
  else
    printf 'ok  : %s\n' "a tag below the highest existing release is still refused"
  fi

  rm -rf "$tmp"
}

git_path

if [ "$fails" != 0 ]; then
  printf '\n%s check(s) failed\n' "$fails"
  exit 1
fi
printf '\nall checks passed\n'
