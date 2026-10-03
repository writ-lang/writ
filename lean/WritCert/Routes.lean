/-
Copyright (C) 2026 Alex Kunich
SPDX-License-Identifier: AGPL-3.0-or-later

# Routes, distances, and counting

Three smaller claims every writ report makes, each made checkable:

- **a witness is a route** — replayed on the table, it is a sequence of real
  moves from the initial situation, landing where writ says each step lands;
- **a witness is shortest** — a distance certificate (each situation one more
  than its parent, no edge shortening anything) bounds every route from below;
- **`states: N` counts situations** — a sorting permutation shows the N listed
  situations are pairwise distinct, so with `reach_iff` there are exactly N
  reachable ones.
-/
import WritCert.Props

namespace Writ

/-- Routes over real edges, counted. -/
inductive StepsN (M : Model) : State → State → Nat → Prop where
  | refl (s : State) : StepsN M s s 0
  | cons {s s' u : State} {t k : Nat} : step M s t = .next s' → StepsN M s' u k → StepsN M s u (k + 1)

/-- Replay a route — (move, landing) pairs — on the table, from `i`. -/
def routeOK (G : Graph) : Nat → List (Nat × Nat) → Bool
  | _, [] => true
  | i, (t, j) :: rest => G.cell i t == .to j && routeOK G j rest

def routeEnd : Nat → List (Nat × Nat) → Nat
  | i, [] => i
  | _, (_, j) :: rest => routeEnd j rest

section
variable {M : Model} {G : Graph}

theorem route_sound (hG : checkGraph M G = true) :
    ∀ (r : List (Nat × Nat)) (i : Nat), i < G.size → routeOK G i r = true →
      routeEnd i r < G.size ∧ StepsN M (G.st i) (G.st (routeEnd i r)) r.length := by
  intro r
  induction r with
  | nil => intro i hi _; exact ⟨hi, .refl _⟩
  | cons p rest ih =>
    obtain ⟨t, j⟩ := p
    intro i hi h
    simp only [routeOK, Bool.and_eq_true, beq_iff_eq] at h
    obtain ⟨hj, hstep⟩ := at_to hG hi h.1
    obtain ⟨he, hs⟩ := ih j hj h.2
    exact ⟨he, .cons hstep hs⟩

/-! ## Distances -/

def distOK (M : Model) (G : Graph) (dist : Array Nat) : Bool :=
  dist.getD 0 0 == 0 &&
  allBelow G.size (fun i => i == 0 ||
    (dist.getD (G.par i) 0 + 1 == dist.getD i 0)) &&
  allBelow G.size (fun i => allBelow M.transitions.length fun t =>
    match G.cell i t with
    | .to j => decide (dist.getD j 0 ≤ dist.getD i 0 + 1)
    | _ => true)

/-- No route is shorter than the distance certificate says: any route of `L`
moves from a listed situation at distance `d` ends at a listed copy of its
end at distance at most `d + L`. -/
theorem dist_lower (hG : checkGraph M G = true) {dist : Array Nat}
    (hd : distOK M G dist = true) {s u : State} {L : Nat} (h : StepsN M s u L) :
    ∀ i, i < G.size → G.st i = s → ∃ j, j < G.size ∧ G.st j = u ∧ dist.getD j 0 ≤ dist.getD i 0 + L := by
  simp only [distOK, Bool.and_eq_true] at hd
  obtain ⟨_, hedge⟩ := hd
  induction h with
  | refl => intro i hi h; exact ⟨i, hi, h, by omega⟩
  | @cons s0 s' u' t k hs _ ih =>
    intro i hi rfl
    obtain ⟨j, hj, hat, rfl⟩ := step_next hG hi hs
    obtain ⟨j', hj', hst, hle⟩ := ih j hj rfl
    have ht : t < M.transitions.length := by
      refine Classical.byContradiction fun hge => ?_
      rw [step_of_ge (by omega)] at hs; cases hs
    have := (allBelow_iff.mp ((allBelow_iff.mp hedge) i hi)) t ht
    rw [hat] at this
    simp only [decide_eq_true_eq] at this
    exact ⟨j', hj', hst, by omega⟩

/-- A route to listed situation `k` of `dist[k]` moves, all of whose copies sit
no nearer, is a shortest route to that situation. -/
theorem shortest (hG : checkGraph M G = true) {dist : Array Nat}
    (hd : distOK M G dist = true) {k : Nat} (hcopies : ∀ j, j < G.size → G.st j = G.st k →
      dist.getD k 0 ≤ dist.getD j 0) {L : Nat} (hL : StepsN M M.init (G.st k) L) :
    dist.getD k 0 ≤ L := by
  have h0 : dist.getD 0 0 = 0 := by
    simp only [distOK, Bool.and_eq_true, beq_iff_eq] at hd; exact hd.1.1
  obtain ⟨j, hj, hst, hle⟩ :=
    dist_lower hG hd hL 0 (checkGraph_size hG) (checkGraph_init hG)
  have := hcopies j hj hst
  omega

/-- A satisfying situation `k` no farther than any other satisfying one: every
route to ANY situation satisfying F is at least `dist[k]` moves. -/
theorem nearest (hG : checkGraph M G = true) {dist : Array Nat}
    (hd : distOK M G dist = true) {F : Guard} {k : Nat}
    (hmin : ∀ j, j < G.size → G.sat M F j = true → dist.getD k 0 ≤ dist.getD j 0)
    {s : State} {L : Nat} (hL : StepsN M M.init s L) (hs : Sat M F s) :
    dist.getD k 0 ≤ L := by
  have h0 : dist.getD 0 0 = 0 := by
    simp only [distOK, Bool.and_eq_true, beq_iff_eq] at hd; exact hd.1.1
  obtain ⟨j, hj, rfl, hle⟩ :=
    dist_lower hG hd hL 0 (checkGraph_size hG) (checkGraph_init hG)
  have := hmin j hj hs
  omega

end

/-! ## Distinctness -/

/-- Lexicographic order on situations; a vacant cell sorts first. -/
def cellLt : Cell → Cell → Bool
  | none, some _ => true
  | some a, some b => decide (a < b)
  | _, _ => false

def stLt : State → State → Bool
  | [], _ :: _ => true
  | a :: as, b :: bs => cellLt a b || (a == b && stLt as bs)
  | _, _ => false

theorem cellLt_irrefl (a : Cell) : cellLt a a = false := by
  cases a <;> simp [cellLt]

theorem cellLt_trans : ∀ {a b c : Cell}, cellLt a b = true → cellLt b c = true → cellLt a c = true
  | none, some _, some _, _, _ => rfl
  | some _, some _, some _, h1, h2 => by
    simp only [cellLt, decide_eq_true_eq] at h1 h2 ⊢; exact Nat.lt_trans h1 h2
  | none, none, _, h1, _ => by simp [cellLt] at h1
  | some _, none, _, h1, _ => by simp [cellLt] at h1
  | _, some _, none, _, h2 => by simp [cellLt] at h2

theorem stLt_irrefl (a : State) : stLt a a = false := by
  induction a with
  | nil => rfl
  | cons x xs ih => simp [stLt, cellLt_irrefl, ih]

theorem stLt_trans : ∀ {a b c : State}, stLt a b = true → stLt b c = true → stLt a c = true
  | [], _ :: _, _ :: _, _, _ => rfl
  | _ :: _, _ :: _, _ :: _, h1, h2 => by
    simp only [stLt, Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq] at h1 h2 ⊢
    rcases h1 with h1 | ⟨rfl, h1⟩ <;> rcases h2 with h2 | ⟨rfl, h2⟩
    · exact .inl (cellLt_trans h1 h2)
    · exact .inl h1
    · exact .inl h2
    · exact .inr ⟨rfl, stLt_trans h1 h2⟩
  | [], [], _, h, _ => by simp [stLt] at h
  | _ :: _, [], _, h, _ => by simp [stLt] at h
  | _, _ :: _, [], _, h => by simp [stLt] at h

/-- `ord` lists the situations in strictly increasing order, and `inv` is its
inverse — so `ord` is a bijection and no two situations are equal. -/
def distinctOK (G : Graph) (ord inv : Array Nat) : Bool :=
  allBelow G.size (fun k => decide (ord.getD k 0 < G.size)) &&
  allBelow (G.size - 1) (fun k => stLt (G.st (ord.getD k 0)) (G.st (ord.getD (k + 1) 0))) &&
  allBelow G.size (fun i => decide (inv.getD i 0 < G.size) && ord.getD (inv.getD i 0) 0 == i)

theorem distinct (G : Graph) {ord inv : Array Nat} (h : distinctOK G ord inv = true) :
    ∀ i j, i < G.size → j < G.size → G.st i = G.st j → i = j := by
  simp only [distinctOK, Bool.and_eq_true] at h
  obtain ⟨⟨_, hsorted⟩, hinv⟩ := h
  have hord : ∀ k, k < G.size - 1 → stLt (G.st (ord.getD k 0)) (G.st (ord.getD (k + 1) 0)) = true :=
    fun k hk => (allBelow_iff.mp hsorted) k hk
  have chain : ∀ a d, a + d + 1 < G.size →
      stLt (G.st (ord.getD a 0)) (G.st (ord.getD (a + d + 1) 0)) = true := by
    intro a d
    induction d with
    | zero => intro h; exact hord a (by omega)
    | succ d ih =>
      intro h
      exact stLt_trans (ih (by omega)) (by
        have := hord (a + d + 1) (by omega)
        simpa [Nat.add_assoc] using this)
  have hi' : ∀ i, i < G.size → inv.getD i 0 < G.size ∧ ord.getD (inv.getD i 0) 0 = i := by
    intro i hi
    have := (allBelow_iff.mp hinv) i hi
    simpa using this
  intro i j hi hj hst
  obtain ⟨hki, hoi⟩ := hi' i hi
  obtain ⟨hkj, hoj⟩ := hi' j hj
  rcases Nat.lt_trichotomy (inv.getD i 0) (inv.getD j 0) with hlt | heq | hgt
  · have := chain (inv.getD i 0) (inv.getD j 0 - inv.getD i 0 - 1) (by omega)
    rw [show inv.getD i 0 + (inv.getD j 0 - inv.getD i 0 - 1) + 1 = inv.getD j 0 by omega,
      hoi, hoj, hst, stLt_irrefl] at this
    cases this
  · rw [← hoi, ← hoj, heq]
  · have := chain (inv.getD j 0) (inv.getD i 0 - inv.getD j 0 - 1) (by omega)
    rw [show inv.getD j 0 + (inv.getD i 0 - inv.getD j 0 - 1) + 1 = inv.getD i 0 by omega,
      hoi, hoj, hst, stLt_irrefl] at this
    cases this

/-- **`states: N` is right**: the reachable situations are exactly the N
listed ones, and those are N different situations. -/
theorem count_exact {M : Model} (hG : checkGraph M G = true) {ord inv : Array Nat}
    (h : distinctOK G ord inv = true) :
    ((List.range G.size).map G.st).Nodup ∧
      ∀ s, Reach M s ↔ s ∈ (List.range G.size).map G.st := by
  refine ⟨?_, fun s => ?_⟩
  · unfold List.Nodup
    rw [List.pairwise_map]
    refine List.Pairwise.imp_of_mem ?_ List.nodup_range
    intro i j hi hj hne hst
    exact hne (distinct G h i j (List.mem_range.mp hi) (List.mem_range.mp hj) hst)
  · rw [reach_iff hG]
    simp [List.mem_map, List.mem_range, eq_comm]

/-- The sorting permutation, found by sorting. Untrusted, like everything that
searches. -/
def sortCert (G : Graph) : Array Nat × Array Nat :=
  let ord := (Array.range G.size).qsort fun a b => stLt (G.st a) (G.st b)
  let inv := ord.foldl (init := (Array.replicate G.size 0, 0)) (fun (acc, k) i =>
    (acc.set! i k, k + 1)) |>.1
  (ord, inv)

end Writ
