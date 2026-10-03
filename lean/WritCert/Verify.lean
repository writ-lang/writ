/-
Copyright (C) 2026 Alex Kunich
SPDX-License-Identifier: AGPL-3.0-or-later

# Holding writ to its report

Re-derives every line `writ check` prints from a checked certificate: each is
certified, DISAGREES (a bug in writ), uncertified (a gap in the checker), or
trusted (an n/a verdict, passed through).
-/
import WritCert.Import
import WritCert.Generate
import WritCert.Routes

namespace Writ.Verify

open Writ.Import

inductive Status where
  | certified
  | disagrees
  | uncertified
  | trusted
  deriving BEq, Repr

structure Line where
  status : Status
  what : String
  detail : String

def Status.tag : Status → String
  | .certified => "certified  "
  | .disagrees => "DISAGREES  "
  | .uncertified => "uncertified"
  | .trusted => "trusted    "

structure Ctx where
  M : Model
  G : Graph
  T : Nat
  dist : Array Nat
  distOk : Bool
  moves : Array String
  names : Array String

def Ctx.n (c : Ctx) : Nat := c.G.size

/-- writ's route as (move index, landing) pairs; `none` if malformed. -/
def Ctx.route (c : Ctx) (r : Array (String × Option Nat)) : Option (List (Nat × Nat)) :=
  r.toList.mapM fun (mv, to) => do
    let t ← c.moves.findIdx? (· == mv)
    let j ← to
    pure (t, j)

def Ctx.replay (c : Ctx) (r : Array (String × Option Nat)) : Option (Nat × Nat) := do
  let rt ← c.route r
  if routeOK c.G 0 rt then some (routeEnd 0 rt, rt.length) else none

/-- `Writ.nearest`'s premise: no situation passing `pred` is nearer than `k`. -/
def Ctx.nearestOK (c : Ctx) (pred : Nat → Bool) (k len : Nat) : Bool :=
  c.distOk && c.dist.getD k 0 == len &&
  allBelow c.n fun j => !pred j || decide (c.dist.getD k 0 ≤ c.dist.getD j 0)

def Ctx.name (c : Ctx) (i : Nat) : String := c.names.getD i s!"?{i}"

def Ctx.out (c : Ctx) : Out → String
  | .absent => "absent"
  | .gap m => s!"a gap \"{c.name m}\""
  | .to j => s!"→ #{j}"

def Ctx.outcome (c : Ctx) (G : Graph) : Outcome → String
  | .absent => "absent"
  | .gap m => s!"a gap \"{c.name m}\""
  | .next s =>
    match (List.range G.size).find? (G.st · == s) with
    | some j => s!"→ #{j}"
    | none => "→ a situation writ did not list"

/-- The first cell where the table and the semantics disagree. -/
def graphFault (M : Model) (G : Graph) (c : Ctx) : String := Id.run do
  if G.size == 0 then return "the certificate lists no situations"
  if G.st 0 != M.init then return "situation #0 is not the initial situation"
  for i in [0:G.size] do
    if (G.row i).size != M.transitions.length then
      return s!"situation #{i} has {(G.row i).size} moves in its row, the model has {M.transitions.length}"
    for t in [0:M.transitions.length] do
      if !outOK M G i t then
        return s!"at situation #{i}, move {c.moves.getD t "?"}: writ says {c.out (G.cell i t)}, the semantics says {c.outcome G (step M (G.st i) t)}"
  for i in [1:G.size] do
    if G.par i ≥ i then
      return s!"situation #{i} has no edge into it from an earlier situation: writ's numbering is not breadth-first"
  return "unknown"

