/-
Copyright (C) 2026 Alex Kunich
SPDX-License-Identifier: AGPL-3.0-or-later

# Finding certificates

Untrusted searches for the evidence `WritCert.Props` checks. A wrong
certificate is refused by `checkCert`, so a bug here costs an answer, never
gives a wrong one.
-/
import WritCert.Props
import Std.Data.HashMap

namespace Writ

open Std

/-! ## The space, explored -/

/-- Breadth-first search in `Space.build`'s order, so the numbering matches
writ's. Used by `by writ`, which has no writ to ask. -/
def explore (M : Model) (cap : Nat := 200000) : Except String Graph := Id.run do
  let T := M.transitions.length
  let mut index : HashMap State Nat := HashMap.emptyWithCapacity 64
  let mut states : Array State := #[M.init]
  let mut out : Array (Array Out) := #[]
  let mut parent : Array Nat := #[0]
  index := index.insert M.init 0
  let mut i := 0
  while i < states.size do
    let s := states[i]!
    let mut row : Array Out := Array.mkEmpty T
    for t in [0:T] do
      match step M s t with
      | .absent => row := row.push .absent
      | .gap m => row := row.push (.gap m)
      | .next s' =>
        match index.get? s' with
        | some j => row := row.push (.to j)
        | none =>
          if states.size ≥ cap then
            return .error s!"state space exceeds cap ({cap})"
          let j := states.size
          index := index.insert s' j
          states := states.push s'
          parent := parent.push i
          row := row.push (.to j)
    out := out.push row
    i := i + 1
  return .ok { states, out, parent }

def succs (G : Graph) (T : Nat) : Array (Array Nat) :=
  (Array.range G.size).map fun i => Id.run do
    let mut r : Array Nat := #[]
    for t in [0:T] do
      match G.cell i t with
      | .to j => if j < G.size && !r.contains j then r := r.push j
      | _ => pure ()
    return r

/-- BFS parents; in writ's BFS numbering each precedes its child. -/
def bfs (G : Graph) (T : Nat) : Array Nat × Array Nat := Id.run do
  let n := G.size
  let sx := succs G T
  let inf := n + 1
  let mut dist := Array.replicate n inf
  let mut par := Array.replicate n 0
  if n == 0 then return (dist, par)
  dist := dist.set! 0 0
  let mut queue : Array Nat := #[0]
  let mut h := 0
  while h < queue.size do
    let i := queue[h]!
    h := h + 1
    for j in sx[i]! do
      if dist[j]! == inf then
        dist := dist.set! j (dist[i]! + 1)
        par := par.set! j i
        queue := queue.push j
  return (dist, par)

/-! ## Strongly connected components -/

/-- Iterative Tarjan over `alive`. Components are numbered in reverse
topological order (edges go higher to lower): the rank a round needs. -/
def tarjan (n : Nat) (succ : Array (Array Nat)) (alive : Nat → Bool) : Array (Option Nat) := Id.run do
  let mut visit := Array.replicate n (none : Option Nat)
  let mut low := Array.replicate n 0
  let mut onStack := Array.replicate n false
  let mut comp := Array.replicate n (none : Option Nat)
  let mut stack : Array Nat := #[]
  let mut clock := 0
  let mut ncomp := 0
  for root in [0:n] do
    if alive root && visit[root]!.isNone then
      visit := visit.set! root (some clock); low := low.set! root clock; clock := clock + 1
      stack := stack.push root; onStack := onStack.set! root true
      -- frames: (node, index of the next successor to try)
      let mut work : Array (Nat × Nat) := #[(root, 0)]
      while work.size > 0 do
        let (v, k) := work.back!
        let sv := (succ[v]!).filter alive
        if h : k < sv.size then
          let w := sv[k]
          work := work.pop.push (v, k + 1)
          match visit[w]! with
          | none =>
            visit := visit.set! w (some clock); low := low.set! w clock; clock := clock + 1
            stack := stack.push w; onStack := onStack.set! w true
            work := work.push (w, 0)
          | some vw =>
            if onStack[w]! && vw < low[v]! then low := low.set! v vw
        else
          work := work.pop
          if let some (p, _) := work.back? then
            if low[v]! < low[p]! then low := low.set! p low[v]!
          if some low[v]! == visit[v]! then
            let mut go := true
            while go do
              match stack.back? with
              | none => go := false
              | some w =>
                stack := stack.pop; onStack := onStack.set! w false
                comp := comp.set! w (some ncomp)
                if w == v then go := false
            ncomp := ncomp + 1
  return comp

