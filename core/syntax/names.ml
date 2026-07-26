open Pol_data

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

type kind = Type | Entity | Equation

let kind_name = function
  | Type -> "type"
  | Entity -> "entity"
  | Equation -> "equation"

let article = function Entity | Equation -> "an" | Type -> "a"

(* A roster clause is [(TYPE e…)], all-atom; a valuation clause is
   [(ARROW (E V)…)], whose arguments are lists. Telling them apart needs the
   schema in [Decl], but syntactically the shape is enough, and working from
   the raw datums is what keeps a position on every name. [(of SCHEMA)] is
   neither and is skipped by name. *)
let roster_entities (clauses : Reader.t list) : (string * Errors.pos) list =
  List.concat_map
    (function
      | Reader.List (Reader.Atom ("of", _) :: _, _) -> []
      | Reader.List (Reader.Atom (_, _) :: args, _)
        when args <> []
             && List.for_all
                  (function Reader.Atom _ -> true | _ -> false)
                  args ->
          List.filter_map
            (function Reader.Atom (e, p) -> Some (e, p) | _ -> None)
            args
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
      | Reader.List (Reader.Atom ("schema", _) :: _ :: clauses, _) ->
          schema_names clauses
      | Reader.List (Reader.Atom ("instance", _) :: _ :: clauses, _) ->
          List.map (fun (e, p) -> (e, Entity, p)) (roster_entities clauses)
      | _ -> [])
    datums

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
              ^ " — §7 gives types, entities, forms and equations one \
                 namespace across the loaded universe")
        | None ->
            Hashtbl.add seen n k;
            go rest)
  in
  go (declared datums)
