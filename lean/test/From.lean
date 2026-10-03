/-
`writ_model … from` runs writ while Lean elaborates, so it is tested in the
box that has writ (`make test`), not built with the library.
-/
import WritCert
open Writ

writ_model runs from "runs.writ" claims "runs.claims"

theorem settles : runs.settles.Holds runs.model := by writ
theorem loops : ¬ runs.loops.Holds runs.model := by writ
