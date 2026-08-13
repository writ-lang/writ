(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Pol_data

(* Model / library datums -> Schema / Instance / Model. A library is a bag of
   declarations (schemas, instances; forms are expanded away before parsing); a
   model additionally has exactly one [(use SCHEMA)], one [(initial INSTANCE)],
   and its transitions. Schema and instance decoding live in [Decl]; this module
   orchestrates and decodes the dynamics. Every guard/effect path is type-checked
   against the schema (fold F3) with an env mapping each instance entity to its
   type, plus any [some]-bound variables. *)

type decls = {
  schemas : Schema.t list;
  instances : Instance.t list;
  forms : Forms.form_def list;
}

let ( let* ) = Result.bind

let rec map_r f = function
  | [] -> Ok []
  | x :: xs ->
      let* y = f x in
      let* ys = map_r f xs in
      Ok (y :: ys)

let rec iter_r f = function
  | [] -> Ok ()
  | x :: xs ->
      let* () = f x in
      iter_r f xs

let head_str = function
  | Reader.List (Reader.Atom (h, _) :: _, _) -> h
  | Reader.List (_, _) -> "(…)"
  | Reader.Atom (s, _) -> s

(* The env a transition/formula path is checked in: each roster entity mapped to
   its type. [some] extends this in [Grammar.check_guard]. *)
let env_of_instance (i : Instance.t) : Grammar.env =
  List.concat_map
    (fun (r : Instance.roster) ->
      List.map (fun e -> (e, r.Instance.ty)) r.Instance.entities)
    i.Instance.rosters

let collect_decls (datums : Reader.t list) : (decls, Errors.t) result =
  let* () = Names.check datums in
  let* schemas =
    map_r Decl.decode_schema
      (List.filter
         (function
           | Reader.List (Reader.Atom ("schema", _) :: _, _) -> true
           | _ -> false)
         datums)
  in
  let* instances =
    map_r
      (Decl.decode_instance schemas)
      (List.filter
         (function
           | Reader.List (Reader.Atom ("instance", _) :: _, _) -> true
           | _ -> false)
         datums)
  in
  Ok { schemas; instances; forms = [] }

let parse_library (datums : Reader.t list) : (decls, Errors.t) result =
  collect_decls datums

(* [(transition [NAME] (when GUARD) (do EFFECT…))] — NAME optional. *)
let decode_transition (schema : Schema.t) (env : Grammar.env) (d : Reader.t) :
    (Model.transition, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom ("transition", _) :: rest, dp) ->
      let name, clauses =
        match rest with
        | Reader.Atom (n, _) :: cs -> (Some n, cs)
        | cs -> (None, cs)
      in
      (* §10.1: "exactly one `when`, exactly one `do`". [List.find_map] silently
         took the first of each, so a second clause was *discarded* — a false
         first guard beside a true second one gave a move that exists nowhere,
         and a second [do] dropped every effect in it. Both read as a working
         model, so the author is never told which of the two things they wrote
         the engine is doing. Collecting them all is what makes the second one
         nameable, and it is the second we blame: the first is where they
         probably meant to write it. *)
      let occurrences k =
        List.filter_map
          (function
            | Reader.List (Reader.Atom (k', p) :: args, _) when k' = k ->
                Some (args, p)
            | _ -> None)
          clauses
      in
      let* gdatum =
        match occurrences "when" with
        | [ ([ g ], _) ] -> Ok g
        | [] | [ _ ] -> Errors.err ~pos:dp "a transition needs a (when GUARD)"
        | _ :: (_, p) :: _ ->
            Errors.err ~pos:p "a transition has exactly one (when GUARD)"
      in
      let* do_clause =
        match occurrences "do" with
        | [] -> Ok None
        | [ (es, _) ] -> Ok (Some es)
        | _ :: (_, p) :: _ ->
            Errors.err ~pos:p "a transition has exactly one (do EFFECT…)"
      in
      let* when_ = Grammar.guard gdatum in
      let* () = Grammar.check_guard schema env gdatum in
      let effs = match do_clause with Some es -> es | None -> [] in
      let* effects = map_r Grammar.effect effs in
      let* () = iter_r (Grammar.check_effect schema env) effs in
      Ok { Model.name; when_; effects }
  | _ -> Reader.err_at d "expected a (transition …)"

(* §10.1: "NAME, if present, fresh." Unlike §8.1 this does *not* cite §7, so the
   namespace is the transitions' own — a move may share a name with a type or an
   entity, and only another move collides with it.

   Two moves of one name are not a cosmetic clash. §10.1 makes NAME how a report
   identifies a move and how §15 acknowledgments name one, so a duplicate makes
   every such reference ambiguous; and [pol control] emits one [edge] entity per
   transition, so a duplicated name produces a quiver instance with a duplicated
   entity — output the front end now refuses to re-read (§7). Blame the second,
   which is the one the author added. *)
let check_transition_names (trs : Reader.t list) : (unit, Errors.t) result =
  let rec go seen = function
    | [] -> Ok ()
    | Reader.List (Reader.Atom ("transition", _) :: Reader.Atom (n, p) :: _, _)
      :: rest ->
        if List.mem n seen then
          Errors.err ~pos:p
            ("transition `" ^ n
           ^ "` is already declared — §10.1 requires a transition name to be \
              fresh among the model's moves")
        else go (n :: seen) rest
    | _ :: rest -> go seen rest
  in
  go [] trs

(* §9.1: "**Constraints** — NAME fresh; SCHEMA declared." Like §10.1's transition
   name and unlike §8.1's schema name, this does NOT cite §7, so the namespace is
   the instances' own; whether §7 should also cover instances is a question for
   the spec, and nothing here needs it answered. What "fresh" cannot mean is
   *twice*: [(initial i)] resolves by [List.find_opt], so a second instance named
   `i` was simply discarded, and a model naming one initial situation quietly got
   the other author's. Blame the second — the first is the one already referred
   to. *)
let check_instance_names (datums : Reader.t list) : (unit, Errors.t) result =
  let rec go seen = function
    | [] -> Ok ()
    | Reader.List (Reader.Atom ("instance", _) :: Reader.Atom (n, p) :: _, _)
      :: rest ->
        if List.mem n seen then
          Errors.err ~pos:p
            ("instance `" ^ n
           ^ "` is already declared — §9.1 requires an instance name to be \
              fresh")
        else go (n :: seen) rest
    | _ :: rest -> go seen rest
  in
  go [] datums

let parse_model (datums : Reader.t list) : (Model.t, Errors.t) result =
  let* () = check_instance_names datums in
  let* decls = collect_decls datums in
  let rec classify use_ init trs = function
    | [] -> Ok (use_, init, List.rev trs)
    | d :: rest -> (
        match d with
        | Reader.List (Reader.Atom ("schema", _) :: _, _)
        | Reader.List (Reader.Atom ("instance", _) :: _, _) ->
            classify use_ init trs rest
        | Reader.List ([ Reader.Atom ("use", _); Reader.Atom (sn, sp) ], _) -> (
            match use_ with
            | Some _ -> Errors.err ~pos:sp "a model has exactly one (use …)"
            | None -> classify (Some (sn, sp)) init trs rest)
        | Reader.List ([ Reader.Atom ("initial", _); Reader.Atom (inm, ip) ], _)
          -> (
            match init with
            | Some _ -> Errors.err ~pos:ip "a model has exactly one (initial …)"
            | None -> classify use_ (Some (inm, ip)) trs rest)
        | Reader.List (Reader.Atom ("transition", _) :: _, _) ->
            classify use_ init (d :: trs) rest
        | other ->
            Reader.err_at other
              ("unknown top-level declaration: `" ^ head_str other ^ "`"))
  in
  let* use_, init, trs = classify None None [] datums in
  let* () = check_transition_names trs in
  let* sname, use_pos =
    match use_ with
    | Some u -> Ok u
    | None -> Errors.err "a model needs one (use SCHEMA)"
  in
  let* schema =
    match List.find_opt (fun s -> s.Schema.name = sname) decls.schemas with
    | Some s -> Ok s
    | None ->
        Errors.err ~pos:use_pos ("(use …) names unknown schema `" ^ sname ^ "`")
  in
  let* iname, ipos =
    match init with
    | Some i -> Ok i
    | None -> Errors.err "a model needs one (initial INSTANCE)"
  in
  let* initial =
    match List.find_opt (fun i -> i.Instance.name = iname) decls.instances with
    | Some i -> Ok i
    | None ->
        Errors.err ~pos:ipos
          ("(initial …) names unknown instance `" ^ iname ^ "`")
  in
  let* () =
    if initial.Instance.schema = schema.Schema.name then Ok ()
    else
      Errors.err ~pos:ipos
        "the initial instance is of a different schema than (use …)"
  in
  let env = env_of_instance initial in
  let* () = Decl_checks.check_equations_in schema env in
  let* transitions = map_r (decode_transition schema env) trs in
  Ok { Model.schema; initial; transitions }
