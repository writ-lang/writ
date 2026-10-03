/-
Copyright (C) 2026 Alex Kunich
SPDX-License-Identifier: AGPL-3.0-or-later

# The graph certificate

A candidate state space with each move's outcome at each situation.
`checkGraph` holds every cell to `Writ.step`, and `reach_iff` makes the listed
situations exactly the reachable ones, so the builder need not be trusted.
`parent` (an earlier situation with an edge in) makes reachability local.
-/
import WritCert.Semantics

namespace Writ

/-- One cell of the edge table. -/
inductive Out where
  | absent
  | gap (msg : Name)
  | to (j : Nat)
  deriving DecidableEq, Repr, Inhabited

structure Graph where
  states : Array State
  out : Array (Array Out)
  parent : Array Nat
  deriving Repr, Inhabited

namespace Graph

def size (G : Graph) : Nat := G.states.size
def st (G : Graph) (i : Nat) : State := G.states.getD i []
def row (G : Graph) (i : Nat) : Array Out := G.out.getD i #[]
def cell (G : Graph) (i t : Nat) : Out := (G.row i).getD t .absent
def par (G : Graph) (i : Nat) : Nat := G.parent.getD i 0

end Graph

/-! ## Bounded loops

`List.range` unfolds in the kernel and `List.all` compiles to a loop, so one
definition serves both `by writ` and large compiled checks. -/

def allBelow (n : Nat) (f : Nat → Bool) : Bool := (List.range n).all f
def anyBelow (n : Nat) (f : Nat → Bool) : Bool := (List.range n).any f

theorem allBelow_iff {n : Nat} {f : Nat → Bool} :
    allBelow n f = true ↔ ∀ i, i < n → f i = true := by
  simp [allBelow, List.all_eq_true, List.mem_range]

theorem anyBelow_iff {n : Nat} {f : Nat → Bool} :
    anyBelow n f = true ↔ ∃ i, i < n ∧ f i = true := by
  simp [anyBelow, List.any_eq_true, List.mem_range]

/-! ## The check -/

def outOK (M : Model) (G : Graph) (i t : Nat) : Bool :=
  match step M (G.st i) t, G.cell i t with
  | .absent, .absent => true
  | .gap m, .gap m' => m == m'
  | .next s', .to j => decide (j < G.size) && G.st j == s'
  | _, _ => false

def checkGraph (M : Model) (G : Graph) : Bool :=
  decide (0 < G.size) && G.st 0 == M.init &&
  allBelow G.size (fun i =>
    (G.row i).size == M.transitions.length &&
    allBelow M.transitions.length (fun t => outOK M G i t)) &&
  allBelow G.size (fun i =>
    i == 0 ||
    (decide (G.par i < i) &&
     anyBelow M.transitions.length (fun t => G.cell (G.par i) t == .to i)))

/-! ## What the check buys -/

section
variable {M : Model} {G : Graph}

theorem step_of_ge {s : State} {t : Nat} (h : M.transitions.length ≤ t) :
    step M s t = .absent := by
  simp [step, List.getElem?_eq_none h]

private theorem at_of_ge {i t : Nat} (hrow : (G.row i).size = M.transitions.length)
    (h : M.transitions.length ≤ t) : G.cell i t = .absent := by
  simp [Graph.cell, Array.getD, hrow]
  omega

