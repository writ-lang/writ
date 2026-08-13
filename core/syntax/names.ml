(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* §7, *Names*: "Global names — types, entities, forms, equations. One namespace
   across the loaded universe; declaring an existing name is an error. There is
   no shadowing." Forms are already policed by [Forms.collect]; this module is
   the other three.

   Why here and not in [Decl]: §7 says *loaded universe*, and a duplicate that
   spans two files exists in neither of them alone. [Parser.collect_decls] is
   the first point where every declaration is in one list — after [Loader]
   inlines the loads (§6.2) and the expander has run — so it is the earliest
   place the rule can be stated at all.

   Why it matters more than a tidy diagnostic: without it, two declarations
   claim one name and the model still builds, so whichever the lookup happens to
   find decides what the model *means*, and the author is never told there was a
   choice. That is the failure §7 exists to prevent, and it is worse than an
   error because it is silent. §6.2's justification for idempotent loading leans
   on the same rule — "a repeated-name error always signals two *different*
   declarations claiming one name" is only worth saying if repeated names are
   errors at all. *)

(* Schema names are here because §8.1 puts them here — its one constraint is
   "NAME is fresh (§7)", which cites this namespace rather than a namespace of
   its own. So two [(schema m …)] declarations collide exactly as two types
   would, and a schema may not take a name a type holds either. Contrast §10.1,
   which says a transition NAME must be fresh and pointedly does *not* cite §7:
   that one is scoped to transitions and lives in [Parser]. *)
type kind = Type | Entity | Equation | Schema

let kind_name = function
  | Type -> "type"
  | Entity -> "entity"
  | Equation -> "equation"
  | Schema -> "schema"

let article = function Entity | Equation -> "an" | Type | Schema -> "a"

(* Which section put this name in the namespace — cited off the kind the author
   has just written, since that is the declaration they can act on. A schema's
   name is in here only because §8.1 sends it here, and saying "§7 gives types,
   entities, forms and equations one namespace" over a rejected `schema` would
   invite the reader to check §7 and find no schemas listed. *)
let cite = function
  | Schema -> "§8.1 requires a schema's name to be fresh in §7's one namespace"
  | Type | Entity | Equation ->
      "§7 gives types, entities, forms and equations one namespace across the \
       loaded universe"

(* A roster clause is [(TYPE e…)], all-atom; a valuation clause is
   [(ARROW (E V)…)], whose arguments are lists. Telling them apart needs the
   schema in [Decl], but syntactically the shape is enough, and working from
   the raw datums is what keeps a position on every name. [(of SCHEMA)] is
   neither and is skipped by name. *)
let roster_entities (clauses : Reader.t list) : (string * Errors.pos) list =
  List.concat_map
    (function
      | Reader.List (Reader.Atom ("of", _) :: _, _) -> []
      | Reader.List (Reader.Atom (_, _) :: args, _) when args <> [] ->
          (* An entity-major clause is (TYPE ENTITY… SLOT…): the LEADING RUN of
             atoms are the entities, and the lists after them are slots, not
             names. Demanding every arg be an atom — as this did while the only
             shape was a bare roster — silently skipped any clause carrying a
             slot, so its entities went unregistered and a binder could shadow
             one undetected. *)
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

(* Every globally-named declaration in the universe, in source order — so the
   *second* occurrence is the one blamed, which is what §7's own example asks
   for ("an error at the second declaration"). *)
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

(* A [some] binder names a variable scoped to its own guard body, so two
   transitions may each bind [b]: they are disjoint, and nothing in §7 makes a
   scoped name globally unique. Collecting them is not about uniqueness among
   themselves.

   What §7 does forbid is shadowing, and a binder is the one construct in the
   language that can shadow anything. [Eval.eval_path] resolves a chain root
   through the binding environment BEFORE the roster, so a binder spelled like
   an entity hides it and the model still builds — the same silent
   winner-picking this module was written to end, arriving by the one door it
   left open.

   Read off the raw datums for the module's usual reason: it keeps a position
   on every binder. A [.rules] file's binders are checked by
   [Rules_guard.binder] instead, which additionally rejects the ALL-CAPS
   spelling because there it would also read as a rule variable; in a model
   that spelling is merely unconventional, and is left alone. *)
let rec binders (d : Reader.t) : (string * Errors.pos) list =
  match d with
  | Reader.List
      ( Reader.Atom ("some", _)
        :: Reader.List ([ Reader.Atom (x, xp); Reader.Atom _ ], _)
        :: body,
        _ ) ->
      (x, xp) :: List.concat_map binders body
  (* A query's [(where (VAR TYPE)…)] binds the same way [some] does and shadows
     the same names (§16.2); it is listed separately only because it takes its
     binders as a run of clauses rather than one, so the generic descent below
     would walk straight past them into the atoms. *)
  | Reader.List (Reader.Atom ("where", _) :: bs, _) ->
      List.concat_map
        (function
          | Reader.List ([ Reader.Atom (x, xp); Reader.Atom _ ], _) ->
              [ (x, xp) ]
          | d -> binders d)
        bs
  | Reader.List (items, _) -> List.concat_map binders items
  | Reader.Atom _ -> []

(* The binder rule, over any way of asking whether a name is already taken.
   Two callers need it from opposite directions: a model is checked against the
   universe's raw datums, and a [.claims] file against the model those datums
   already built (§16). Factored so the rule is *stated* once — two copies of a
   shadowing check would be a second place for the two file types to drift. *)
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

(* The [taken] a [.claims] file needs: its universe is a built [Model.t], not a
   datum list, so the names come off the schema and the initial instance. Same
   four kinds [declared] collects, by construction — anything reachable here
   was put there by a declaration it already saw. *)
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
            (* Same kind twice reads better without restating it; a cross-kind
               collision has to name both, because "already declared" alone
               would send the author looking for another type when what they
               have is an entity. *)
            Errors.err ~pos:p
              (kind_name k ^ " `" ^ n ^ "` is already declared"
              ^ (if k = k0 then "" else " as " ^ article k0 ^ " " ^ kind_name k0)
              ^ " — " ^ cite k)
        | None ->
            Hashtbl.add seen n k;
            go rest)
  in
  (* Binders are checked only after every declaration is in [seen], so the
     collision is caught wherever the two happen to sit in the file. A binder
     is never *added* to [seen]: it holds its name for the length of a guard
     body, not the universe. *)
  match go (declared datums) with
  | Error _ as e -> e
  | Ok () -> check_binders (Hashtbl.find_opt seen) datums
