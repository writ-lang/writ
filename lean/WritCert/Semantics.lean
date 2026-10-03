/-
Copyright (C) 2026 Alex Kunich
SPDX-License-Identifier: AGPL-3.0-or-later

# The reference semantics

What a writ model MEANS (kernel-spec §10, §12, §16.1), written as Lean
definitions. Nothing here is efficient and nothing here is a certificate: this
file is the specification the checker is proved against, and it is meant to be
read beside `runtime/eval.ml` and `runtime/space.ml`, clause by clause.

Names are interned to `Nat` before they reach this file (`WritCert.Import`).
That is a representation choice, not a semantic one — writ compares names as
strings and every comparison here is the same comparison on their codes — and it
is what lets the kernel evaluate a model: `Nat` equality is a GMP comparison in
the kernel, `String` equality is a walk over characters.

Every recursion below is structural, on purpose: a definition by well-founded
recursion does not unfold in the kernel, and `by writ` (`WritCert.Tactic`)
needs the kernel to run these.
-/

namespace Writ

abbrev Name := Nat

/-- A slot's content: a member, or nothing (`vacant`, §8.4). -/
abbrev Cell := Option Name

/-- A situation: one cell per mutable slot, in layout order (§12.1). -/
abbrev State := List Cell

/-- A chain `root.a₁.….aₙ` (§8.5). -/
structure Path where
  root : Name
  steps : List Name
  deriving DecidableEq, Repr, Inhabited

/-- The right side of `is` and `set`: a literal, or a second chain (§10.2). -/
inductive Rhs where
  | lit (v : Name)
  | chain (p : Path)
  deriving DecidableEq, Repr, Inhabited

/-- The guard language (§10.2). -/
inductive Guard where
  | and (gs : List Guard)
  | or (gs : List Guard)
  | not (g : Guard)
  | is (p : Path) (r : Rhs)
  | defined (p : Path)
  | some (x ty : Name) (g : Guard)
  deriving Repr, Inhabited

/-- Effects (§10.3, §10.4). -/
inductive Effect where
  | set (p : Path) (r : Rhs)
  | vacate (p : Path)
  | gap (msg : Name)
  deriving Repr, Inhabited

structure Transition where
  name : Name
  guard : Guard
  effects : List Effect
  deriving Repr, Inhabited

/-- An equation (§8.6): a guard over one free root, its subject. `subject` is
`none` only for a law writ would have rejected; writ reads such a law as holding,
and so does `eqHolds`. -/
structure Equation where
  name : Name
  subject : Option Name
  body : Guard
  deriving Repr, Inhabited

/-- A model after the front end is done with it: forms expanded, the instance
split into wiring (`fixed`) and the layout of mutable slots (§8.4, §9). -/
structure Model where
  /-- Every type's extent — an enumerated type's values, an open type's roster. -/
  members : List (Name × List Name)
  /-- The mutable slots, as (arrow, source entity), in state order. -/
  layout : List (Name × Name)
  /-- The wiring: each fixed slot's content. -/
  fixed : List ((Name × Name) × Cell)
  init : State
  transitions : List Transition
  equations : List Equation
  deriving Repr, Inhabited

namespace Model

def membersOf (M : Model) (ty : Name) : List Name := (M.members.lookup ty).getD []

end Model

/-- The position of the first `k` in `l`. -/
def indexOf (k : Name × Name) : List (Name × Name) → Nat → Option Nat
  | [], _ => none
  | x :: xs, i => if x = k then some i else indexOf k xs (i + 1)

/-- Read a slot: a mutable one from the situation, a fixed one from the wiring,
and anything else as vacant (`State.get`). -/
def getCell (M : Model) (s : State) (a src : Name) : Cell :=
  match indexOf (a, src) M.layout 0 with
  | some i => s.getD i none
  | none => (M.fixed.lookup (a, src)).getD none

/-- Walk a chain from an entity (`Eval.eval_path`): an empty slot ends the walk
with no answer. -/
def walk (M : Model) (s : State) : Name → List Name → Option Name
  | cur, [] => some cur
  | cur, a :: rest =>
    match getCell M s a cur with
    | none => none
    | some v => walk M s v rest

