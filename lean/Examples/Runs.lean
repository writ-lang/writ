/-
Every kind of `inevitable` evidence, as theorems (lean/test/runs.writ).
-/
import WritCert

open Writ

writ_model runs certificate "runs.cert.json"

/-- A run can flip the lamp for ever. -/
theorem loops : ¬ runs.loops.Holds runs.model := by writ

/-- Fair to `finish`, a run still spins for ever where `finish` is never offered. -/
theorem spins : ¬ runs.spins.Holds runs.model := by writ

/-- Fair to `finish`, no run flips for ever: an Emerson–Lei round. -/
theorem settles : runs.settles.Holds runs.model := by writ

/-- …which needs the fairness: without it, flipping avoids the goal. -/
theorem settles_unfair : ¬ runs.«settles-unfair».Holds runs.model := by writ

theorem leaves_off : runs.«leaves-off».Holds runs.model := by writ
theorem can_finish : ¬ runs.«can-finish».Holds runs.model := by writ
theorem can_spin : runs.«can-spin».Holds runs.model := by writ
theorem never_gone : runs.«never-gone».Holds runs.model := by writ

/-- The compiler instead of the kernel, for large spaces. -/
theorem settles' : runs.settles.Holds runs.model := by writ (native := true)
