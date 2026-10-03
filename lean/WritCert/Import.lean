/-
Copyright (C) 2026 Alex Kunich
SPDX-License-Identifier: AGPL-3.0-or-later

# Reading a writ certificate

The JSON `writ check --certificate FILE` writes (docs/certificates.md), read into the kernel
structures with every name interned. Interning is the one transformation, and
it is injective by construction — one table, one code per distinct string — so
a guard compares the same names here that it compares in writ.

This file is part of what is trusted: a reader that mistook `"and"` for
`"or"` would check the wrong model. It is kept to a direct transcription for
that reason.
-/
import WritCert.Semantics
import WritCert.Graph
import WritCert.Json
import Std.Data.HashMap

namespace Writ.Import

structure Names where
  codes : Std.HashMap String Nat := {}
  strs : Array String := #[]

abbrev M := StateT Names (Except String)

def intern (s : String) : M Nat := do
  let t ← get
  match t.codes.get? s with
  | some c => pure c
  | none =>
    let c := t.strs.size
    set { codes := t.codes.insert s c, strs := t.strs.push s : Names }
    pure c

def fail {α} (msg : String) : M α := throw msg

def str (j : Json) : M String :=
  match j with
  | .str s => pure s
  | _ => fail s!"expected a string, got {j.compress}"

def arr (j : Json) : M (Array Json) :=
  match j with
  | .arr a => pure a
  | _ => fail s!"expected an array, got {(j.compress).take 80}"

def field (j : Json) (k : String) : M Json :=
  match j.getObjVal? k with
  | .ok v => pure v
  | .error _ => fail s!"missing field `{k}`"

def nat (j : Json) : M Nat :=
  match j.getNat? with
  | .ok n => pure n
  | .error _ => fail s!"expected a natural number, got {j.compress}"

def name (j : Json) : M Nat := do intern (← str j)

def cell (j : Json) : M Cell :=
  match j with
  | .null => pure none
  | _ => some <$> name j

def path (j : Json) : M Path := do
  let parts ← (← arr j).toList.mapM name
  match parts with
  | r :: steps => pure ⟨r, steps⟩
  | [] => fail "an empty path"

def rhs (j : Json) : M Rhs := do
  match j.getObjVal? "lit", j.getObjVal? "chain" with
  | .ok v, _ => .lit <$> name v
  | _, .ok p => .chain <$> path p
  | _, _ => fail s!"expected a right-hand side, got {j.compress}"

partial def guard (j : Json) : M Guard := do
  let a ← arr j
  let tag ← str (a.getD 0 .null)
  let args := a.toList.drop 1
  match tag, args with
  | "and", gs => .and <$> gs.mapM guard
  | "or", gs => .or <$> gs.mapM guard
  | "not", [g] => .not <$> guard g
  | "is", [p, r] => .is <$> path p <*> rhs r
  | "defined", [p] => .defined <$> path p
  | "some", [x, ty, g] => .some <$> name x <*> name ty <*> guard g
  | _, _ => fail s!"not a guard: {j.compress.take 120}"

def effect (j : Json) : M Effect := do
  let a ← arr j
  match ← str (a.getD 0 .null), a.toList.drop 1 with
  | "set", [p, r] => .set <$> path p <*> rhs r
  | "vacate", [p] => .vacate <$> path p
  | "gap", [m] => .gap <$> name m
  | _, _ => fail s!"not an effect: {j.compress.take 120}"

def model (j : Json) : M (Model × Array String) := do
  let members ← (← arr (← field j "types")).toList.mapM fun t => do
    pure (← name (← field t "name"), ← (← arr (← field t "members")).toList.mapM name)
  let layout ← (← arr (← field j "layout")).toList.mapM fun c => do
    pure (← name (← field c "arrow"), ← name (← field c "src"))
  let fixed ← (← arr (← field j "fixed")).toList.mapM fun c => do
    pure ((← name (← field c "arrow"), ← name (← field c "src")), ← cell (← field c "value"))
  let init ← (← arr (← field j "initial")).toList.mapM cell
  let trs ← (← arr (← field j "transitions")).toList.mapM fun t => do
    let label ← str (← field t "name")
    pure (label, ({ name := ← intern label, guard := ← guard (← field t "guard"),
                    effects := ← (← arr (← field t "effects")).toList.mapM effect } : Transition))
  let eqs ← (← arr (← field j "equations")).toList.mapM fun e => do
    let subject ← match ← field e "subject" with
      | .null => pure none
      | s => some <$> name s
    pure ({ name := ← name (← field e "name"), subject, body := ← guard (← field e "body") } : Equation)
  pure ({ members, layout, fixed, init, transitions := trs.map (·.2), equations := eqs },
        (trs.map (·.1)).toArray)

