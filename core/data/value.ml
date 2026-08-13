(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Cells and literal paths — the leaf datum every layer speaks in.

   A cell is the value an arrow takes at a source entity: a filled scalar or the
   absence of one. A path is a literal route [root.a1.…an] through the schema,
   written out (no closure operator, kernel §0.2). *)

type cell = Filled of string | Vacant
type path = { root : string; steps : string list }

(* A total order on cells: [Vacant] sorts before every [Filled], and filled
   cells compare by their string. Explicit (not polymorphic [compare]) so the
   ordering is stable and independent of the constructors' runtime tags. *)
let compare_cell (a : cell) (b : cell) : int =
  match (a, b) with
  | Vacant, Vacant -> 0
  | Vacant, Filled _ -> -1
  | Filled _, Vacant -> 1
  | Filled x, Filled y -> String.compare x y

let equal_cell (a : cell) (b : cell) : bool = compare_cell a b = 0

(* A total order on cell arrays — the key State.M is built on. Shorter arrays
   sort first; equal-length arrays compare lexicographically by cell. *)
let compare_cells (a : cell array) (b : cell array) : int =
  let la = Array.length a and lb = Array.length b in
  if la <> lb then Int.compare la lb
  else
    let rec go i =
      if i >= la then 0
      else
        let c = compare_cell a.(i) b.(i) in
        if c <> 0 then c else go (i + 1)
    in
    go 0

let compare_path (a : path) (b : path) : int =
  let c = String.compare a.root b.root in
  if c <> 0 then c else List.compare String.compare a.steps b.steps
