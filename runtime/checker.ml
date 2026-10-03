(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* The four modalities, each with a BFS-shortest witness:
   - [never F] fails if F is reachable;
   - [possible F] holds if F is reachable, carrying the path as the solution
     (spec Appendix C);
   - [live F] is [AG EF F] over real edges, gap exits being non-F terminals;
   - [inevitable F] is [AG AF F] over maximal runs, and implies [live F].
   [Not_applicable] when F names schema structure that does not exist. A
   failing [live]/[inevitable] also carries the stuck state. *)

type outcome =
  | Holds of string list
  | Fails of { route : string list; stuck : State.t option }
  | Not_applicable of string

(* The type heading a path's root: a [some]-bound variable's type, or the
   type whose roster holds the entity. *)
let root_type (ctx : State.ctx) (env : (string * string) list) (root : string) :
    string option =
  match List.assoc_opt root env with
  | Some ty -> Some ty
  | None ->
      List.find_map
        (fun (r : Instance.roster) ->
          if List.mem root r.entities then Some r.ty else None)
        ctx.rosters

(* The path's final cod type, or [None] if a step names a missing arrow. *)
let path_cod (ctx : State.ctx) (env : (string * string) list) (p : Value.path) :
    string option =
  match root_type ctx env p.root with
  | None -> None
  | Some ty ->
      let rec walk cur = function
        | [] -> Some cur
        | step :: rest -> (
            match Schema.arrow_in ctx.schema ~dom:cur step with
            | Some a -> walk a.cod rest
            | None -> None)
      in
      walk ty p.steps

(* An enumerated value of [ty], or an entity of its roster. *)
let value_in_type (ctx : State.ctx) (ty : string) (v : string) : bool =
  match Schema.type_of ctx.schema ty with
  | Some { flavor = Enumerated vs; _ } -> List.mem v vs
  | Some { flavor = Open; _ } ->
      List.exists
        (fun (r : Instance.roster) -> r.ty = ty && List.mem v r.entities)
        ctx.rosters
  | None -> false

(* Applicable iff every path resolves and every named type and compared value
   exists; otherwise the property is n/a. *)
let rec guard_ok (ctx : State.ctx) (env : (string * string) list)
    (g : Model.guard) : bool =
  match g with
  | Model.And gs | Model.Or gs -> List.for_all (guard_ok ctx env) gs
  | Model.Not g -> guard_ok ctx env g
  | Model.Is (p, r) -> (
      match (path_cod ctx env p, r) with
      | Some ty, Model.Lit v -> value_in_type ctx ty v
      | Some ty, Model.Chain q -> path_cod ctx env q = Some ty
      | None, _ -> false)
  | Model.Defined p -> path_cod ctx env p <> None
  | Model.Some_ (x, ty, g) -> (
      match Schema.type_of ctx.schema ty with
      | None -> false
      | Some _ -> guard_ok ctx ((x, ty) :: env) g)

(* The reachable state satisfying [pred] at the least BFS distance, if any. *)
let nearest (sp : Space.t) (pred : State.t -> bool) : State.t option =
  let best = ref None in
  Array.iter
    (fun s ->
      if pred s then
        match !best with
        | None -> best := Some s
        | Some b ->
            let ds = State.M.find s sp.dist and db = State.M.find b sp.dist in
            if ds < db then best := Some s)
    sp.states;
  !best

(* [within] narrows which situations the question is about (§17's fiber), not
   the dynamics: each of those must still reach F through any moves. *)
let check ?(within : State.t -> bool = fun _ -> true) (sp : Space.t)
    (prop : Claims.property) : outcome =
  let ctx = sp.Space.ctx in
  if not (guard_ok ctx [] prop.formula) then
    Not_applicable ("schema lacks structure named by " ^ prop.name)
  else
    let sat s = Eval.guard_holds ctx s [] prop.formula in
    let nearest sp pred = nearest sp (fun s -> within s && pred s) in
    match prop.modality with
    | Claims.Possible -> (
        match nearest sp sat with
        | Some s -> Holds (Space.shortest_path sp s)
        | None -> Fails { route = []; stuck = None })
    | Claims.Never -> (
        match nearest sp sat with
        | Some s -> Fails { route = Space.shortest_path sp s; stuck = None }
        | None -> Holds [])
    | Claims.Live -> (
        let can = Space.bwd_reach sp sat in
        let cannot s =
          match State.M.find_opt s sp.index with
          | Some i -> not can.(i)
          | None -> false
        in
        match nearest sp cannot with
        | None -> Holds []
        | Some s -> Fails { route = Space.shortest_path sp s; stuck = Some s })
    | Claims.Inevitable fair -> (
        let known =
          List.filter_map (fun (t : Model.transition) -> t.name) sp.transitions
        in
        match List.find_opt (fun m -> not (List.mem m known)) fair with
        | Some m ->
            (* A move that does not exist makes the question n/a. *)
            Not_applicable ("model has no move named " ^ m)
        | None -> (
            let esc = Space.escapes_f ~fair sp sat in
            let escapes s =
              match State.M.find_opt s sp.index with
              | Some i -> esc.(i)
              | None -> false
            in
            match nearest sp escapes with
            | None -> Holds []
            | Some s ->
                Fails { route = Space.shortest_path sp s; stuck = Some s }))
