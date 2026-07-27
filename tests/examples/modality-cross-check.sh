#!/bin/sh
# The modality cross-check — two implementations of one question.
#
# `pol check` answers a `.claims` property with the checker's CTL reading
# (runtime/checker.ml). `pol derive` answers the SAME property, over the SAME
# enumerated space, from a hand-written `.rules` encoding beside each scenario
# (extension §2: "the modalities become two-line derivations"). This script runs
# both and compares them. It is the only test in the repo whose oracle is not a
# number its own author chose.
#
# A DISAGREEMENT IS A FINDING, NEVER A NUMBER TO ADJUST. If this goes red, one
# of the two implementations is wrong; find out which and say so. Do not tune a
# rule, a model or this script to make it green.
#
# POLARITY is per modality, and getting it backwards is the failure mode that
# leaves the script green while the oracle means nothing:
#
#   possible F   the relation is the SATISFYING set     non-empty ⟺ holds
#   live F       the relation is the COUNTEREXAMPLE set  empty     ⟺ holds
#   never F      the relation is the COUNTEREXAMPLE set  empty     ⟺ holds
#   n/a          skipped, and counted — a third outcome, never a failure
#
# `n/a` is Checker.Not_applicable: the property names schema structure the model
# lacks, so the `.rules` file could not express it either (its guard datum would
# name a missing arrow and the file would be rejected at read time). Skipped
# properties are counted so the coverage line stays honest.
#
# Usage:  modality-cross-check.sh          (`pol` is taken from $POL, as
#                                           run-tests.sh does; default: PATH)
set -u

here=$(cd "$(dirname "$0")" && pwd)
POL=${POL:-pol}

scenarios="river island queens jobshop-possible jobshop-best oversight workflow access"

considered=0
compared=0
skipped=0
bad=0
n_possible=0
n_live=0
n_never=0

ok() { printf '  [ok]   %s\n' "$1"; }
no() {
  bad=$((bad + 1))
  printf '  [FAIL] %s\n' "$1"
}

# The properties of a claims file, one `NAME MODALITY` per line.
#
# Comments and description strings are stripped before the scan, then every
# paren is spaced out so the datum can be walked as tokens: `(` `property` NAME
# … `(` MODALITY. Reading the modality positionally rather than by grepping for
# the word is what keeps a description mentioning "live" from being mistaken for
# one. (Assumed, and true of every claims file here: no `;` inside a string.)
props() {
  awk '
    { l = $0; sub(/;.*/, "", l); gsub(/"[^"]*"/, " ", l)
      gsub(/\(/, " ( ", l); gsub(/\)/, " ) ", l); s = s " " l }
    END {
      n = split(s, t, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        if (t[i] == "property" && t[i-1] == "(") {
          name = t[i+1]
          for (j = i + 2; j <= n; j++)
            if (t[j-1] == "(" &&
                (t[j] == "possible" || t[j] == "live" || t[j] == "never")) {
              print name, t[j]; break
            }
        }
      }
    }' "$1"
}

# What `pol check` says about one property: report.ml prints `holds  NAME`,
# `fails  NAME` or `n/a  NAME` on a line of its own (witnesses are indented).
verdict() { # check-output  name
  if printf '%s\n' "$1" | grep -qx "holds  $2"; then
    echo holds
  elif printf '%s\n' "$1" | grep -qx "fails  $2"; then
    echo fails
  elif printf '%s\n' "$1" | grep -qx "n/a  $2"; then
    echo na
  else
    echo unreported
  fi
}

for s in $scenarios; do
  model="$here/$s/$s.pol"
  claims="$here/$s/$s.claims"
  rules="$here/$s/$s.rules"
  echo "== $s =="
  if [ ! -f "$rules" ]; then
    no "$s: no $s.rules beside the scenario — nothing to cross-check against"
    continue
  fi
  check=$("$POL" check "$model" --claims "$claims" 2>&1)

  list=$(props "$claims")
  printf '%s\n' "$list" | grep -q . || {
    no "$s: no properties found in $s.claims"
    continue
  }

  # A `while read` over a pipe runs in a subshell in POSIX sh, which would throw
  # away every counter this script exists to report. Feed it from a here-doc.
  while read -r name modality; do
    [ -n "$name" ] || continue
    considered=$((considered + 1))
    case "$modality" in
    possible) n_possible=$((n_possible + 1)) ;;
    live) n_live=$((n_live + 1)) ;;
    never) n_never=$((n_never + 1)) ;;
    esac

    said=$(verdict "$check" "$name")
    if [ "$said" = na ]; then
      skipped=$((skipped + 1))
      ok "$s/$name  $modality: pol check says n/a — skipped, not compared"
      continue
    fi
    if [ "$said" = unreported ]; then
      no "$s/$name  pol check reported no verdict at all"
      continue
    fi

    out=$("$POL" derive "$model" "$rules" "$name" 2>&1)
    st=$?
    if [ "$st" -ne 0 ]; then
      no "$s/$name  pol derive exited $st: $(printf '%s\n' "$out" | head -1)"
      continue
    fi
    rows=$(printf '%s\n' "$out" | grep -c '^  ')

    # The polarity table above, and the only place in the script it is applied.
    case "$modality" in
    possible)
      what="satisfying set of"
      if [ "$rows" -gt 0 ]; then derived=holds; else derived=fails; fi
      ;;
    live | never)
      what="counterexample set of"
      if [ "$rows" -eq 0 ]; then derived=holds; else derived=fails; fi
      ;;
    *)
      no "$s/$name  unknown modality: $modality"
      continue
      ;;
    esac

    compared=$((compared + 1))
    if [ "$derived" = "$said" ]; then
      ok "$s/$name  $modality: $what $rows — both say $said"
    else
      no "$s/$name  $modality: $what $rows ⇒ the rules engine says $derived, but pol check says $said"
    fi
  done <<EOF
$list
EOF
done

echo
echo "considered $considered properties: $compared compared, $skipped skipped n/a"
echo "  possible: $n_possible   live: $n_live"

# An untested code path must not read as a tested one. The counterexample
# encoding for `never` is the same shape as `live`'s, but nothing in the repo
# exercises it, so it announces itself on every run. Adding a `never` property
# to any scenario exercises it automatically.
if [ "$n_never" -eq 0 ]; then
  echo "never: 0 properties — branch unexercised"
else
  echo "never: $n_never properties compared"
fi

# A green oracle that measured nothing is the decay mode a cross-check is most
# likely to reach; refuse to be one.
if [ "$compared" -eq 0 ]; then
  echo "cross-check compared zero properties — the oracle measured nothing"
  exit 1
fi

if [ "$bad" -eq 0 ]; then
  echo "the rules engine and pol check agree on all $compared compared properties"
else
  echo "$bad DISAGREEMENT(S) — a finding to report, not a number to adjust"
fi
[ "$bad" -eq 0 ]
