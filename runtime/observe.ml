(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Equation observation (kernel §8, §15, §16.3). [can_break] is a sound
   static test: a move can break a law iff it writes an arrow the law reads.
   [laws] is the claims-agnostic §15 finding; [unadmitted] and [stale] compare
   breakers against the claims' [accept]s (§16.3). *)

let last_step (p : Value.path) : string option =
  match List.rev p.steps with [] -> None | x :: _ -> Some x

let can_break (tr : Model.transition) (eq : Schema.equation) : bool =
  let written =
    List.filter_map
      (function
        | Model.Set (p, _) -> last_step p
        | Model.Vacate p -> last_step p
        | Model.Gap _ -> None)
      tr.effects
  in
  (* Every arrow any chain of the law walks, regardless of [some] scope. *)
  let used = Guard.arrows eq.Schema.body in
  List.exists (fun w -> List.mem w used) written

let tr_name (tr : Model.transition) : string =
  match tr.name with Some n -> n | None -> ""

(* Per-equation §15 finding: the breakers, and the reachable violation if
   any. *)
type law = {
  name : string;
  breakers : string list;
  violation : (int * string list) option;
}

let laws (sp : Space.t) : law list =
  let ctx = sp.Space.ctx in
  let eqs = ctx.State.schema.equations in
  let trs = sp.Space.transitions in
  List.filter_map
    (fun (eq : Schema.equation) ->
      let breakers =
        List.filter_map
          (fun tr -> if can_break tr eq then Some (tr_name tr) else None)
          trs
      in
      let count = ref 0 in
      let best = ref None in
      Array.iter
        (fun s ->
          if not (Eval.eq_holds ctx s eq) then begin
            incr count;
            match !best with
            | None -> best := Some s
            | Some b ->
                if State.M.find s sp.dist < State.M.find b sp.dist then
                  best := Some s
          end)
        sp.states;
      let violation =
        match !best with
        | Some s -> Some (!count, Space.shortest_path sp s)
        | None -> None
      in
      if breakers = [] && violation = None then None
      else Some { name = eq.name; breakers; violation })
    eqs

(* A can-break move with no matching [accept]: (transition, equation). *)
let unadmitted (sp : Space.t) (claims : Claims.t) : (string * string) list =
  let ctx = sp.Space.ctx in
  let eqs = ctx.State.schema.equations in
  let trs = sp.Space.transitions in
  let accepts = claims.Claims.accepts in
  List.concat_map
    (fun tr ->
      List.filter_map
        (fun (eq : Schema.equation) ->
          if
            can_break tr eq
            && not
                 (List.exists
                    (fun (a : Claims.accept) ->
                      a.tr = tr_name tr && a.eq = eq.name)
                    accepts)
          then Some (tr_name tr, eq.name)
          else None)
        eqs)
    trs

(* An [accept] naming a move that cannot break the law: (transition, equation). *)
let stale (sp : Space.t) (claims : Claims.t) : (string * string) list =
  let ctx = sp.Space.ctx in
  let eqs = ctx.State.schema.equations in
  let trs = sp.Space.transitions in
  List.filter_map
    (fun (a : Claims.accept) ->
      match
        ( List.find_opt (fun tr -> tr_name tr = a.tr) trs,
          List.find_opt (fun (eq : Schema.equation) -> eq.name = a.eq) eqs )
      with
      | Some tr, Some eq -> if can_break tr eq then None else Some (a.tr, a.eq)
      | _ -> None)
    claims.Claims.accepts