/-- A chain's answer. Its root is a `some`-bound variable if `env` binds it,
and otherwise the entity of that name. -/
def evalPath (M : Model) (s : State) (env : List (Name × Name)) (p : Path) : Option Name :=
  walk M s ((env.lookup p.root).getD p.root) p.steps

mutual
/-- Guard truth (§10.2; `Eval.guard_holds`). `is` is strict on both sides. -/
def evalGuard (M : Model) (s : State) (env : List (Name × Name)) : Guard → Bool
  | .and gs => evalAll M s env gs
  | .or gs => evalAny M s env gs
  | .not g => !evalGuard M s env g
  | .is p (.lit v) =>
    match evalPath M s env p with
    | some x => x == v
    | none => false
  | .is p (.chain q) =>
    match evalPath M s env p, evalPath M s env q with
    | some x, some y => x == y
    | _, _ => false
  | .defined p => (evalPath M s env p).isSome
  | .some x ty g => (M.membersOf ty).any fun e => evalGuard M s ((x, e) :: env) g

def evalAll (M : Model) (s : State) (env : List (Name × Name)) : List Guard → Bool
  | [] => true
  | g :: gs => evalGuard M s env g && evalAll M s env gs

def evalAny (M : Model) (s : State) (env : List (Name × Name)) : List Guard → Bool
  | [] => false
  | g :: gs => evalGuard M s env g || evalAny M s env gs
end

/-- Which slot a target chain names: walk all but its last step, then take the
last as the arrow (`Eval.target_index`). `none` — the effect is a no-op — for a
chain with no steps, a prefix with no answer, or a slot that is not mutable. -/
def target (M : Model) (s : State) (p : Path) : Option Nat :=
  match p.steps.getLast? with
  | none => none
  | some a =>
    match evalPath M s [] ⟨p.root, p.steps.dropLast⟩ with
    | some src => indexOf (a, src) M.layout 0
    | none => none

/-- A right-hand side's value, read in the situation the move started from. -/
def readRhs (M : Model) (s : State) : Rhs → Option Name
  | .lit v => some v
  | .chain q => evalPath M s [] q

inductive Write where
  | write (i : Nat) (c : Cell)
  | gap (msg : Name)

/-- Phase 1 of `Eval.apply`: resolve every effect against the starting
situation. `none` is `Blocked` — a `set` whose right side has no answer makes
the whole move absent, and outranks any `gap` (§10.3). -/
def resolve (M : Model) (s : State) : List Effect → Option (List Write)
  | [] => some []
  | .set p r :: rest =>
    match readRhs M s r with
    | none => none
    | some v =>
      match target M s p with
      | some i => (resolve M s rest).map (Write.write i (some v) :: ·)
      | none => resolve M s rest
  | .vacate p :: rest =>
    match target M s p with
    | some i => (resolve M s rest).map (Write.write i none :: ·)
    | none => resolve M s rest
  | .gap m :: rest => (resolve M s rest).map (Write.gap m :: ·)

def firstGap : List Write → Option Name
  | [] => none
  | .gap m :: _ => some m
  | .write .. :: ws => firstGap ws

def writeAll : State → List Write → State
  | s, [] => s
  | s, .write i c :: ws => writeAll (s.set i c) ws
  | s, .gap _ :: ws => writeAll s ws

/-- What a move does at a situation: nothing (it is absent), a gap, or a next
situation (§12.2). -/
inductive Outcome where
  | absent
  | gap (msg : Name)
  | next (s : State)
  deriving DecidableEq, Repr, Inhabited

/-- Phase 2 of `Eval.apply`: the first gap ends the model; otherwise the
writes, in order, into slots phase 1 already chose — a simultaneous assignment
(§10.1). -/
def apply (M : Model) (s : State) (effs : List Effect) : Outcome :=
  match resolve M s effs with
  | none => .absent
  | some ws =>
    match firstGap ws with
    | some m => .gap m
    | none => .next (writeAll s ws)

/-- Move `t` at situation `s`: absent where its guard is false (§10.1). -/
def step (M : Model) (s : State) (t : Nat) : Outcome :=
  match M.transitions[t]? with
  | none => .absent
  | some tr => if evalGuard M s [] tr.guard then apply M s tr.effects else .absent

