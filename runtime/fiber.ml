(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Fiber reporting (kernel §17). A fiber is the set of reachable situations in
   which a cell — spelled [SRC.ARROW] — holds one value; several cells give the
   product. Each property is asked of every fiber with the dynamics left whole,
   so the report says in which mode a guarantee fails. *)

type fiber = { cells : (string * int) list; values : string list }
(** the cells by name and layout index, and one value per cell *)

let cell_index (sp : Space.t) (spelling : string) : (string * int) option =
  let cells = sp.Space.ctx.State.layout.State.cells in
  let n = Array.length cells in
  let rec go i =
    if i >= n then None
    else
      let cr = cells.(i) in
      if cr.Instance.src ^ "." ^ cr.Instance.arrow = spelling then
        Some (spelling, i)
      else go (i + 1)
  in
  go 0

let value_text = function Value.Filled v -> v | Value.Vacant -> "∅"

(* The values a cell takes, in BFS order of first appearance, so the initial
   situation's value leads. *)
let values_of (sp : Space.t) (i : int) : string list =
  let seen = ref [] in
  Array.iter
    (fun s ->
      let v = value_text s.(i) in
      if not (List.mem v !seen) then seen := v :: !seen)
    sp.Space.states;
  List.rev !seen

(* Every fiber of the product of the named cells, each with its predicate. *)
let fibers (sp : Space.t) (cells : (string * int) list) :
    (fiber * (State.t -> bool)) list =
  let rec product = function
    | [] -> [ [] ]
    | (name, i) :: rest ->
        List.concat_map
          (fun v -> List.map (fun tail -> (name, i, v) :: tail) (product rest))
          (values_of sp i)
  in
  List.map
    (fun combo ->
      let fiber =
        {
          cells = List.map (fun (n, i, _) -> (n, i)) combo;
          values = List.map (fun (_, _, v) -> v) combo;
        }
      in
      let within (s : State.t) =
        List.for_all (fun (_, i, v) -> value_text s.(i) = v) combo
      in
      (fiber, within))
    (product cells)

let label (f : fiber) : string =
  String.concat " " (List.map2 (fun (n, _) v -> n ^ "=" ^ v) f.cells f.values)

(* One property, asked of every fiber. *)
let outcomes (sp : Space.t) (cells : (string * int) list)
    (prop : Claims.property) : (fiber * Checker.outcome) list =
  List.map
    (fun (f, within) -> (f, Checker.check ~within sp prop))
    (fibers sp cells)
