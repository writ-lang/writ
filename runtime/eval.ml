(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Kleene evaluation over a state (kernel §3, §4). A path evaluates to a
   [Value.cell option], [None] when it steps off a vacant cell — partiality
   propagates. Guards use the usual connectives, [some] scanning a roster.
   Applying effects yields the next state, a gap, or [`Blocked]. No I/O. *)

type env = (string * string) list

(* An enumerated type's values, or an open type's roster entities. *)
let entities_of_type (ctx : State.ctx) (ty : string) : string list =
  match Schema.type_of ctx.schema ty with
  | Some { flavor = Enumerated vs; _ } -> vs
  | Some { flavor = Open; _ } ->
      List.concat_map
        (fun (r : Instance.roster) -> if r.ty = ty then r.entities else [])
        ctx.rosters
  | None -> []

(* Walk a path over a state. The root is a bound variable or an entity; each
   step follows a cell. A vacant cell makes the path undefined; no steps means
   the root itself. *)
let eval_path (ctx : State.ctx) (st : State.t) (env : env) (p : Value.path) :
    Value.cell option =
  let root =
    match List.assoc_opt p.root env with Some e -> e | None -> p.root
  in
  let rec walk cur = function
    | [] -> Some (Value.Filled cur)
    | step :: rest -> (
        match State.get ctx st { Instance.arrow = step; src = cur } with
        | Value.Vacant -> None
        | Value.Filled v -> walk v rest)
  in
  walk root p.steps

let rec guard_holds (ctx : State.ctx) (st : State.t) (env : env)
    (g : Model.guard) : bool =
  match g with
  | Model.And gs -> List.for_all (guard_holds ctx st env) gs
  | Model.Or gs -> List.exists (guard_holds ctx st env) gs
  | Model.Not g -> not (guard_holds ctx st env g)
  (* Strict on both sides (§10.2): the chain has an answer and it equals V.
     The Kleene reading belongs to the stdlib's `=`. *)
  | Model.Is (p, r) -> (
      match eval_path ctx st env p with
      | Some (Value.Filled x) -> (
          match r with
          | Model.Lit v -> String.equal x v
          | Model.Chain q -> (
              match eval_path ctx st env q with
              | Some (Value.Filled y) -> String.equal x y
              | _ -> false))
      | _ -> false)
  | Model.Defined p -> (
      match eval_path ctx st env p with
      | Some (Value.Filled _) -> true
      | _ -> false)
  | Model.Some_ (x, ty, g) ->
      List.exists
        (fun e -> guard_holds ctx st ((x, e) :: env) g)
        (entities_of_type ctx ty)

(* Which cell a path names, as a slot in the state vector. Kept apart from
   writing so targets resolve in the starting situation (§10.1). [None] — a
   no-op effect (§10.3) — for a rootless path, an undefined prefix, or a cell
   outside the layout. *)
let target_index (ctx : State.ctx) (st : State.t) (p : Value.path) : int option
    =
  match List.rev p.steps with
  | [] -> None
  | last :: rev_prefix -> (
      let prefix = { p with steps = List.rev rev_prefix } in
      match eval_path ctx st [] prefix with
      | Some (Value.Filled src) ->
          State.index_of ctx { Instance.arrow = last; src }
      | _ -> None)

(* Apply a move in two phases (§10.1, §10.3). Phase 1 resolves both sides of
   every effect against the starting situation, so a [do] block is a
   simultaneous assignment ([(do (set a.x b.y) (set b.y a.x))] swaps).

   A chain with no answer makes the move [`Blocked] — not a vacate (§8.3
   forbids that) and not a self-loop, which would hide a dead end. [`Blocked]
   outranks [`Gap]. *)
let apply (ctx : State.ctx) (st : State.t) (effects : Model.effect list) :
    [ `Next of State.t | `Gap of string | `Blocked ] =
  let read = function
    | Model.Lit v -> Some v
    | Model.Chain p -> (
        match eval_path ctx st [] p with
        | Some (Value.Filled v) -> Some v
        | Some Value.Vacant | None -> None)
  in
  (* Phase 1. A target naming no cell is a no-op (§10.3) and drops out. *)
  let rec resolve acc = function
    | [] -> Ok (List.rev acc)
    | Model.Set (p, r) :: rest -> (
        match read r with
        | None -> Error `Blocked
        | Some v -> (
            match target_index ctx st p with
            | Some i -> resolve (`Write (i, Value.Filled v) :: acc) rest
            | None -> resolve acc rest))
    | Model.Vacate p :: rest -> (
        match target_index ctx st p with
        | Some i -> resolve (`Write (i, Value.Vacant) :: acc) rest
        | None -> resolve acc rest)
    | Model.Gap msg :: rest -> resolve (`Gap msg :: acc) rest
  in
  match resolve [] effects with
  | Error `Blocked -> `Blocked
  | Ok resolved -> (
      match List.find_opt (function `Gap _ -> true | _ -> false) resolved with
      | Some (`Gap msg) -> `Gap msg
      | _ ->
          (* Phase 2: the writes. *)
          `Next
            (List.fold_left
               (fun st -> function
                 | `Write (i, cell) -> State.set st i cell | `Gap _ -> st)
               st resolved))

(* A law is a guard over its single free root (§8.6): it must hold with the
   root bound to each entity of that type. Strictness is whatever the guard
   says; `=` in the stdlib spells out the Kleene reading. *)
let eq_holds (ctx : State.ctx) (st : State.t) (eq : Schema.equation) : bool =
  match Guard.free_roots eq.Schema.body with
  | [ root ] ->
      List.for_all
        (fun e -> guard_holds ctx st [ (root, e) ] eq.Schema.body)
        (entities_of_type ctx root)
  (* Rejected at declaration, so unreachable; holds rather than crash. *)
  | _ -> true