/-! ## The meaning of a model (§12) -/

/-- The reachable situations: the least set holding the initial one and closed
under successor edges (§12.3). -/
inductive Reach (M : Model) : State → Prop where
  | init : Reach M M.init
  | step {s s' : State} {t : Nat} : Reach M s → step M s t = .next s' → Reach M s'

/-- Routes over real edges (gap edges lead nowhere). -/
inductive Steps (M : Model) : State → State → Prop where
  | refl (s : State) : Steps M s s
  | cons {s s' u : State} {t : Nat} : step M s t = .next s' → Steps M s' u → Steps M s u

/-- A situation satisfies a closed formula. -/
def Sat (M : Model) (F : Guard) (s : State) : Prop := evalGuard M s [] F = true

/-- Nothing moves on from `s`: no real edge out (a gap is not a move within the
model, §16.1). -/
def Stopped (M : Model) (s : State) : Prop := ∀ t s', step M s t ≠ .next s'

/-- Move `t` is on offer at `s` — it fires, to a situation or to a gap. -/
def Available (M : Model) (s : State) (t : Nat) : Prop := step M s t ≠ .absent

/-- A route from `s` to `u` all of whose situations, both ends included, fail F. -/
inductive Avoids (M : Model) (F : Guard) : State → State → Prop where
  | refl {s : State} : ¬Sat M F s → Avoids M F s s
  | cons {s s' u : State} {t : Nat} :
      ¬Sat M F s → step M s t = .next s' → Avoids M F s' u → Avoids M F s u

/-- An infinite run from `s` that never meets F and is fair to every move in
`fair`: a move on offer again and again for ever is taken again and again. -/
def AvoidsForever (M : Model) (F : Guard) (fair : List Nat) (s : State) : Prop :=
  ∃ (r : Nat → State) (ts : Nat → Nat),
    r 0 = s ∧
    (∀ n, step M (r n) (ts n) = .next (r (n + 1))) ∧
    (∀ n, ¬Sat M F (r n)) ∧
    ∀ m ∈ fair, (∀ N, ∃ n, N ≤ n ∧ Available M (r n) m) → ∀ N, ∃ n, N ≤ n ∧ ts n = m

/-- Some maximal run from `s` avoids F: it stops short of F, or it goes on for
ever without it, fairly. -/
def Escapes (M : Model) (F : Guard) (fair : List Nat) (s : State) : Prop :=
  (∃ u, Avoids M F s u ∧ Stopped M u) ∨ AvoidsForever M F fair s

/-! ## The four modalities (§16.1) -/

inductive Modality where
  | possible
  | never
  | live
  | inevitable (fair : List Nat)
  deriving DecidableEq, Repr, Inhabited

structure Property where
  name : Name
  modality : Modality
  formula : Guard
  deriving Repr, Inhabited

def Possible (M : Model) (F : Guard) : Prop := ∃ s, Reach M s ∧ Sat M F s

def Never (M : Model) (F : Guard) : Prop := ∀ s, Reach M s → ¬Sat M F s

def Live (M : Model) (F : Guard) : Prop := ∀ s, Reach M s → ∃ u, Steps M s u ∧ Sat M F u

def Inevitable (M : Model) (F : Guard) (fair : List Nat) : Prop :=
  ∀ s, Reach M s → ¬Escapes M F fair s

/-- What it means for a property to hold of a model. -/
def Property.Holds (M : Model) (p : Property) : Prop :=
  match p.modality with
  | .possible => Possible M p.formula
  | .never => Never M p.formula
  | .live => Live M p.formula
  | .inevitable fair => Inevitable M p.formula fair

/-! ## Laws (§8.6) -/

def evalEach (M : Model) (s : State) (x : Name) (g : Guard) : List Name → Bool
  | [] => true
  | e :: es => evalGuard M s [(x, e)] g && evalEach M s x g es

/-- A law holds at a situation when its guard holds of every member of its
subject (`Eval.eq_holds`). -/
def eqHolds (M : Model) (s : State) (eq : Equation) : Bool :=
  match eq.subject with
  | none => true
  | some x => evalEach M s x eq.body (M.membersOf x)

end Writ
