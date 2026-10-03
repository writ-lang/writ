/-
Copyright (C) 2026 Alex Kunich
SPDX-License-Identifier: AGPL-3.0-or-later

# writ inside Lean

Two pieces, so that a writ model can be a Lean object and its properties Lean
theorems.

**`writ_model NAME from "MODEL.writ" [claims "FILE.claims"]`** runs `writ check --certificate`
on the model and defines `NAME.model : Writ.Model` and one
`NAME.«property» : Writ.Property` per question in the claims file.
**`writ_model NAME certificate "FILE.json"`** does the same from a certificate
already written, for a build with no writ on the PATH. writ's front end —
parsing, `load`, forms — is what makes the model; that is the same trust as
`writ-cert`, and nothing else is taken from writ: the graph and the verdicts
are not imported.

**`by writ`** proves `p.Holds M` or `¬ p.Holds M`. It explores the space,
finds a certificate (both untrusted, run at elaboration time), and closes the
goal with `holds_of_check`/`fails_of_check`, whose two premises —
`checkGraph M G = true` and `checkCert M G p c = true` — the KERNEL evaluates.
So the theorem's axioms are the standard three: no `native_decide`, no
`ofReduceBool`, nothing trusted but Lean. `by writ (native := true)` uses
`native_decide` instead, for spaces too large for the kernel, and says so in
`#print axioms`.
-/
import WritCert.Import
import WritCert.Generate
import WritCert.Props
import Lean

namespace Writ

open Lean Elab Meta Term Command Tactic

/-! ## Quoting certificates and models as terms -/

instance : ToExpr Path where
  toExpr p := mkApp2 (mkConst ``Path.mk) (toExpr p.root) (toExpr p.steps)
  toTypeExpr := mkConst ``Path

instance : ToExpr Rhs where
  toExpr
    | .lit v => mkApp (mkConst ``Rhs.lit) (toExpr v)
    | .chain p => mkApp (mkConst ``Rhs.chain) (toExpr p)
  toTypeExpr := mkConst ``Rhs

partial def guardToExpr : Guard → Expr
  | .and gs => mkApp (mkConst ``Guard.and) (listExpr gs)
  | .or gs => mkApp (mkConst ``Guard.or) (listExpr gs)
  | .not g => mkApp (mkConst ``Guard.not) (guardToExpr g)
  | .is p r => mkApp2 (mkConst ``Guard.is) (toExpr p) (toExpr r)
  | .defined p => mkApp (mkConst ``Guard.defined) (toExpr p)
  | .some x ty g => mkApp3 (mkConst ``Guard.some) (toExpr x) (toExpr ty) (guardToExpr g)
where
  listExpr (gs : List Guard) : Expr :=
    gs.foldr (fun g acc => mkApp3 (mkConst ``List.cons [0]) (mkConst ``Guard) (guardToExpr g) acc)
      (mkApp (mkConst ``List.nil [0]) (mkConst ``Guard))

instance : ToExpr Guard where
  toExpr := guardToExpr
  toTypeExpr := mkConst ``Guard

instance : ToExpr Effect where
  toExpr
    | .set p r => mkApp2 (mkConst ``Effect.set) (toExpr p) (toExpr r)
    | .vacate p => mkApp (mkConst ``Effect.vacate) (toExpr p)
    | .gap m => mkApp (mkConst ``Effect.gap) (toExpr m)
  toTypeExpr := mkConst ``Effect

instance : ToExpr Transition where
  toExpr t := mkApp3 (mkConst ``Transition.mk) (toExpr t.name) (toExpr t.guard) (toExpr t.effects)
  toTypeExpr := mkConst ``Transition

instance : ToExpr Equation where
  toExpr e := mkApp3 (mkConst ``Equation.mk) (toExpr e.name) (toExpr e.subject) (toExpr e.body)
  toTypeExpr := mkConst ``Equation

instance : ToExpr Model where
  toExpr m := mkAppN (mkConst ``Model.mk)
    #[toExpr m.members, toExpr m.layout, toExpr m.fixed, toExpr m.init,
      toExpr m.transitions, toExpr m.equations]
  toTypeExpr := mkConst ``Model

