#!/bin/sh
# End-to-end tests: SOLVE the Prologue puzzles with `pol` and check the answers
# — including the SOLUTION PATH `pol` prints (the witness under a holding
# `possible`). Each `pol check` exits 1 because it HAS findings to report — that
# is the correct outcome here (a blunder IS possible; the census ISN'T
# completable) — so the tests assert exit 1.
#
# Usage:  run-tests.sh [NAME | NUMBER | all | list]   (default: all)
#   run-tests.sh list      # the numbered menu
#   run-tests.sh 3         # run test #3 by number
#   run-tests.sh river     # run one by name
# `pol` is taken from $POL (default: the one on PATH).
set -u

here=$(cd "$(dirname "$0")" && pwd)
POL=${POL:-pol}
pass=0
fail=0

ok() {
  pass=$((pass + 1))
  printf '  [ok]   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf '  [FAIL] %s\n' "$1"
}
has() { # label  haystack  needle
  if printf '%s\n' "$2" | grep -qF "$3"; then ok "$1"; else bad "$1 — missing: $3"; fi
}
near() { # label  haystack  anchor  needle  (needle within 6 lines after anchor)
  if printf '%s\n' "$2" | grep -A6 -F "$3" | grep -qF "$4"; then ok "$1"; else bad "$1 — '$4' not shown under '$3'"; fi
}
lacks() { # label  haystack  needle  (assert the needle is ABSENT)
  if printf '%s\n' "$2" | grep -qF "$3"; then bad "$1 — unexpected: $3"; else ok "$1"; fi
}
exit_is() { # label  actual  expected
  if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else bad "$1 — exit $2, want $3"; fi
}

