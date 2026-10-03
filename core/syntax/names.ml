(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* §7: one global namespace across the loaded universe, and no shadowing.
   Runs on the inlined datums, since a duplicate may span files. Forms are
   checked by [Forms.collect]. *)

(* Schema names join via §8.1; transition names are [Parser]'s (§10.1). *)
type kind = Type | Entity | Equation | Schema

let kind_name = function
  | Type -> "type"
  | Entity -> "entity"
  | Equation -> "equation"
  | Schema -> "schema"

let article = function Entity | Equation -> "an" | Type | Schema -> "a"

(* The section that put this kind of name in the namespace. *)
let cite = function
  | Schema -> "§8.1 requires a schema's name to be fresh in §7's one namespace"
  | Type | Entity | Equation ->
      "§7 gives types, entities, forms and equations one namespace across the \
       loaded universe"

(* Entity names, with positions, from an instance's clauses. *)
let roster_entities (clauses : Reader.t list) : (string * Errors.pos) list =
  List.concat_map
    (function
      | Reader.List (Reader.Atom ("of", _) :: _, _) -> []
      | Reader.List (Reader.Atom (_, _) :: args, _) when args <> [] ->
          (* (TYPE ENTITY… SLOT…): only the leading atoms are entities. *)
          let rec leading acc = function
            | Reader.Atom (e, p) :: rest -> leading ((e, p) :: acc) rest
            | _ -> List.rev acc
          in
          leading [] args
      | _ -> [])
    clauses

let schema_names (clauses : Reader.t list) : (string * kind * Errors.pos) list =
  List.filter_map
    (function
      | Reader.List ([ Reader.Atom ("type", _); Reader.Atom (n, p) ], _)
      | Reader.List (Reader.Atom ("type", _) :: Reader.Atom (n, p) :: _, _) ->
          Some (n, Type, p)
      | Reader.List (Reader.Atom ("equation", _) :: Reader.Atom (n, p) :: _, _)
        ->
          Some (n, Equation, p)
      | _ -> None)
    clauses

(* Every global declaration, in source order, so the second occurrence is
   blamed (§7). *)
let declared (datums : Reader.t list) : (string * kind * Errors.pos) list =
  List.concat_map
    (function
      | Reader.List
          (Reader.Atom ("schema", _) :: Reader.Atom (n, p) :: clauses, _) ->
          (n, Schema, p) :: schema_names clauses
      | Reader.List (Reader.Atom ("instance", _) :: _ :: clauses, _) ->
          List.map (fun (e, p) -> (e, Entity, p)) (roster_entities clauses)
      | _ -> [])
    datums

(* Every [some] binder. Binders may share names but not shadow a global, which
   [Eval.eval_path] would silently prefer. *)
let rec binders (d : Reader.t) : (string * Errors.pos) list =
  match d with
  | Reader.List
      ( Reader.Atom ("some", _)
        :: Reader.List ([ Reader.Atom (x, xp); Reader.Atom _ ], _)
        :: body,
        _ ) ->
      (x, xp) :: List.concat_map binders body
  (* A query's [(where (VAR TYPE)…)] binds like [some] (§16.2), but takes a run
     of binders. *)
  | Reader.List (Reader.Atom ("where", _) :: bs, _) ->
      List.concat_map
        (function
          | Reader.List ([ Reader.Atom (x, xp); Reader.Atom _ ], _) ->
              [ (x, xp) ]
          | d -> binders d)
        bs
  | Reader.List (items, _) -> List.concat_map binders items
  | Reader.Atom _ -> []

(* The binder rule, parameterised by [taken]: a model checks against its raw
   datums, a [.claims] file against the built model (§16). *)
let check_binders (taken : string -> kind option) (datums : Reader.t list) :
    (unit, Errors.t) result =
  let rec go = function
    | [] -> Ok ()
    | (n, p) :: rest -> (
        match taken n with
        | Some k0 ->
            Errors.err ~pos:p
              ("binder `" ^ n ^ "` shadows " ^ article k0 ^ " " ^ kind_name k0
             ^ " of the same name — §7 gives types, entities, forms and \
                equations one namespace, and there is no shadowing")
        | None -> go rest)
  in
  go (List.concat_map binders datums)

(* [taken] for a [.claims] file: the names of a built schema and instance. *)
let taken_in (s : Schema.t) (i : Instance.t) (n : string) : kind option =
  if s.Schema.name = n then Some Schema
  else if List.exists (fun (t : Schema.ty) -> t.Schema.name = n) s.Schema.types
  then Some Type
  else if
    List.exists
      (fun (e : Schema.equation) -> e.Schema.name = n)
      s.Schema.equations
  then Some Equation
  else if
    List.exists
      (fun (r : Instance.roster) -> List.mem n r.Instance.entities)
      i.Instance.rosters
  then Some Entity
  else None

let check (datums : Reader.t list) : (unit, Errors.t) result =
  let seen = Hashtbl.create 64 in
  let rec go = function
    | [] -> Ok ()
    | (n, k, p) :: rest -> (
        match Hashtbl.find_opt seen n with
        | Some k0 ->
            (* A cross-kind collision names both kinds. *)
            Errors.err ~pos:p
              (kind_name k ^ " `" ^ n ^ "` is already declared"
              ^ (if k = k0 then "" else " as " ^ article k0 ^ " " ^ kind_name k0)
              ^ " — " ^ cite k)
        | None ->
            Hashtbl.add seen n k;
            go rest)
  in
  (* Binders are checked after all declarations are seen, and never added:
     they are scoped to a guard body. *)
  match go (declared datums) with
  | Error _ as e -> e
  | Ok () -> check_binders (Hashtbl.find_opt seen) datums