instance : ToExpr Modality where
  toExpr
    | .possible => mkConst ``Modality.possible
    | .never => mkConst ``Modality.never
    | .live => mkConst ``Modality.live
    | .inevitable f => mkApp (mkConst ``Modality.inevitable) (toExpr f)
  toTypeExpr := mkConst ``Modality

instance : ToExpr Property where
  toExpr p := mkApp3 (mkConst ``Property.mk) (toExpr p.name) (toExpr p.modality) (toExpr p.formula)
  toTypeExpr := mkConst ``Property

instance : ToExpr Out where
  toExpr
    | .absent => mkConst ``Out.absent
    | .gap m => mkApp (mkConst ``Out.gap) (toExpr m)
    | .to j => mkApp (mkConst ``Out.to) (toExpr j)
  toTypeExpr := mkConst ``Out

instance : ToExpr Graph where
  toExpr g := mkApp3 (mkConst ``Graph.mk) (toExpr g.states) (toExpr g.out) (toExpr g.parent)
  toTypeExpr := mkConst ``Graph

instance : ToExpr Round where
  toExpr r := mkAppN (mkConst ``Round.mk) #[toExpr r.move, toExpr r.rank, toExpr r.del, toExpr r.hasDel]
  toTypeExpr := mkConst ``Round

instance : ToExpr Cert where
  toExpr
    | .possibleHolds i => mkApp (mkConst ``Cert.possibleHolds) (toExpr i)
    | .possibleFails => mkConst ``Cert.possibleFails
    | .neverHolds => mkConst ``Cert.neverHolds
    | .neverFails i => mkApp (mkConst ``Cert.neverFails) (toExpr i)
    | .liveHolds r => mkApp (mkConst ``Cert.liveHolds) (toExpr r)
    | .liveFails k c => mkApp2 (mkConst ``Cert.liveFails) (toExpr k) (toExpr c)
    | .inevitableHolds rs f => mkApp2 (mkConst ``Cert.inevitableHolds) (toExpr rs) (toExpr f)
    | .inevitableStopped k => mkApp (mkConst ``Cert.inevitableStopped) (toExpr k)
    | .inevitableLasso c m => mkApp2 (mkConst ``Cert.inevitableLasso) (toExpr c) (toExpr m)
  toTypeExpr := mkConst ``Cert

/-! ## `by writ` -/

unsafe def evalModelUnsafe (e : Expr) : MetaM Model := evalExpr Model (mkConst ``Model) e
@[implemented_by evalModelUnsafe] opaque evalModel (e : Expr) : MetaM Model

unsafe def evalPropertyUnsafe (e : Expr) : MetaM Property := evalExpr Property (mkConst ``Property) e
@[implemented_by evalPropertyUnsafe] opaque evalProperty (e : Expr) : MetaM Property

/-- Prove a decidable `b = true` goal by kernel evaluation, or by the compiler. -/
def decideTrue (b : Expr) (native : Bool) : TermElabM Expr := do
  let goal ← mkEq b (mkConst ``Bool.true)
  let stx ← if native then `(by native_decide) else `(by decide +kernel)
  let pf ← elabTermEnsuringType stx goal
  synthesizeSyntheticMVarsNoPostponing
  instantiateMVars pf

syntax (name := writTac) "writ" (" (" &"native" " := " ident ")")? : tactic

