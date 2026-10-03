/-
Copyright (C) 2026 Alex Kunich
SPDX-License-Identifier: AGPL-3.0-or-later

# Property certificates

Evidence that makes a verdict checkable by a scan, each check proved sound
against `WritCert.Semantics` (not writ's algorithm):

| verdict                | evidence                                                  |
|------------------------|-----------------------------------------------------------|
| `possible` holds/fails | none — a scan of a graph `reach_iff` made exact           |
| `never` holds/fails    | none — the same scan                                      |
| `live` holds           | a rank: each situation is F, or has an edge to a lower rank |
| `live` fails           | a closed set holding the stuck situation, F-free          |
| `inevitable` fails     | a stopped situation, or a fair F-free lasso through one   |
| `inevitable` holds     | Emerson–Lei rounds, then a rank that strictly falls       |

A fair run must leave each round's deleted situations for good; then the
final rank leaves no infinite run (`inevitable_holds`).
-/
import WritCert.Graph

namespace Writ

namespace Graph
def sat (M : Model) (G : Graph) (F : Guard) (i : Nat) : Bool := evalGuard M (G.st i) [] F

def isTo : Out → Bool
  | .to _ => true
  | _ => false

def target? : Out → Option Nat
  | .to j => some j
  | _ => none
end Graph

/-- One Emerson–Lei deletion. -/
structure Round where
  move : Nat
  rank : Array Nat
  del : Array Bool
  /-- `hasDel[k]`: some deleted situation has rank `k`. -/
  hasDel : Array Bool
  deriving Repr, Inhabited

inductive Cert where
  | possibleHolds (i : Nat)
  | possibleFails
  | neverHolds
  | neverFails (i : Nat)
  | liveHolds (rank : Array Nat)
  | liveFails (k : Nat) (closed : Array Bool)
  | inevitableHolds (rounds : List Round) (final : Array Nat)
  | inevitableStopped (k : Nat)
  | inevitableLasso (cyc moves : Array Nat)
  deriving Repr, Inhabited

/-- The verdict a certificate argues for: `true` is "holds". -/
def Cert.verdict : Cert → Bool
  | .possibleHolds _ | .neverHolds | .liveHolds _ | .inevitableHolds .. => true
  | _ => false

section checks
variable (M : Model) (G : Graph) (F : Guard)

local notation "T" => M.transitions.length
local notation "n" => G.size

def someSat : Bool := anyBelow n (G.sat M F)

def liveHoldsOK (rank : Array Nat) : Bool :=
  allBelow n fun i =>
    G.sat M F i ||
    anyBelow T fun t =>
      match G.cell i t with
      | .to j => decide (rank.getD j 0 < rank.getD i 0)
      | _ => false

def liveFailsOK (k : Nat) (closed : Array Bool) : Bool :=
  decide (k < n) && closed.getD k false &&
  allBelow n fun i =>
    !closed.getD i false ||
    (!G.sat M F i && allBelow T fun t =>
      match G.cell i t with
      | .to j => closed.getD j false
      | _ => true)

def stoppedOK (k : Nat) : Bool :=
  decide (k < n) && !G.sat M F k && allBelow T fun t => !Graph.isTo (G.cell k t)

def lassoOK (fair : List Nat) (cyc moves : Array Nat) : Bool :=
  let L := cyc.size
  decide (0 < L) && moves.size == L &&
  (allBelow L fun p =>
    decide (cyc.getD p 0 < n) && !G.sat M F (cyc.getD p 0) &&
    G.cell (cyc.getD p 0) (moves.getD p 0) == .to (cyc.getD ((p + 1) % L) 0)) &&
  fair.all fun m =>
    !(anyBelow L fun p => G.cell (cyc.getD p 0) m != .absent) ||
    anyBelow L fun p => moves.getD p 0 == m

/-- Nothing stops short of F. -/
def noStopOK : Bool :=
  allBelow n fun i => G.sat M F i || anyBelow T fun t => Graph.isTo (G.cell i t)

/-- The conditions of one round, over the region `alive`. -/
def roundOK (fair : List Nat) (alive : Nat → Bool) (R : Round) : Bool :=
  fair.contains R.move &&
  (allBelow n fun i => !alive i ||
    allBelow T fun t =>
      match G.cell i t with
      | .to j =>
        !alive j ||
        (decide (R.rank.getD j 0 ≤ R.rank.getD i 0) &&
         (t != R.move || decide (R.rank.getD j 0 < R.rank.getD i 0) ||
          !R.hasDel.getD (R.rank.getD i 0) false))
      | _ => true) &&
  (allBelow n fun i => !R.del.getD i false ||
    (alive i && G.cell i R.move != .absent && R.hasDel.getD (R.rank.getD i 0) false))

def finalOK (alive : Nat → Bool) (final : Array Nat) : Bool :=
  allBelow n fun i => !alive i ||
    allBelow T fun t =>
      match G.cell i t with
      | .to j => !alive j || decide (final.getD j 0 < final.getD i 0)
      | _ => true

def roundsOK (fair : List Nat) (final : Array Nat) : (Nat → Bool) → List Round → Bool
  | alive, [] => finalOK M G alive final
  | alive, R :: Rs =>
    roundOK M G fair alive R &&
    roundsOK fair final (fun i => alive i && !R.del.getD i false) Rs

end checks

def checkCert (M : Model) (G : Graph) (p : Property) (c : Cert) : Bool :=
  let F := p.formula
  match p.modality, c with
  | .possible, .possibleHolds i => decide (i < G.size) && G.sat M F i
  | .possible, .possibleFails => !someSat M G F
  | .never, .neverHolds => !someSat M G F
  | .never, .neverFails i => decide (i < G.size) && G.sat M F i
  | .live, .liveHolds rank => liveHoldsOK M G F rank
  | .live, .liveFails k closed => liveFailsOK M G F k closed
  | .inevitable fair, .inevitableHolds rounds final =>
    noStopOK M G F && roundsOK M G fair final (fun i => !G.sat M F i) rounds
  | .inevitable _, .inevitableStopped k => stoppedOK M G F k
  | .inevitable fair, .inevitableLasso cyc moves => lassoOK M G F fair cyc moves
  | _, _ => false

/-! ## Soundness -/

section sound
variable {M : Model} {G : Graph} {F : Guard}

theorem sat_iff {i : Nat} : G.sat M F i = true ↔ Sat M F (G.st i) := Iff.rfl

theorem possible_iff (hG : checkGraph M G = true) : someSat M G F = true ↔ Possible M F := by
  constructor
  · intro h
    obtain ⟨i, hi, hs⟩ := anyBelow_iff.mp h
    exact ⟨_, reach_of_listed hG i hi, hs⟩
  · rintro ⟨s, hr, hs⟩
    obtain ⟨i, hi, rfl⟩ := listed_of_reach hG hr
    exact anyBelow_iff.mpr ⟨i, hi, hs⟩

theorem never_iff : Never M F ↔ ¬Possible M F := by
  constructor
  · rintro h ⟨s, hr, hs⟩; exact h s hr hs
  · intro h s hr hs; exact h ⟨s, hr, hs⟩

/-! ### live -/

theorem live_holds (hG : checkGraph M G = true) {rank : Array Nat}
    (hc : liveHoldsOK M G F rank = true) : Live M F := by
  have key : ∀ k i, rank.getD i 0 = k → i < G.size → ∃ u, Steps M (G.st i) u ∧ Sat M F u := by
    intro k
    induction k using Nat.strongRecOn with
    | _ k ih =>
      intro i hk hi
      have h := (allBelow_iff.mp hc) i hi
      simp only [Bool.or_eq_true] at h
      rcases h with hs | hany
      · exact ⟨_, .refl _, hs⟩
      · obtain ⟨t, _, ht⟩ := anyBelow_iff.mp hany
        split at ht
        · rename_i j hj
          simp only [decide_eq_true_eq] at ht
          obtain ⟨hjn, hstep⟩ := at_to hG hi hj
          obtain ⟨u, hu, hsu⟩ := ih _ (hk ▸ ht) j rfl hjn
          exact ⟨u, .cons hstep hu, hsu⟩
        · cases ht
  intro s hr
  obtain ⟨i, hi, rfl⟩ := listed_of_reach hG hr
  exact key _ i rfl hi

theorem live_fails (hG : checkGraph M G = true) {k : Nat} {closed : Array Bool}
    (hc : liveFailsOK M G F k closed = true) : ¬Live M F := by
  simp only [liveFailsOK, Bool.and_eq_true, decide_eq_true_eq] at hc
  obtain ⟨⟨hk, hck⟩, hall⟩ := hc
  have inv : ∀ {s u}, Steps M s u → ∀ i, i < G.size → closed.getD i false = true →
      G.st i = s → ∃ j, j < G.size ∧ closed.getD j false = true ∧ G.st j = u := by
    intro s u h
    induction h with
    | refl => intro i hi hc h; exact ⟨i, hi, hc, h⟩
    | cons hs _ ih =>
      rename_i t _
      intro i hi hci rfl
      obtain ⟨j, hj, hat, rfl⟩ := step_next hG hi hs
      have h := (allBelow_iff.mp hall) i hi
      simp only [Bool.or_eq_true, Bool.not_eq_true', Bool.and_eq_true] at h
      rcases h with h | ⟨_, h⟩
      · rw [hci] at h; cases h
      · have := (allBelow_iff.mp h) t (by
          refine Classical.byContradiction fun hge => ?_
          have := step_of_ge (M := M) (s := G.st i) (by omega : M.transitions.length ≤ t)
          rw [hs] at this; cases this)
        rw [hat] at this
        exact ih j hj this rfl
  intro hlive
  obtain ⟨u, hsu, hsat⟩ := hlive _ (reach_of_listed hG k hk)
  obtain ⟨j, hj, hcj, rfl⟩ := inv hsu k hk hck rfl
  have h := (allBelow_iff.mp hall) j hj
  simp only [Bool.or_eq_true, Bool.not_eq_true', Bool.and_eq_true] at h
  rcases h with h | ⟨h, _⟩
  · rw [hcj] at h; cases h
  · exact absurd hsat (by simpa [Graph.sat, Sat] using h)

/-! ### inevitable, failing -/

theorem stopped_escapes (hG : checkGraph M G = true) {k : Nat} (fair : List Nat)
    (hc : stoppedOK M G F k = true) : ¬Inevitable M F fair := by
  simp only [stoppedOK, Bool.and_eq_true, decide_eq_true_eq, Bool.not_eq_true'] at hc
  obtain ⟨⟨hk, hns⟩, hall⟩ := hc
  intro hinev
  apply hinev _ (reach_of_listed hG k hk)
  refine .inl ⟨G.st k, .refl (by simpa [Graph.sat, Sat] using hns), ?_⟩
  intro t s' hs
  obtain ⟨j, _, hat, _⟩ := step_next hG hk hs
  have ht : t < M.transitions.length := by
    refine Classical.byContradiction fun hge => ?_
    have := step_of_ge (M := M) (s := G.st k) (by omega : M.transitions.length ≤ t)
    rw [hs] at this; cases this
  have := (allBelow_iff.mp hall) t ht
  rw [hat] at this
  simp [Graph.isTo] at this

theorem lasso_escapes (hG : checkGraph M G = true) {fair : List Nat} {cyc moves : Array Nat}
    (hc : lassoOK M G F fair cyc moves = true) : ¬Inevitable M F fair := by
  simp only [lassoOK, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, List.all_eq_true,
    Bool.or_eq_true, Bool.not_eq_true'] at hc
  obtain ⟨⟨⟨hL, hms⟩, hcyc⟩, hfair⟩ := hc
  have hp : ∀ p, p < cyc.size → cyc.getD p 0 < G.size ∧ G.sat M F (cyc.getD p 0) = false ∧
      G.cell (cyc.getD p 0) (moves.getD p 0) = .to (cyc.getD ((p + 1) % cyc.size) 0) := by
    intro p hp
    have := (allBelow_iff.mp hcyc) p hp
    simp only [Bool.and_eq_true, decide_eq_true_eq, Bool.not_eq_true', beq_iff_eq] at this
    exact ⟨this.1.1, this.1.2, this.2⟩
  let L := cyc.size
  let r : Nat → State := fun k => G.st (cyc.getD (k % L) 0)
  let ts : Nat → Nat := fun k => moves.getD (k % L) 0
  intro hinev
  have h0 := hp 0 hL
  apply hinev _ (reach_of_listed hG _ h0.1)
  refine .inr ⟨r, ts, ?_, ?_, ?_, ?_⟩
  · simp [r, Nat.zero_mod]
  · intro k
    have hk := hp (k % L) (Nat.mod_lt _ hL)
    have := (at_to hG hk.1 hk.2.2).2
    simp only [r, ts]
    rw [this, Nat.mod_add_mod]
  · intro k
    have hk := hp (k % L) (Nat.mod_lt _ hL)
    simpa [r, Graph.sat, Sat] using hk.2.1
  · intro m hm hio
    obtain ⟨k, _, hav⟩ := hio 0
    have hk := hp (k % L) (Nat.mod_lt _ hL)
    have hoff : G.cell (cyc.getD (k % L) 0) m ≠ .absent := by
      intro h; exact hav ((at_absent hG hk.1).mp h)
    rcases hfair m hm with h | h
    · have hany : (anyBelow cyc.size fun p => G.cell (cyc.getD p 0) m != Out.absent) = true :=
        anyBelow_iff.mpr ⟨k % L, Nat.mod_lt _ hL, bne_iff_ne.mpr hoff⟩
      rw [hany] at h; cases h
    · obtain ⟨p, hpL, hpm⟩ := anyBelow_iff.mp h
      intro N
      refine ⟨N * L + p, by
        have : N ≤ N * L := Nat.le_mul_of_pos_right N hL
        omega, ?_⟩
      simp only [ts]
      rw [Nat.mul_comm, Nat.mul_add_mod, Nat.mod_eq_of_lt hpL]
      simpa using hpm

/-! ### inevitable, holding -/

/-- A run, on the graph's indices. -/
structure IdxRun (M : Model) (G : Graph) (F : Guard) (fair : List Nat) (a ts : Nat → Nat) : Prop where
  lt : ∀ k, a k < G.size
  edge : ∀ k, G.cell (a k) (ts k) = .to (a (k + 1))
  nsat : ∀ k, G.sat M F (a k) = false
  fair : ∀ m ∈ fair, (∀ N, ∃ k, N ≤ k ∧ G.cell (a k) m ≠ .absent) → ∀ N, ∃ k, N ≤ k ∧ ts k = m

theorem antitone_stable (f : Nat → Nat) (hf : ∀ k, f (k + 1) ≤ f k) :
    ∃ K, ∀ k, K ≤ k → f k = f K := by
  suffices ∀ v (f : Nat → Nat), (∀ k, f (k + 1) ≤ f k) → f 0 = v → ∃ K, ∀ k, K ≤ k → f k = f K from
    this _ f hf rfl
  intro v
  induction v using Nat.strongRecOn with
  | _ v ih =>
    intro f hf hv
    have hle : ∀ k, f k ≤ f 0 := by
      intro k; induction k with
      | zero => exact Nat.le_refl _
      | succ k ihk => exact Nat.le_trans (hf k) ihk
    by_cases h : ∃ k, f k < f 0
    · obtain ⟨k0, hk0⟩ := h
      obtain ⟨K, hK⟩ := ih (f k0) (hv ▸ hk0) (fun j => f (k0 + j))
        (fun j => by simpa [Nat.add_assoc] using hf (k0 + j)) rfl
      refine ⟨k0 + K, fun k hk => ?_⟩
      have := hK (k - k0) (by omega)
      simpa [show k0 + (k - k0) = k by omega] using this
    · refine ⟨0, fun k _ => ?_⟩
      have := hle k
      have : ¬ f k < f 0 := fun hlt => h ⟨k, hlt⟩
      omega

theorem no_strict_descent (f : Nat → Nat) (N : Nat) (hf : ∀ k, N ≤ k → f (k + 1) < f k) : False := by
  have : ∀ j, f (N + j) + j ≤ f N := by
    intro j; induction j with
    | zero => simp
    | succ j ih =>
      have := hf (N + j) (by omega)
      show f (N + j + 1) + (j + 1) ≤ f N
      omega
  have := this (f N + 1)
  omega

theorem round_step (hG : checkGraph M G = true) {fair : List Nat} {a ts : Nat → Nat}
    (run : IdxRun M G F fair a ts)
    {alive : Nat → Bool} {R : Round} (hR : roundOK M G fair alive R = true)
    (hev : ∃ N, ∀ k, N ≤ k → alive (a k) = true) :
    ∃ N, ∀ k, N ≤ k → (alive (a k) && !R.del.getD (a k) false) = true := by
  simp only [roundOK, Bool.and_eq_true] at hR
  obtain ⟨⟨hmem, hedges⟩, hdel⟩ := hR
  obtain ⟨N, hN⟩ := hev
  -- the two edge conditions, read along the run
  have hE : ∀ k, N ≤ k → R.rank.getD (a (k + 1)) 0 ≤ R.rank.getD (a k) 0 ∧
      (ts k = R.move → R.rank.getD (a (k + 1)) 0 < R.rank.getD (a k) 0 ∨
        R.hasDel.getD (R.rank.getD (a k) 0) false = false) := by
    intro k hk
    have hT : ts k < M.transitions.length := by
      refine Classical.byContradiction fun hge => ?_
      have := (at_to hG (run.lt k) (run.edge k)).2
      rw [step_of_ge (by omega)] at this; cases this
    have h := (allBelow_iff.mp hedges) (a k) (run.lt k)
    simp only [hN k hk, Bool.not_true, Bool.false_or] at h
    have h := (allBelow_iff.mp h) (ts k) hT
    rw [run.edge k] at h
    simp only [hN (k + 1) (by omega), Bool.not_true, Bool.false_or, Bool.and_eq_true,
      decide_eq_true_eq, Bool.or_eq_true, bne_iff_ne, ne_eq, Bool.not_eq_true'] at h
    refine ⟨h.1, fun hm => ?_⟩
    rcases h.2 with (h | h) | h
    · exact absurd hm h
    · exact .inl h
    · exact .inr h
  obtain ⟨K, hK⟩ := antitone_stable (fun j => R.rank.getD (a (N + j)) 0)
    (fun j => by simpa [Nat.add_assoc] using (hE (N + j) (by omega)).1)
  have hconst : ∀ k, N + K ≤ k → R.rank.getD (a k) 0 = R.rank.getD (a (N + K)) 0 := by
    intro k hk
    have := hK (k - N) (by omega)
    simpa [show N + (k - N) = k by omega] using this
  cases hc : R.hasDel.getD (R.rank.getD (a (N + K)) 0) false
  · -- the class the run settles in has no deletion at all
    refine ⟨N + K, fun k hk => ?_⟩
    simp only [hN k (by omega), Bool.true_and, Bool.not_eq_true']
    cases hd : R.del.getD (a k) false
    · rfl
    · have h := (allBelow_iff.mp hdel) (a k) (run.lt k)
      simp only [hd, Bool.not_true, Bool.false_or, Bool.and_eq_true] at h
      rw [hconst k hk, hc] at h
      cases h.2
  · -- it has one, so the move is never taken again, so it stops being offered
    have hnot : ∀ k, N + K ≤ k → ts k ≠ R.move := by
      intro k hk hm
      rcases (hE k (by omega)).2 hm with h | h
      · rw [hconst k hk, hconst (k + 1) (by omega)] at h; omega
      · rw [hconst k hk, hc] at h; cases h
    have hoff : ∃ N', ∀ k, N' ≤ k → G.cell (a k) R.move = .absent := by
      have hm : R.move ∈ fair := by simpa using hmem
      apply Classical.byContradiction
      intro hno
      have hio : ∀ N', ∃ k, N' ≤ k ∧ G.cell (a k) R.move ≠ .absent := by
        intro N'
        apply Classical.byContradiction
        intro h'
        exact hno ⟨N', fun k hk => Classical.byContradiction fun hne => h' ⟨k, hk, hne⟩⟩
      obtain ⟨k, hk, hts⟩ := run.fair _ hm hio (N + K)
      exact hnot k hk hts
    obtain ⟨N', hN'⟩ := hoff
    refine ⟨N + K + N', fun k hk => ?_⟩
    simp only [hN k (by omega), Bool.true_and, Bool.not_eq_true']
    cases hd : R.del.getD (a k) false
    · rfl
    · have h := (allBelow_iff.mp hdel) (a k) (run.lt k)
      simp only [hd, Bool.not_true, Bool.false_or, Bool.and_eq_true, bne_iff_ne, ne_eq] at h
      exact absurd (hN' k (by omega)) h.1.2

theorem final_step (hG : checkGraph M G = true) {fair : List Nat} {a ts : Nat → Nat}
    (run : IdxRun M G F fair a ts) {alive : Nat → Bool} {final : Array Nat}
    (hf : finalOK M G alive final = true) (hev : ∃ N, ∀ k, N ≤ k → alive (a k) = true) :
    False := by
  obtain ⟨N, hN⟩ := hev
  apply no_strict_descent (fun k => final.getD (a k) 0) N
  intro k hk
  have hT : ts k < M.transitions.length := by
    refine Classical.byContradiction fun hge => ?_
    have := (at_to hG (run.lt k) (run.edge k)).2
    rw [step_of_ge (by omega)] at this; cases this
  have h := (allBelow_iff.mp hf) (a k) (run.lt k)
  simp only [hN k hk, Bool.not_true, Bool.false_or] at h
  have h := (allBelow_iff.mp h) (ts k) hT
  rw [run.edge k] at h
  simpa [hN (k + 1) (by omega)] using h

theorem rounds_sound (hG : checkGraph M G = true) {fair : List Nat} {a ts : Nat → Nat}
    (run : IdxRun M G F fair a ts) {final : Array Nat} :
    ∀ (Rs : List Round) (alive : Nat → Bool), roundsOK M G fair final alive Rs = true →
      (∃ N, ∀ k, N ≤ k → alive (a k) = true) → False := by
  intro Rs
  induction Rs with
  | nil => intro alive h hev; exact final_step hG run h hev
  | cons R Rs ih =>
    intro alive h hev
    simp only [roundsOK, Bool.and_eq_true] at h
    exact ih _ h.2 (round_step hG run h.1 hev)

theorem avoids_end {s u : State} (h : Avoids M F s u) : ¬Sat M F u ∧ Steps M s u := by
  induction h with
  | refl h => exact ⟨h, .refl _⟩
  | cons _ hs _ ih => exact ⟨ih.1, .cons hs ih.2⟩

/-- The run's situations as graph indices, following the table from `i0`. -/
def idxSeq (G : Graph) (i0 : Nat) (ts : Nat → Nat) : Nat → Nat
  | 0 => i0
  | k + 1 =>
    match G.cell (idxSeq G i0 ts k) (ts k) with
    | .to j => j
    | _ => 0

theorem inevitable_holds (hG : checkGraph M G = true) {fair : List Nat}
    {rounds : List Round} {final : Array Nat}
    (hstop : noStopOK M G F = true)
    (hr : roundsOK M G fair final (fun i => !G.sat M F i) rounds = true) :
    Inevitable M F fair := by
  intro s hs hesc
  obtain ⟨i, hi, rfl⟩ := listed_of_reach hG hs
  rcases hesc with ⟨u, hav, hstopped⟩ | ⟨r, ts, h0, hstep, hnsat, hfair⟩
  · obtain ⟨hnu, hsu⟩ := avoids_end hav
    obtain ⟨j, hj, rfl⟩ := steps_listed hG hsu i hi rfl
    have h := (allBelow_iff.mp hstop) j hj
    simp only [Bool.or_eq_true] at h
    rcases h with h | h
    · exact hnu h
    · obtain ⟨t, _, ht⟩ := anyBelow_iff.mp h
      cases hc : G.cell j t with
      | to j' => exact hstopped t _ (at_to hG hj hc).2
      | absent => rw [hc] at ht; cases ht
      | gap m => rw [hc] at ht; cases ht
  · let a := idxSeq G i ts
    have inv : ∀ k, a k < G.size ∧ G.st (a k) = r k := by
      intro k
      induction k with
      | zero => exact ⟨hi, h0.symm⟩
      | succ k ih =>
        obtain ⟨hk, hst⟩ := ih
        have := hstep k
        rw [← hst] at this
        obtain ⟨j, hj, hc, hsj⟩ := step_next hG hk this
        have : a (k + 1) = j := by simp only [a, idxSeq]; simp only [a] at hc; rw [hc]
        exact ⟨this ▸ hj, this ▸ hsj⟩
    have run : IdxRun M G F fair a ts := by
      refine ⟨fun k => (inv k).1, ?_, ?_, ?_⟩
      · intro k
        have := hstep k
        rw [← (inv k).2] at this
        obtain ⟨j, _, hc, hsj⟩ := step_next hG (inv k).1 this
        have : a (k + 1) = j := by simp only [a, idxSeq]; simp only [a] at hc; rw [hc]
        rw [hc, this]
      · intro k
        have := hnsat k
        rw [← (inv k).2] at this
        simpa [Graph.sat, Sat] using this
      · intro m hm hio
        apply hfair m hm
        intro N
        obtain ⟨k, hk, hne⟩ := hio N
        refine ⟨k, hk, ?_⟩
        intro habs
        rw [← (inv k).2] at habs
        exact hne ((at_absent hG (inv k).1).mpr habs)
    exact rounds_sound hG run rounds _ hr ⟨0, fun k _ => by simp [run.nsat k]⟩

/-! ### All together -/

/-- **A checked certificate's verdict is the property's truth.** -/
theorem checkCert_sound (hG : checkGraph M G = true) {p : Property} {c : Cert}
    (hc : checkCert M G p c = true) :
    (c.verdict = true → p.Holds M) ∧ (c.verdict = false → ¬p.Holds M) := by
  obtain ⟨name, mod, F⟩ := p
  cases mod <;> cases c <;>
    simp only [checkCert, Bool.and_eq_true, decide_eq_true_eq, Bool.not_eq_true',
      reduceCtorEq] at hc <;>
    simp only [Cert.verdict, Property.Holds, Bool.true_eq_false, Bool.false_eq_true,
      false_implies, true_implies, and_true, true_and]
  · exact ⟨_, reach_of_listed hG _ hc.1, hc.2⟩
  · intro h; exact absurd ((possible_iff hG).mpr h) (by simp [hc])
  · exact never_iff.mpr fun h => absurd ((possible_iff hG).mpr h) (by simp [hc])
  · intro h; exact h _ (reach_of_listed hG _ hc.1) hc.2
  · exact live_holds hG hc
  · exact live_fails hG hc
  · exact inevitable_holds hG hc.1 hc.2
  · exact stopped_escapes hG _ hc
  · exact lasso_escapes hG hc

theorem holds_of_check (hG : checkGraph M G = true) {p : Property} {c : Cert}
    (hc : checkCert M G p c = true) (hv : c.verdict = true) : p.Holds M :=
  (checkCert_sound hG hc).1 hv

theorem fails_of_check (hG : checkGraph M G = true) {p : Property} {c : Cert}
    (hc : checkCert M G p c = true) (hv : c.verdict = false) : ¬p.Holds M :=
  (checkCert_sound hG hc).2 hv

end sound

end Writ