/-! ## The certificates -/

/-- Backward BFS from F: a `live` rank, or a closed F-free remainder. -/
def backDist (G : Graph) (T : Nat) (sat : Nat → Bool) : Array (Option Nat) := Id.run do
  let n := G.size
  let sx := succs G T
  let mut preds := Array.replicate n (#[] : Array Nat)
  for i in [0:n] do
    for j in sx[i]! do preds := preds.modify j (·.push i)
  let mut d := Array.replicate n (none : Option Nat)
  let mut queue : Array Nat := #[]
  for i in [0:n] do
    if sat i then d := d.set! i (some 0); queue := queue.push i
  let mut h := 0
  while h < queue.size do
    let i := queue[h]!
    h := h + 1
    for p in preds[i]! do
      if d[p]!.isNone then
        d := d.set! p (some (d[i]!.getD 0 + 1)); queue := queue.push p
  return d

def liveCert (M : Model) (G : Graph) (F : Guard) (prefer : Option Nat) : Cert :=
  let T := M.transitions.length
  let d := backDist G T (G.sat M F)
  if d.all (·.isSome) then .liveHolds (d.map (·.getD 0))
  else
    let closed := d.map (·.isNone)
    let k := match prefer with
      | some k => if closed.getD k false then k else (closed.findIdx? id).getD 0
      | none => (closed.findIdx? id).getD 0
    .liveFails k closed

def routeWithin (G : Graph) (T : Nat) (inside : Nat → Bool) (a b : Nat) :
    Option (Array (Nat × Nat)) := Id.run do
  if a == b then return some #[]
  let n := G.size
  let mut prev := Array.replicate n (none : Option (Nat × Nat))
  let mut seen := Array.replicate n false
  seen := seen.set! a true
  let mut queue : Array Nat := #[a]
  let mut h := 0
  while h < queue.size do
    let i := queue[h]!
    h := h + 1
    for t in [0:T] do
      match G.cell i t with
      | .to j =>
        if inside j && !seen[j]! then
          seen := seen.set! j true
          prev := prev.set! j (some (i, t))
          queue := queue.push j
      | _ => pure ()
  if !seen[b]! then return none
  let mut path : Array (Nat × Nat) := #[]
  let mut cur := b
  let mut fuel := n
  while cur != a && fuel > 0 do
    fuel := fuel - 1
    match prev[cur]! with
    | some (i, t) => path := path.push (t, cur); cur := i
    | none => return none
  return some path.reverse

/-- A fair lasso through `k` within its component: take an internal edge of
every fair move the component offers, then return to `k`. -/
def lasso (M : Model) (G : Graph) (fair : List Nat) (alive : Nat → Bool)
    (comp : Array (Option Nat)) (k : Nat) : Option Cert := do
  let T := M.transitions.length
  let c ← comp[k]!
  let inC := fun i => alive i && comp[i]! == some c
  let members := (List.range G.size).filter inC
  -- one internal edge per fair move on offer; any edge if none (a cycle must move)
  let mut legs : Array (Nat × Nat × Nat) := #[]
  for m in fair.eraseDups do
    if members.any (fun i => G.cell i m != .absent) then
      let e := members.findSome? fun i =>
        match G.cell i m with
        | .to j => if inC j then some (i, m, j) else none
        | _ => none
      legs := legs.push (← e)
  if legs.isEmpty then
    let e := members.findSome? fun i =>
      (List.range T).findSome? fun t =>
        match G.cell i t with
        | .to j => if inC j then some (i, t, j) else none
        | _ => none
    legs := legs.push (← e)
  let mut steps : Array (Nat × Nat) := #[]
  let mut cur := k
  for (u, m, v) in legs do
    steps := steps ++ (← routeWithin G T inC cur u)
    steps := steps.push (m, v)
    cur := v
  steps := steps ++ (← routeWithin G T inC cur k)
  -- cyc[p] is where step p starts; moves[p] is the move it takes
  let cyc := #[k] ++ (steps.pop.map (·.2))
  return .inevitableLasso cyc (steps.map (·.1))

def inevitableCert (M : Model) (G : Graph) (F : Guard) (fair : List Nat) (prefer : Option Nat) :
    Option Cert := do
  let T := M.transitions.length
  let n := G.size
  let sat := G.sat M F
  let stopped := (List.range n).filter fun i =>
    !sat i && !(List.range T).any fun t => Graph.isTo (G.cell i t)
  if !stopped.isEmpty then
    let k := match prefer with
      | some k => if stopped.contains k then k else stopped.head!
      | none => stopped.head!
    return .inevitableStopped k
  let sx := succs G T
  let mut aliveA : Array Bool := (Array.range n).map fun i => !sat i
  let mut rounds : Array Round := #[]
  let mut changed := true
  let mut fuel := n * (fair.length + 1) + 1
  while changed && fuel > 0 do
    fuel := fuel - 1
    changed := false
    for m in fair.eraseDups do
      let alive := fun i => aliveA.getD i false
      let comp := tarjan n sx alive
      let ncomp := comp.foldl (fun acc c => max acc ((c.map (· + 1)).getD 0)) 0
      let mut offers := Array.replicate ncomp false
      let mut takes := Array.replicate ncomp false
      for i in [0:n] do
        if let some c := comp[i]! then
          match G.cell i m with
          | .absent => pure ()
          | .gap _ => offers := offers.set! c true
          | .to j =>
            offers := offers.set! c true
            if comp[j]! == some c then takes := takes.set! c true
      let hasDel := (Array.range ncomp).map fun c => offers[c]! && !takes[c]!
      if hasDel.any id then
        let rank := comp.map (·.getD 0)
        let del := (Array.range n).map fun i =>
          match comp[i]! with
          | some c => hasDel[c]! && G.cell i m != .absent
          | none => false
        rounds := rounds.push { move := m, rank, del, hasDel }
        aliveA := (Array.range n).map fun i => aliveA[i]! && !del[i]!
        changed := true
  let alive := fun i => aliveA.getD i false
  let comp := tarjan n sx alive
  let sizes := comp.foldl (fun (acc : HashMap Nat Nat) c =>
    match c with | some c => acc.insert c (acc.getD c 0 + 1) | none => acc) {}
  let cyclic := fun i =>
    match comp[i]! with
    | some c => sizes.getD c 0 > 1 || (sx[i]!).contains i
    | none => false
  let cyc := (List.range n).filter cyclic
  if cyc.isEmpty then
    return .inevitableHolds rounds.toList (comp.map (·.getD 0))
  let k := match prefer with
    | some k => if cyclic k then k else cyc.head!
    | none => cyc.head!
  lasso M G fair alive comp k

/-- A certificate for a property. `prefer` names the witness situation writ
chose, so the certificate backs writ's answer, not just some answer. -/
def certify (M : Model) (G : Graph) (p : Property) (prefer : Option Nat := none) : Option Cert :=
  let F := p.formula
  let n := G.size
  let firstSat := (List.range n).find? (G.sat M F)
  let pick := match prefer with
    | some k => if k < n && G.sat M F k then some k else firstSat
    | none => firstSat
  match p.modality with
  | .possible => some (match pick with | some i => .possibleHolds i | none => .possibleFails)
  | .never => some (match pick with | some i => .neverFails i | none => .neverHolds)
  | .live => some (liveCert M G F prefer)
  | .inevitable fair => inevitableCert M G F fair prefer

end Writ