def describe (c : Ctx) : Cert → String
  | .possibleHolds i => s!"satisfied at #{i}"
  | .possibleFails => s!"no satisfying situation among {c.n}"
  | .neverHolds => s!"no situation of {c.n} satisfies it"
  | .neverFails i => s!"satisfied at #{i}"
  | .liveHolds rank =>
    s!"every situation within {rank.foldl max 0} moves of F"
  | .liveFails k closed =>
    s!"#{k} is in a closed, F-free set of {(closed.filter id).size}"
  | .inevitableHolds rounds _ =>
    if rounds.isEmpty then "every run falls by rank into F"
    else s!"{rounds.length} fairness round(s), then every run falls by rank into F"
  | .inevitableStopped k => s!"#{k} stops outside F"
  | .inevitableLasso cyc _ => s!"a fair F-free cycle of {cyc.size} move(s) through #{cyc.getD 0 0}"

def checkProperty (c : Ctx) (p : WProp) : Line :=
  let what := s!"{p.verdict.pushn ' ' (6 - p.verdict.length)} {p.name}"
  if !p.applicable then
    ⟨if p.verdict == "n/a" then .trusted else .disagrees, what,
     "n/a — names structure the schema lacks; nothing to evaluate"⟩
  else
    let F := p.prop.formula
    let replay := c.replay p.witness
    -- the situation writ's answer singles out
    let singled := match p.stuck with
      | some k => some k
      | none => replay.map (·.1)
    match certify c.M c.G p.prop singled with
    | none => ⟨.uncertified, what, "no certificate found"⟩
    | some cert =>
      if !checkCert c.M c.G p.prop cert then
        ⟨.uncertified, what, s!"the certificate found did not check ({describe c cert})"⟩
      else
        let mine := if cert.verdict then "holds" else "fails"
        if mine != p.verdict then
          ⟨.disagrees, what, s!"the property {mine}: {describe c cert}"⟩
        else
          let sat := c.G.sat c.M F
          let w : Except String String :=
            if p.witness.isEmpty then
              match p.prop.modality, cert.verdict with
              | .possible, true | .never, false | .live, false | .inevitable _, false =>
                if p.stuck == some 0 || (p.stuck.isNone && (sat 0)) then .ok "at the initial situation"
                else .error "writ printed no witness where one is due"
              | _, _ => .ok ""
            else
              match replay with
              | none => .error "writ's witness is not a route of the model"
              | some (k, len) =>
                match p.prop.modality, p.stuck with
                | .possible, _ | .never, _ =>
                  if !sat k then .error s!"writ's witness ends at #{k}, which does not satisfy the formula"
                  else if !c.nearestOK sat k len then
                    .error s!"writ's witness ({len} moves) is not a shortest route to the formula"
                  else .ok s!"witness: a shortest route, {len} moves"
                | _, some s =>
                  if k != s then .error s!"writ's witness ends at #{k}, not at #{s}"
                  else if !c.nearestOK (· == s) s len then
                    .error s!"writ's witness ({len} moves) is not a shortest route to #{s}"
                  else .ok s!"witness: a shortest route to #{s}, {len} moves"
                | _, none => .error "writ's witness has nowhere to lead"
          match w with
          | .error e => ⟨.disagrees, what, e⟩
          | .ok wd =>
            ⟨.certified, what, describe c cert ++ (if wd.isEmpty then "" else s!"; {wd}")⟩

def checkEquation (c : Ctx) (e : WEquation) : Line :=
  let bad := fun i => !eqHolds c.M (c.G.st i) e.eq
  let viol := (List.range c.n).filter bad
  let what := s!"law   {e.name}"
  match e.violated with
  | none =>
    if viol.isEmpty then ⟨.certified, what, "never violated"⟩
    else ⟨.disagrees, what, s!"violated at {viol.length} situation(s), first #{viol.head!}"⟩
  | some (count, w) =>
    if count != viol.length then
      ⟨.disagrees, what, s!"writ counts {count} violating situation(s), there are {viol.length}"⟩
    else match c.replay w with
      | none => ⟨.disagrees, what, "writ's witness is not a route of the model"⟩
      | some (k, len) =>
        if !bad k then ⟨.disagrees, what, s!"writ's witness ends at #{k}, which does not violate it"⟩
        else if !c.nearestOK bad k len then
          ⟨.disagrees, what, s!"writ's witness ({len} moves) is not a shortest route to a violation"⟩
        else ⟨.certified, what, s!"violated at {count}; witness: a shortest route, {len} moves"⟩

