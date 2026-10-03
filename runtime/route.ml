(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* A route — move names, as the checker gives it — read back as the
   situation indices the rest of the tool addresses. *)

(* The index after each move of [route]. A route that cannot be replayed stops
   where it fails, so the answer is a prefix. Each step re-fires the named move
   rather than scanning the space's edges for it, which would be far slower on
   a large space. *)
let walk (sp : Space.t) (route : string list) : int list =
  let ctx = sp.Space.ctx in
  let labelled =
    List.mapi
      (fun i (tr : Model.transition) ->
        ( (match tr.Model.name with
          | Some n -> n
          | None -> "#" ^ string_of_int i),
          tr ))
      sp.Space.transitions
  in
  let step cur mv =
    match List.assoc_opt mv labelled with
    | Some tr when Eval.guard_holds ctx cur [] tr.Model.when_ -> (
        match Eval.apply ctx cur tr.Model.effects with
        | `Next d -> Some d
        | `Gap _ | `Blocked -> None)
    | _ -> None
  in
  let rec go cur acc = function
    | [] -> List.rev acc
    | mv :: rest -> (
        match step cur mv with
        | Some d -> (
            match State.M.find_opt d sp.Space.index with
            | Some i -> go d (i :: acc) rest
            | None -> List.rev acc)
        | None -> List.rev acc)
  in
  go sp.Space.initial [] route

(* The cells on which two situations differ, [(src.arrow, before, after)] in
   layout order, vacant as [None]. *)
let deltas (sp : Space.t) (a : State.t) (b : State.t) :
    (string * string option * string option) list =
  let cells = sp.Space.ctx.State.layout.State.cells in
  let value = function Value.Filled v -> Some v | Value.Vacant -> None in
  let out = ref [] in
  Array.iteri
    (fun i (cr : Instance.cellref) ->
      if not (Value.equal_cell a.(i) b.(i)) then
        out :=
          (cr.Instance.src ^ "." ^ cr.Instance.arrow, value a.(i), value b.(i))
          :: !out)
    cells;
  List.rev !out
