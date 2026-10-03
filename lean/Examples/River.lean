/-
The river crossing (writ-problems/river), as Lean theorems.

The certificate was written by
    writ check river.writ --claims river.claims --certificate river.cert.json
and only its MODEL and PROPERTIES are read here; the graph and the verdicts in
it are ignored. `by writ` re-explores the space and the kernel checks the
answer — so these are theorems about the model writ's front end produced, not
about what writ said of it.
-/
import WritCert

open Writ

writ_model river certificate "river.cert.json"

/-- The crossing can be made. -/
theorem river_solvable : river.solvable.Holds river.model := by writ

/-- …but not from every arrangement: one careless crossing strands it. -/
theorem river_blunders : ¬ river.«no-blunders».Holds river.model := by writ

/-- The same, unfolded: writ's words, Lean's definitions. -/
example : Possible river.model river.solvable.formula := river_solvable

/-- info: 'river_solvable' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms river_solvable