structure Result where
  writ : String
  lines : Array Line

def Result.worst (r : Result) : Status :=
  if r.lines.any (·.status == .disagrees) then .disagrees
  else if r.lines.any (·.status == .uncertified) then .uncertified
  else .certified

def verify (C : Certificate) : Result := Id.run do
  let M := C.model
  let T := M.transitions.length
  -- Numbered in writ's breadth-first order, so witness indices can be checked.
  let G ← match explore M with
    | .ok G => pure G
    | .error e => return { writ := C.writ, lines := #[⟨.uncertified, "space", e⟩] }
  let (dist, _) := bfs G T
  let c : Ctx := { M, G, T, dist, distOk := distOK M G dist, moves := C.moves, names := C.names }
  let mut lines : Array Line := #[]
  if !checkGraph M G then
    lines := lines.push ⟨.uncertified, "space", s!"the explored graph did not check: {graphFault M G c}"⟩
    return { writ := C.writ, lines }
  let (ord, inv) := sortCert G
  let distinctOk := distinctOK G ord inv
  let n := G.size
  let edges := (List.range n).foldl (fun acc i =>
    acc + ((List.range T).filter fun t => G.cell i t != .absent).length) 0
  -- size (§15)
  lines := lines.push <|
    if !distinctOk then ⟨.uncertified, "states", "the listed situations are not pairwise distinct"⟩
    else if C.reportStates != n then
      ⟨.disagrees, "states", s!"writ reports {C.reportStates}; there are {n} reachable situations"⟩
    else ⟨.certified, "states", s!"{n} — exactly the reachable situations, pairwise distinct"⟩
  lines := lines.push <|
    if C.reportEdges != edges then
      ⟨.disagrees, "edges", s!"writ reports {C.reportEdges}; the table has {edges}"⟩
    else ⟨.certified, "edges", s!"{edges} — every move at every situation, as the semantics gives it"⟩
  -- dead ends
  let dead := (List.range n).filter fun i => (List.range T).all fun t => G.cell i t == .absent
  let writDead := C.deadEnds.toList.mergeSort (· ≤ ·)
  lines := lines.push <|
    if dead != writDead then
      ⟨.disagrees, "dead ends", s!"writ lists {writDead.length}; there are {dead.length}: {dead.take 5}"⟩
    else ⟨.certified, "dead ends", if dead.isEmpty then "none" else s!"{dead.length}"⟩
  -- gaps: one per (move, message) site, at its fewest moves
  let mut sites : Array (String × String × Nat) := #[]
  for i in [0:n] do
    for t in [0:T] do
      if let .gap m := G.cell i t then
        let key := (C.moves.getD t "?", c.name m)
        let d := dist.getD i 0
        match sites.findIdx? (fun s => (s.1, s.2.1) == key) with
        | some k => if d < sites[k]!.2.2 then sites := sites.set! k (key.1, key.2, d)
        | none => sites := sites.push (key.1, key.2, d)
  let norm := fun (a : Array (String × String × Nat)) =>
    (a.toList.map fun (mv, msg, d) => s!"{mv}\x00{msg}\x00{d}").mergeSort (· ≤ ·)
  lines := lines.push <|
    if norm sites != norm C.gaps then
      ⟨.disagrees, "gaps", s!"writ lists {C.gaps.size} gap site(s); there are {sites.size}"⟩
    else ⟨.certified, "gaps", if sites.isEmpty then "none" else s!"{sites.size} site(s), each at its fewest moves"⟩
  for e in C.equations do
    lines := lines.push (checkEquation c e)
  for p in C.props do
    lines := lines.push (checkProperty c p)
  return { writ := C.writ, lines }

end Writ.Verify