river() {
  echo "== The river crossing (kernel-spec Appendix C) =="
  echo "   Q: can the farmer get the wolf, goat and cabbage across intact?"
  out=$("$POL" check "$here/river/river.pol" --claims "$here/river/river.claims" 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  exit_is "river: check reports findings" "$st" 1
  has "river: 36 reachable arrangements" "$out" "states: 36"
  has "river: A. the crossing IS solvable" "$out" "holds  solvable"
  near "river:    and pol SHOWS a real, safe crossing (the solution path)" "$out" "holds  solvable" "witness:"
  near "river:    that brings the goat BACK — the hallmark of the real solution" "$out" "holds  solvable" "cross-goat-RL"
  near "river:    before ferrying the cabbage across" "$out" "holds  solvable" "cross-cabbage-LR"
  has "river: B. but a careless crossing dooms it" "$out" "fails  no-blunders"
  near "river:    pol names the blundering move" "$out" "fails  no-blunders" "witness:"
  near "river:    stranding prey with its predator is the mistake" "$out" "fails  no-blunders" "stuck at:"
}

queens() {
  echo "== Eight queens =="
  echo "   Q: can eight queens stand on a board with none attacking another?"
  out=$("$POL" check "$here/queens/queens.pol" --claims "$here/queens/queens.claims" 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /' | head -14
  exit_is "queens: check exits clean — nothing is wrong with the board" "$st" 0
  has "queens: 2057 situations, the column-ordered search tree" "$out" "states: 2057"
  has "queens: A. eight queens CAN be placed" "$out" "holds  solvable"
  near "queens:    and pol shows where they go" "$out" "holds  solvable" "witness:"
  near "queens:    starting from a first-column placement" "$out" "holds  solvable" "place-1-"
  # `near` looks six lines past its anchor and the witness is eight moves, so
  # the last one is asserted on the numbered line it prints as — a spelling
  # that occurs nowhere else, since dead ends are listed as "reached by:".
  has "queens:    through to the eighth column" "$out" "8. place-8-"
  # A complete board is a dead end whose route fills column 8. The other dead
  # ends are stuck prefixes — a partial board with no safe next column — which
  # is why this counts routes rather than dead ends.
  n=$(printf '%s\n' "$out" | grep 'reached by:' | grep -c 'place-8-')
  if [ "$n" -eq 92 ]; then
    ok "queens: B. all 92 complete boards are found (each a dead end)"
  else
    bad "queens: B. expected 92 complete boards, found $n"
  fi
}

island() {
  echo "== Knights & knaves (kernel-spec Appendix D) =="
  echo "   Q: can every native be classified, and who could be a knight?"
  out=$("$POL" check "$here/island/island.pol" --claims "$here/island/island.claims" 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  exit_is "island: check reports findings" "$st" 1
  has "island: 9 reachable situations" "$out" "states: 9"
  has "island: A. the rules run out — a gap" "$out" "gaps: 1"
  has "island:    the hole is reading cal, the knave-sayer" "$out" "read-cal —"
  has "island:    the rules are silent there" "$out" "rules are silent"
  has "island: B. NOT everyone is classifiable" "$out" "fails  census-completable"
  has "island: C. abe could be a knight" "$out" "holds  abe-can-be-knight"
  near "island:    and pol shows the reading that makes it so" "$out" "holds  abe-can-be-knight" "abe-is-knight"
  has "island:    bea could be a knight" "$out" "holds  bea-can-be-knight"
  has "island:    cal could be nothing at all" "$out" "fails  cal-can-be-knight"
}

jobshop_possible() {
  echo "== A blocking job shop =="
  echo "   Q: three jobs, three machines, no buffers — can every schedule still"
  echo "      finish, or can the shop walk into a deadlock?"
  out=$("$POL" check "$here/jobshop-possible/jobshop-possible.pol" --claims "$here/jobshop-possible/jobshop-possible.claims" 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  exit_is "jobshop-possible: check reports findings" "$st" 1
  has "jobshop-possible: 51 reachable schedules" "$out" "states: 51"
  has "jobshop-possible: A. some schedule finishes every job" "$out" "holds  all-finish"
  near "jobshop-possible:    and pol shows one" "$out" "holds  all-finish" "witness:"
  has "jobshop-possible: B. but not EVERY schedule can still finish" "$out" "fails  never-stuck"
  has "jobshop-possible:    the deadlock is named in full" "$out" \
    "m1.held-by=a m2.held-by=b m3.held-by=c"
  near "jobshop-possible:    reached by three moves, one per job" "$out" "fails  never-stuck" "a-enters"
  near "jobshop-possible:    each job holding the machine the next one wants" "$out" \
    "fails  never-stuck" "c-enters"
}

jobshop_best() {
  echo "== The same job shop, with a clock =="
  echo "   Q: what is the SHORTEST schedule, and what does it look like?"
  out=$("$POL" check "$here/jobshop-best/jobshop-best.pol" \
    --claims "$here/jobshop-best/jobshop-best.claims" 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  exit_is "jobshop-best: check reports a finding (the too-tight bound)" "$st" 1
  has "jobshop-best: 1314 situations — the shop times the clock" "$out" "states: 1314"
  has "jobshop-best: A. four ticks is NOT enough" "$out" "fails  done-by-4"
  has "jobshop-best: B. five ticks is — the optimum, pinned from both sides" "$out" \
    "holds  done-by-5"
  near "jobshop-best:    and pol prints the optimal schedule" "$out" \
    "holds  done-by-5" "witness:"
  # The optimum overlaps a and b while holding c back — which is exactly what
  # jobshop-possible proved was necessary, since all three in the shop at once
  # is the deadlock.
  near "jobshop-best:    it starts two jobs in the first tick" "$out" \
    "holds  done-by-5" "b-enters"
  near "jobshop-best:    and only then advances the clock" "$out" \
    "holds  done-by-5" "tick-1"
}

oversight() {
  echo "== Institutional architecture (kernel-spec §3, §4 running example) =="
  echo "   Q: can one lawful move permanently destroy accountability, and what"
  echo "      does repealing restoration actually cost?"
  out=$("$POL" check "$here/oversight/oversight.pol" --claims "$here/oversight/oversight.claims" 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  exit_is "oversight: check reports findings" "$st" 1
  has "oversight: A. our own powers can violate our own law" "$out" "equation same-agency"
  has "oversight:    the law's breakers are named" "$out" "can be broken by: capture-watchdog, restore-watchdog"
  lacks "oversight:    and both are accepted — nothing unadmitted" "$out" "unadmitted"
  has "oversight: B. the case can conclude" "$out" "holds  conviction-possible"
  near "oversight:    and pol prints the concluding move" "$out" "holds  conviction-possible" "witness:"
  has "oversight: C. accountability holds (restoration exists)" "$out" "holds  accountability"

  echo "   Q: this amendment repeals restoration — what does it change?"
  cmp=$("$POL" compare "$here/oversight/oversight.pol" "$here/oversight/oversight-repeal.pol" 2>&1)
  cst=$?
  printf '%s\n' "$cmp" | sed 's/^/     | /'
  exit_is "oversight: compare reports a loss" "$cst" 1
  has "oversight: D. the repeal LOSES accountability" "$cmp" "accountability       LOST"
  near "oversight:    one capture now traps the case forever" "$cmp" "accountability" "capture-watchdog"
  has "oversight:    same-agency itself is preserved" "$cmp" "same-agency          preserved"
}

workflow() {
  echo "== Regulated workflow — KYC / claims (kernel-spec §3) =="
  echo "   Q: where does automation end, which reassignments break the law, and"
  echo "      can a case get stuck?"
  out=$("$POL" check "$here/workflow/workflow.pol" --claims "$here/workflow/workflow.claims" 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  exit_is "workflow: check reports findings" "$st" 1
  has "workflow: A. automation ends at an escalation gap" "$out" "gaps: 1"
  has "workflow:    the gap hands off to a human" "$out" "escalated to a human"
  has "workflow: B. the unit-of-record law's breakers are named" "$out" "can be broken by: reassign-to-fraud, reassign-to-kyc"
  lacks "workflow:    and both reassignments are accepted" "$out" "unadmitted"
  has "workflow: C. no case gets stuck — always still settleable" "$out" "holds  settle-able"
  has "workflow:    and the assignee slot stays fillable" "$out" "holds  assignee-fillable"
}

access() {
  echo "== Access & privilege (kernel-spec §3) =="
  echo "   Q: is revocation always possible, or is some privilege permanent?"
  out=$("$POL" check "$here/access/access.pol" --claims "$here/access/access.claims" 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  exit_is "access: check reports findings" "$st" 1
  has "access: A. the root-tracing law's breaker is named" "$out" "can be broken by: delegate-alice-to-mallory"
  lacks "access:    and the delegation is accepted" "$out" "unadmitted"
  has "access: B. revocation is NOT always possible — a latch" "$out" "fails  revocation-possible"
  near "access:    the break-glass grant is the latching move" "$out" "fails  revocation-possible" "grant-breakglass-admin"
  near "access:    it strands the state with mallory admin forever" "$out" "fails  revocation-possible" "mallory.role=admin"
  has "access: C. the admins query is answered" "$out" "admins  (at state"
}

control() {
  echo "== pol control — a model's dynamics as data (kernel-spec §17) =="
  echo "   Q: can we export the move list and re-use it with the same machinery?"
  out=$("$POL" control "$here/oversight/oversight.pol" 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  exit_is "control: emits cleanly" "$st" 0
  has "control: it is an instance of the stdlib quiver schema" "$out" "(of quiver)"
  has "control: an edge per transition — capture-watchdog" "$out" "capture-watchdog"
  has "control:    ... and assign-judge" "$out" "assign-judge"
  # Prove the emitted quiver is real data: wrap it as a model and re-check it.
  tmp=$(mktemp -d)
  printf '%s\n' "$out" >"$tmp/ctrl.pol"
  printf '(load "ctrl.pol")\n(use quiver)\n(initial oversight-control)\n' >"$tmp/wrap.pol"
  if (cd "$tmp" && "$POL" check wrap.pol >/dev/null 2>&1); then
    ok "control: the emitted quiver re-parses and builds"
  else bad "control: the emitted quiver did not re-parse"; fi
  rm -rf "$tmp"
}

gitcompare() {
  echo "== pol compare --git — an amendment across commits (kernel-spec §17) =="
  echo "   Q: two git revisions of one model — what did the amendment cost?"
  if ! command -v git >/dev/null 2>&1; then
    printf '  [skip] pol compare --git needs git (not installed here)\n'
    return 0
  fi
  # A self-contained history: commit the law, then commit the repeal, in a
  # throwaway repo — so the demo is deterministic and needs no shared history.
  tmp=$(mktemp -d)
  cp "$here/oversight/oversight.pol" "$tmp/law.pol"
  cp "$here/oversight/oversight.claims" "$tmp/law.claims"
  (cd "$tmp" && git init -q && git add law.pol law.claims &&
    git -c user.email=t@t -c user.name=t commit -qm "v1: with restoration") >/dev/null 2>&1
  cp "$here/oversight/oversight-repeal.pol" "$tmp/law.pol"
  (cd "$tmp" && git add law.pol &&
    git -c user.email=t@t -c user.name=t commit -qm "amendment: repeal restoration") >/dev/null 2>&1
  out=$(cd "$tmp" && "$POL" compare --git HEAD~1 HEAD law.pol 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  exit_is "git-compare: the amendment loses a guarantee" "$st" 1
  has "git-compare: accountability is LOST across the two commits" "$out" "accountability       LOST"
  has "git-compare: same-agency is preserved" "$out" "same-agency          preserved"
  rm -rf "$tmp"
}

crosscheck() {
  echo "== The modality cross-check — two implementations of one question =="
  echo "   Q: does the rules engine, asked the SAME properties over the SAME"
  echo "      space, reach the same verdicts as \`pol check\`?"
  out=$(POL="$POL" sh "$here/modality-cross-check.sh" 2>&1)
  st=$?
  printf '%s\n' "$out" | sed 's/^/     | /'
  exit_is "cross-check: the two implementations agree everywhere" "$st" 0
  # The property total is counted from the claims files rather than written
  # down, so adding a property to any scenario obliges the oracle to cover it
  # instead of quietly shrinking the cross-check.
  want=$(cat "$here"/*/*.claims | grep -c '^(property')
  has "cross-check: all $want properties in the repo were considered" "$out" \
    "considered $want properties"
  has "cross-check: A. a possible is its satisfying set — non-empty holds" \
    "$out" "river/solvable  possible: satisfying set of"
  has "cross-check: B. a live is its COUNTEREXAMPLE set — empty holds" \
    "$out" "workflow/settle-able  live: counterexample set of 0"
  has "cross-check:    and a failing live names its witnesses" \
    "$out" "access/revocation-possible  live: counterexample set of 4"
  has "cross-check: C. the unexercised never branch says so" "$out" \
    "never: 0 properties — branch unexercised"
}

# The scenarios, in order — the single source of truth for `all`, numbering
# (1-based, as `list` prints), and name lookup. Each is a function above.
scenarios="river island queens jobshop_possible jobshop_best oversight workflow access control gitcompare crosscheck"

list_scenarios() {
  echo "tests (run one by name or number, e.g. '$0 3' or '$0 river'):"
  i=1
  for s in $scenarios; do
    printf '  %d. %s\n' "$i" "$s"
    i=$((i + 1))
  done
}

nth() { # 1-based index -> scenario name on stdout (nothing if out of range)
  i=1
  for s in $scenarios; do
    [ "$i" = "$1" ] && {
      echo "$s"
      return 0
    }
    i=$((i + 1))
  done
}

unknown() {
  printf '%s\n' "$1" >&2
  list_scenarios >&2
  exit 2
}

sel=${1:-all}
case "$sel" in
list | -l | --list)
  list_scenarios
  exit 0
  ;;
all)
  n=0
  for s in $scenarios; do
    [ "$n" = 0 ] || echo
    "$s"
    n=1
  done
  ;;
*[!0-9]*) # a name
  case " $scenarios " in
  *" $sel "*) "$sel" ;;
  *) unknown "unknown test: $sel" ;;
  esac
  ;;
*) # a number
  name=$(nth "$sel")
  [ -n "$name" ] && "$name" || unknown "no test #$sel"
  ;;
esac

echo
echo "-------- $pass checks passed, $fail failed --------"
[ "$fail" -eq 0 ]
