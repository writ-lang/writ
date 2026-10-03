(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Program-wide checks on a .rules file; the only constructor of a
   [Rules.program]. Order matters: declaredness and arity first (the sort
   table is keyed by column), then ALL-CAPS collisions, then sorts, which
   paths and safety use. Stratification (§5) is here. *)

let ( let* ) = Result.bind
let iter_r f xs = Rules_terms.iter_r f xs

(* ── Declaredness and arity ──────────────────────────────────────────────── *)

(* A duplicate declaration would make [(relation, column)] ambiguous. The spec
   is silent; rejecting is conservative. *)
let rec no_dups seen = function
  | [] -> Ok ()
  | (r : Rules.relation) :: rest ->
      if List.mem r.Rules.rel_name seen then
        Errors.err ~pos:r.Rules.rel_pos
          ("`" ^ r.Rules.rel_name ^ "` is declared twice")
      else no_dups (r.Rules.rel_name :: seen) rest

(* Every user relation a rule names, with the arity it is used at. *)
let uses (r : Rules.rule) : (string * int * Errors.pos) list =
  (r.Rules.head, List.length r.Rules.head_args, r.Rules.rule_pos)
  :: List.filter_map
       (function
         | Rules.Pos_rel (n, ts, p) | Rules.Neg_rel (n, ts, p) ->
             Some (n, List.length ts, p)
         | Rules.Built_in _ | Rules.Guard _ -> None)
       r.Rules.body

let cols n = string_of_int n ^ if n = 1 then " column" else " columns"

let check_uses rels (r : Rules.rule) =
  iter_r
    (fun (n, k, p) ->
      match
        List.find_opt (fun (d : Rules.relation) -> d.Rules.rel_name = n) rels
      with
      | None ->
          Errors.err ~pos:p
            ("`" ^ n ^ "` is not a declared relation; add (relation " ^ n ^ " "
           ^ string_of_int k ^ ")")
      | Some d ->
          let a = Rules_terms.arity_of d in
          if a = k then Ok ()
          else
            Errors.err ~pos:p
              ("`" ^ n ^ "` is declared with " ^ cols a ^ " but is used with "
             ^ cols k ^ " here"))
    (uses r)

(* ── ALL-CAPS collisions ─────────────────────────────────────────────────── *)

(* A term is a variable iff ALL-CAPS (§9), even quoted. A model's ALL-CAPS
   element or entity (e.g. [KNIGHT]) would be misread as a variable in every
   rule, so such a use is diagnosed. *)
let caps_names (m : Model.t) : (string * string) list =
  let elems =
    List.concat_map
      (fun (t : Schema.ty) ->
        match t.Schema.flavor with
        | Schema.Enumerated vs ->
            List.map (fun v -> (v, "an element of `" ^ t.Schema.name ^ "`")) vs
        | Schema.Open -> [])
      m.Model.schema.Schema.types
  in
  let ents =
    List.concat_map
      (fun (r : Instance.roster) ->
        List.map
          (fun e -> (e, "an entity of `" ^ r.Instance.ty ^ "`"))
          r.Instance.entities)
      m.Model.initial.Instance.rosters
  in
  List.filter (fun (n, _) -> Rules.is_var n) (elems @ ents)

let check_caps names (r : Rules.rule) =
  iter_r
    (function
      | Rules.Const _ -> Ok ()
      | Rules.Var (x, p) -> (
          match List.assoc_opt x names with
          | None -> Ok ()
          | Some what ->
              Errors.err ~pos:p
                ("`" ^ x ^ "` reads as a variable here but names " ^ what
               ^ "; rename one")))
    (Rules_terms.terms_of_rule r)

(* ── Stratification (extension §5) ───────────────────────────────────────── *)

type dep = { src : string; dst : string; neg : Errors.pos option }

let deps (rules : Rules.rule list) : dep list =
  List.concat_map
    (fun (r : Rules.rule) ->
      List.filter_map
        (function
          | Rules.Pos_rel (q, _, _) ->
              Some { src = r.Rules.head; dst = q; neg = None }
          | Rules.Neg_rel (q, _, p) ->
              Some { src = r.Rules.head; dst = q; neg = Some p }
          | Rules.Built_in _ | Rules.Guard _ -> None)
        r.Rules.body)
    rules

(* A dependency route from [a] to [b], ignoring polarity. *)
let route (ds : dep list) (a : string) (b : string) : string list option =
  let rec go seen node =
    if node = b then Some [ b ]
    else if List.mem node seen then None
    else
      let seen = node :: seen in
      List.fold_left
        (fun acc d ->
          match acc with
          | Some _ -> acc
          | None ->
              if d.src <> node then None
              else Option.map (fun tl -> node :: tl) (go seen d.dst))
        None ds
  in
  go [] a

(* §5: blame one [(not …)] on the cycle and name the whole cycle; any negative
   edge on it may be the one to remove. *)
let cycle_error (ds : dep list) =
  let quote n = "`" ^ n ^ "`" in
  let found =
    List.find_map
      (fun d ->
        match d.neg with
        | None -> None
        | Some p -> (
            match route ds d.dst d.src with
            | Some back -> Some (d, back, p)
            | None -> None))
      ds
  in
  match found with
  | None ->
      Errors.err
        "the rules cannot be stratified, and no negative edge lies on a cycle"
  | Some (d, back, p) ->
      Errors.err ~pos:p
        ("negation cycle: "
        ^ String.concat " → " (List.map quote (d.src :: back))
        ^ " — a relation cannot be defined by the absence of something that \
           depends on it. Several negative links may lie on this cycle; \
           removing any one of them fixes it.")

let strata (rels : Rules.relation list) (rules : Rules.rule list) :
    ((string * int) list, Errors.t) result =
  let ds = deps rules in
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun (r : Rules.relation) -> Hashtbl.replace tbl r.Rules.rel_name 0)
    rels;
  let get n = match Hashtbl.find_opt tbl n with Some v -> v | None -> 0 in
  (* A stratification, if one exists, is reached within (relation count)
     rounds; still changing after that means a negative cycle. *)
  let bound = List.length rels + 1 in
  let rec relax k =
    let changed = ref false in
    List.iter
      (fun d ->
        let want = get d.dst + if d.neg = None then 0 else 1 in
        if want > get d.src then (
          Hashtbl.replace tbl d.src want;
          changed := true))
      ds;
    if not !changed then Ok ()
    else if k >= bound then cycle_error ds
    else relax (k + 1)
  in
  let* () = relax 0 in
  Ok
    (List.map
       (fun (r : Rules.relation) -> (r.Rules.rel_name, get r.Rules.rel_name))
       rels)

(* ── The one constructor of a checked program ────────────────────────────── *)

let check (m : Model.t) (p : Rules_parser.t) : (Rules.program, Errors.t) result
    =
  let rels = p.Rules_parser.relations and rules = p.Rules_parser.rules in
  let* () = no_dups [] rels in
  let* () = iter_r (check_uses rels) rules in
  let* () = iter_r (check_caps (caps_names m)) rules in
  let* sorts = Rules_sorts.infer m p in
  let* () = Rules_paths.check m sorts rules in
  let* strata = strata rels rules in
  let* () = Rules_safety.check sorts rules in
  Ok
    {
      Rules.relations = rels;
      rules;
      sorts = sorts.Rules_sorts.columns;
      vars = sorts.Rules_sorts.variables;
      strata;
    }
