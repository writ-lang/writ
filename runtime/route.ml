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
   replayed — a name no move at that situation answers to — stops where it
   fails, so the answer is a prefix rather than a lie.

   Each step RE-FIRES the named move rather than looking its edge up. The two
   are the same answer — [Space.build] records exactly the moves that fire —
   but a lookup scanned every edge of the space per step, and a report routes
   to every dead end: 10 188 of them over 564 880 edges made `writ check
   --json` take five minutes on a space the prose report answers in forty
   seconds. Re-firing costs one guard and one move. *)
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