private theorem parts (hG : checkGraph M G = true) :
    0 < G.size ∧ G.st 0 = M.init ∧
    (∀ i, i < G.size → (G.row i).size = M.transitions.length ∧
      ∀ t, t < M.transitions.length → outOK M G i t = true) ∧
    (∀ i, i < G.size → i = 0 ∨
      (G.par i < i ∧ ∃ t, t < M.transitions.length ∧ G.cell (G.par i) t = .to i)) := by
  simp only [checkGraph, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hG
  obtain ⟨⟨⟨h0, hinit⟩, hrows⟩, hpar⟩ := hG
  refine ⟨h0, hinit, ?_, ?_⟩
  · intro i hi
    have := (allBelow_iff.mp hrows) i hi
    simp only [Bool.and_eq_true, beq_iff_eq] at this
    exact ⟨this.1, fun t ht => (allBelow_iff.mp this.2) t ht⟩
  · intro i hi
    have := (allBelow_iff.mp hpar) i hi
    simp only [Bool.or_eq_true, beq_iff_eq, Bool.and_eq_true, decide_eq_true_eq] at this
    rcases this with h | ⟨hlt, hany⟩
    · exact .inl h
    · obtain ⟨t, ht, he⟩ := anyBelow_iff.mp hany
      exact .inr ⟨hlt, t, ht, by simpa using he⟩

theorem checkGraph_size (hG : checkGraph M G = true) : 0 < G.size := (parts hG).1

theorem checkGraph_init (hG : checkGraph M G = true) : G.st 0 = M.init := (parts hG).2.1

theorem outOK_all (hG : checkGraph M G = true) {i : Nat} (hi : i < G.size) (t : Nat) :
    (step M (G.st i) t = .absent ∧ G.cell i t = .absent) ∨
    (∃ m, step M (G.st i) t = .gap m ∧ G.cell i t = .gap m) ∨
    (∃ j, j < G.size ∧ step M (G.st i) t = .next (G.st j) ∧ G.cell i t = .to j) := by
  obtain ⟨hrow, hok⟩ := (parts hG).2.2.1 i hi
  by_cases ht : t < M.transitions.length
  · have h := hok t ht
    unfold outOK at h
    split at h
    · rename_i h1 h2; exact .inl ⟨h1, h2⟩
    · rename_i m m' h1 h2
      simp only [beq_iff_eq] at h
      subst h
      exact .inr (.inl ⟨m, h1, h2⟩)
    · rename_i s' j h1 h2
      simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at h
      exact .inr (.inr ⟨j, h.1, h.2 ▸ h1, h2⟩)
    · simp at h
  · have hge : M.transitions.length ≤ t := by omega
    exact .inl ⟨step_of_ge hge, at_of_ge hrow hge⟩

theorem at_to (hG : checkGraph M G = true) {i t j : Nat} (hi : i < G.size)
    (h : G.cell i t = .to j) : j < G.size ∧ step M (G.st i) t = .next (G.st j) := by
  rcases outOK_all hG hi t with ⟨_, h2⟩ | ⟨m, _, h2⟩ | ⟨j', hj', h1, h2⟩
  · rw [h] at h2; cases h2
  · rw [h] at h2; cases h2
  · rw [h] at h2; cases h2; exact ⟨hj', h1⟩

theorem step_next (hG : checkGraph M G = true) {i t : Nat} {s' : State} (hi : i < G.size)
    (h : step M (G.st i) t = .next s') : ∃ j, j < G.size ∧ G.cell i t = .to j ∧ G.st j = s' := by
  rcases outOK_all hG hi t with ⟨h1, _⟩ | ⟨m, h1, _⟩ | ⟨j, hj, h1, h2⟩
  · rw [h] at h1; cases h1
  · rw [h] at h1; cases h1
  · rw [h] at h1; cases h1; exact ⟨j, hj, h2, rfl⟩

theorem at_absent (hG : checkGraph M G = true) {i t : Nat} (hi : i < G.size) :
    G.cell i t = .absent ↔ step M (G.st i) t = .absent := by
  rcases outOK_all hG hi t with ⟨h1, h2⟩ | ⟨m, h1, h2⟩ | ⟨j, _, h1, h2⟩ <;> simp [h1, h2]

/-- Every listed situation is reachable, via its parent. -/
theorem reach_of_listed (hG : checkGraph M G = true) :
    ∀ i, i < G.size → Reach M (G.st i) := by
  intro i
  induction i using Nat.strongRecOn with
  | _ i ih =>
    intro hi
    rcases (parts hG).2.2.2 i hi with h | ⟨hlt, t, _, hat⟩
    · subst h; rw [checkGraph_init hG]; exact .init
    · have hp : G.par i < G.size := by omega
      exact .step (ih _ hlt hp) (at_to hG hp hat).2

theorem listed_of_reach (hG : checkGraph M G = true) {s : State} (h : Reach M s) :
    ∃ i, i < G.size ∧ G.st i = s := by
  induction h with
  | init => exact ⟨0, checkGraph_size hG, checkGraph_init hG⟩
  | step _ hs ih =>
    obtain ⟨i, hi, rfl⟩ := ih
    obtain ⟨j, hj, _, hst⟩ := step_next hG hi hs
    exact ⟨j, hj, hst⟩

/-- **The graph is the meaning.** -/
theorem reach_iff (hG : checkGraph M G = true) {s : State} :
    Reach M s ↔ ∃ i, i < G.size ∧ G.st i = s :=
  ⟨listed_of_reach hG, fun ⟨i, hi, h⟩ => h ▸ reach_of_listed hG i hi⟩

theorem steps_listed (hG : checkGraph M G = true) {s u : State} (h : Steps M s u) :
    ∀ i, i < G.size → G.st i = s → ∃ j, j < G.size ∧ G.st j = u := by
  induction h with
  | refl => intro i hi h; exact ⟨i, hi, h⟩
  | cons hs _ ih =>
    intro i hi rfl
    obtain ⟨j, hj, _, rfl⟩ := step_next hG hi hs
    exact ih j hj rfl

end

end Writ
