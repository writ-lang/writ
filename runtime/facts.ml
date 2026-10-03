(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Extension §2's built-in relations — the derived category as data.

   Every function is a read off [Space.t], never a second traversal, so the
   built-ins cannot disagree with the interrogator and a rule cannot add a
   situation, edge or cell (§5). A situation is its [Space.index] (§9). *)

let index (sp : Space.t) (s : State.t) : int option =
  State.M.find_opt s sp.Space.index

let state (sp : Space.t) (i : int) : State.t option =
  if i >= 0 && i < Array.length sp.Space.states then Some sp.Space.states.(i)
  else None

(* [(situation S)] — the reachable set, in BFS order. *)
let situations (sp : Space.t) : int list =
  List.init (Array.length sp.Space.states) Fun.id

(* [(init S)] — index 0 in practice, but looked up rather than assumed. *)
let init (sp : Space.t) : int option = index sp sp.Space.initial

(* [(edge E S1 S2)] — [`To] edges only; a [`Gap] answers [gap-edge]. *)
let edges (sp : Space.t) : (string * int * int) list =
  List.filter_map
    (fun (e : Space.edge) ->
      match e.Space.dst with
      | `To s' -> (
          match (index sp e.Space.src, index sp s') with
          | Some a, Some b -> Some (e.Space.via, a, b)
          | _ -> None)
      | `Gap _ -> None)
    sp.Space.edges

(* [(gap-edge E S)] — E fires at S with no successor. *)
let gap_edges (sp : Space.t) : (string * int) list =
  List.filter_map
    (fun (e : Space.edge) ->
      match e.Space.dst with
      | `Gap _ -> Option.map (fun a -> (e.Space.via, a)) (index sp e.Space.src)
      | `To _ -> None)
    sp.Space.edges

(* [(phase S P)] and [(phase-step P Q)] — the quotient by mutual reachability
   and its order, from one [Space.phases] run so the two cannot disagree. *)
let phases (sp : Space.t) : (int * int) list * (int * int) list =
  let comp, steps = Space.phases sp in
  (List.init (Array.length comp) (fun i -> (i, comp.(i))), steps)

(* [(holds S G)] — by the kernel's evaluator, so rules and `writ check` share
   one guard semantics. The environment is empty: [Rules.lower] has already
   substituted the rule's variables. *)
let holds (sp : Space.t) (i : int) (g : Model.guard) : bool =
  match state sp i with
  | None -> false
  | Some st -> Eval.guard_holds sp.Space.ctx st [] g

(* The value a path reads, or [None] if undefined. This makes a top-level
   [(is PATH V)] functional (§2). *)
let read (sp : Space.t) (i : int) (p : Value.path) : string option =
  match state sp i with
  | None -> None
  | Some st -> (
      match Eval.eval_path sp.Space.ctx st [] p with
      | Some (Value.Filled v) -> Some v
      | Some Value.Vacant | None -> None)

(* The domain an unbound path root enumerates (§2). Rules only ever generate
   over declared rosters, which keeps §6's cost bounded. *)
let entities (sp : Space.t) (ty : string) : string list =
  Eval.entities_of_type sp.Space.ctx ty
