(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* A route, read back as the situations it passes through. The checker answers
   with a witness as a list of MOVE NAMES, which is what a reader wants to
   quote; the rest of the tool addresses situations by INDEX, which is what a
   reader wants to follow. This is the seam between the two: replay a route
   from the initial situation and say where each move lands.

   Replay rather than record, deliberately. The BFS tree already knows the
   state behind every witness, but the checker's outcome type carries only
   the names, and widening it would touch every consumer for a fact that is
   cheap to recover: one edge scan per step, on a route a few moves long. *)

(* The index after each move of [route], in order. A route that cannot be
   replayed — a name no edge at that situation carries — stops where it fails,
   so the answer is a prefix rather than a lie. *)
let walk (sp : Space.t) (route : string list) : int list =
  let step cur mv =
    List.find_map
      (fun (e : Space.edge) ->
        match e.Space.dst with
        | `To d when Space.same e.Space.src cur && String.equal e.Space.via mv
          ->
            Some d
        | _ -> None)
      sp.Space.edges
  in
  let rec go cur acc = function
    | [] -> List.rev acc
    | mv :: rest -> (
        match step cur mv with
        | Some d -> go d (State.M.find d sp.Space.index :: acc) rest
        | None -> List.rev acc)
  in
  go sp.Space.initial [] route

(* The cells on which two situations differ: [(src.arrow, before, after)] in
   layout order, a vacant cell as [None]. What a move DID, in the model's own
   vocabulary — and since the names are the author's, the domain's. *)
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