@[tactic writTac] def evalWrit : Tactic := fun stx => withMainContext do
  let native := match stx[1] with
    | .missing => false
    | s => s[3].getId == `true
  let goal ← whnfR (← getMainTarget)
  let (negated, holds) ← match goal.not? with
    | some h => pure (true, h)
    | none => pure (false, goal)
  let holds ← whnfR holds
  let_expr Property.Holds M p := holds
    | throwError "writ: the goal must be `p.Holds M` or `¬ p.Holds M`, got{indentExpr goal}"
  let model ← evalModel M
  let prop ← evalProperty p
  let G ← match explore model with
    | .ok G => pure G
    | .error e => throwError "writ: {e}"
  let some c := certify model G prop
    | throwError "writ: no certificate found for this property"
  unless checkCert model G prop c do
    throwError "writ: the certificate found does not check (a bug in WritCert.Generate)"
  if c.verdict == negated then
    throwError "writ: the property {if c.verdict then "holds" else "fails"}; the goal asks the opposite"
  let gE := toExpr G
  let cE := toExpr c
  let pf ← Term.TermElabM.run' do
    let hG ← decideTrue (mkApp2 (mkConst ``checkGraph) M gE) native
    let hc ← decideTrue (mkApp4 (mkConst ``checkCert) M gE p cE) native
    let hv ← mkEqRefl (toExpr c.verdict)
    let lemma := if negated then ``fails_of_check else ``holds_of_check
    pure (mkAppN (mkConst lemma) #[M, gE, hG, p, cE, hc, hv])
  closeMainGoal `writ pf

/-! ## `writ_model` -/

def defineConst (n : Lean.Name) (type value : Expr) : CommandElabM Unit := liftTermElabM do
  addAndCompile <| .defnDecl {
    name := n, levelParams := [], type, value,
    hints := .abbrev, safety := .safe }

def importCertificate (base : Lean.Name) (text : String) : CommandElabM Unit := do
  let cert ← match Import.parse text with
    | .ok c => pure c
    | .error e => throwError "writ_model: {e}"
  defineConst (base ++ `model) (mkConst ``Model) (toExpr cert.model)
  defineConst (base ++ `names) (toTypeExpr (Array String)) (toExpr cert.names)
  for p in cert.props do
    if p.applicable then
      defineConst (base ++ Name.mkSimple p.name) (mkConst ``Property) (toExpr p.prop)
    else
      logWarning m!"writ_model: `{p.name}` is n/a in this model (it names structure the schema lacks); not defined"

/-- The directory of the file being elaborated: relative paths are read from it. -/
def sourceDir : CommandElabM System.FilePath := do
  return (System.FilePath.mk (← getFileName)).parent.getD "."

syntax (name := writModelFrom) "writ_model " ident " from " str (&" claims " str)? : command
syntax (name := writModelCert) "writ_model " ident &" certificate " str : command

@[command_elab writModelCert] def elabWritModelCert : CommandElab := fun stx => do
  let base := stx[1].getId
  let path := (← sourceDir) / stx[3].isStrLit?.get!
  let text ← match ← (IO.FS.readFile path).toBaseIO with
    | .ok t => pure t
    | .error e => throwError "writ_model: {e}"
  importCertificate base text

@[command_elab writModelFrom] def elabWritModelFrom : CommandElab := fun stx => do
  let base := stx[1].getId
  let dir ← sourceDir
  let model := stx[3].isStrLit?.get!
  let claimsFile := if stx[4].isMissing || stx[4].getNumArgs == 0 then none
    else stx[4][1].isStrLit?
  let writ := (← IO.getEnv "WRIT").getD "writ"
  let (_, file) ← match ← IO.FS.createTempFile.toBaseIO with
    | .ok r => pure r
    | .error e => throwError "writ_model: {e}"
  let args := #["check", model] ++ (match claimsFile with | some c => #["--claims", c] | none => #[]) ++
    #["--certificate", file.toString]
  let out ← match ← (IO.Process.output { cmd := writ, args, cwd := dir }).toBaseIO with
    | .ok o => pure o
    | .error e => throwError "writ_model: could not run `{writ}` ({e}); set WRIT, or use `writ_model … certificate`"
  -- 1 is a finding (a failing property), which is an answer; 2 is a failure
  unless out.exitCode ≤ 1 do
    throwError "writ_model: writ check failed:\n{out.stderr}"
  let text ← match ← (IO.FS.readFile file).toBaseIO with
    | .ok t => pure t
    | .error e => throwError "writ_model: {e}"
  discard <| (IO.FS.removeFile file).toBaseIO
  importCertificate base text

end Writ