/-- A route as writ prints it: `[{"move", "to"}…]`. -/
def route (j : Json) : M (Array (String × Option Nat)) := do
  (← arr j).mapM fun s => do
    let mv ← str (← field s "move")
    let to ← match s.getObjVal? "to" with
      | .ok .null => pure none
      | .ok v => some <$> nat v
      | .error _ => pure none
    pure (mv, to)

structure WProp where
  name : String
  prop : Property
  applicable : Bool
  verdict : String
  witness : Array (String × Option Nat)
  stuck : Option Nat

structure WEquation where
  name : String
  eq : Equation
  violated : Option (Nat × Array (String × Option Nat))

structure Certificate where
  writ : String
  model : Model
  names : Array String
  moves : Array String
  props : Array WProp
  equations : Array WEquation
  reportStates : Nat
  reportEdges : Nat
  deadEnds : Array Nat
  gaps : Array (String × String × Nat)

def modality (s : String) (fair : List Nat) : M Modality :=
  match s with
  | "possible" => pure .possible
  | "never" => pure .never
  | "live" => pure .live
  | "inevitable" => pure (.inevitable fair)
  | _ => fail s!"unknown modality {s}"

def certificate (j : Json) : M Certificate := do
  unless (← str (← field j "format")) == "writ-certificate" do fail "not a writ certificate"
  let v ← nat (← field j "version")
  unless v == 2 do fail s!"certificate format version {v}; this checker reads version 2"
  let (m, moves) ← model (← field j "model")
  let rep ← field j "report"
  -- the report's verdicts, by name
  let repProps ← arr (← field rep "properties")
  let byName := repProps.filterMap fun p =>
    match p.getObjValAs? String "name" with
    | .ok n => some (n, p)
    | .error _ => none
  let props ← (← arr (← field j "properties")).mapM fun p => do
    let pname ← str (← field p "name")
    let fair ← (← arr (← field p "fair")).toList.mapM fun f => do
      let s ← str f
      pure ((moves.findIdx? (· == s)).getD moves.size)
    let mod ← modality (← str (← field p "modality")) fair
    let F ← guard (← field p "formula")
    let applicable := (p.getObjValAs? Bool "applicable").toOption.getD false
    let some (_, r) := byName.find? (·.1 == pname) | fail s!"the report has no property {pname}"
    let stuck ← match r.getObjVal? "stuck_at" with
      | .ok .null => pure none
      | .ok v => some <$> nat v
      | .error _ => pure none
    pure { name := pname, prop := { name := ← intern pname, modality := mod, formula := F },
           applicable, verdict := ← str (← field r "verdict"),
           witness := ← route (← field r "witness"), stuck : WProp }
  let repEqs ← arr (← field rep "equations")
  let equations ← (← arr (← field (← field j "model") "equations")).mapM fun e => do
    let ename ← str (← field e "name")
    let some r := repEqs.find? (fun r => (r.getObjValAs? String "name").toOption == some ename)
      | fail s!"the report has no equation {ename}"
    let violated ← match ← field r "violated" with
      | .null => pure none
      | v => pure (some (← nat (← field v "count"), ← route (← field v "witness")))
    let subject ← match ← field e "subject" with
      | .null => pure none
      | s => some <$> name s
    pure { name := ename, violated,
           eq := { name := ← intern ename, subject, body := ← guard (← field e "body") } : WEquation }
  let deadEnds ← (← arr (← field rep "dead_ends")).mapM fun d => do nat (← field d "state")
  let gaps ← (← arr (← field rep "gaps")).mapM fun g => do
    pure (← str (← field g "move"), ← str (← field g "message"), ← nat (← field g "min_moves"))
  let names := (← get).strs
  pure { writ := ← str (← field j "writ"), model := m, names, moves, props, equations,
         reportStates := ← nat (← field rep "states"), reportEdges := ← nat (← field rep "edges"),
         deadEnds, gaps }

def parse (text : String) : Except String Certificate := do
  let j ← Json.parse text
  (certificate j).run' {}

end Writ.Import
