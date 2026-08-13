(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Pol_data

(* Is a decoded .rules file a legal PROGRAM? [Rules_parser] judged each datum on
   what a single datum can be judged on; everything here is program-wide, and
   all of it is rejected at READ time with a [line:col], which is why it lives
   in core/syntax at all — the parser's positioned IR is the only thing in the
   engine that carries positions.

   The design names four checks, and they are four modules: sorts
   ([Rules_sorts], extension §3), schema conformance for paths and constants
   ([Rules_paths], §2/§3), range restriction ([Rules_safety], §4) and
   stratification (below, §5), over one shared term walk ([Rules_terms]). This
   module also holds the checks a whole file is needed for but no fixpoint is —
   declaredness, arity agreement, and the ALL-CAPS collision — and it is the
   only constructor of a [Rules.program]: nothing unchecked can reach the
   engine, because there is no other way to build one.

   Order matters and is not arbitrary. Declaredness and arity come first: the
   sort fixpoint is indexed by [(relation, column)], so a literal disagreeing
   with its declaration would corrupt the very table the later diagnostics are
   read out of. The collision check comes next, before anything reads an
   ALL-CAPS atom as a variable. Then sorts, because paths and safety both
   consume them. *)

let ( let* ) = Result.bind
let iter_r f xs = Rules_terms.iter_r f xs

(* ── Declaredness and arity ──────────────────────────────────────────────── *)

(* Two declarations of one name would make [(relation, column)] ambiguous and
   silently pick one. The specification is silent on the case; rejecting is the
   conservative reading. *)
let rec no_dups seen = function
  | [] -> Ok ()
  | (r : Rules.relation) :: rest ->
      if List.mem r.Rules.rel_name seen then
        Errors.err ~pos:r.Rules.rel_pos
          ("`" ^ r.Rules.rel_name ^ "` is declared twice")
      else no_dups (r.Rules.rel_name :: seen) rest

(* Every relation a rule names, with the arity it is used at. Built-ins are
   absent by construction: the parser routes them to [Built_in], so a
   [Pos_rel]/[Neg_rel] name is always a user relation. *)
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

(* A term is a variable iff ALL-CAPS (§9), and quoting is no escape because the
   reader hands back the same atom either way. So a model with an ALL-CAPS
   element or entity — [(type kind-t (KNIGHT KNAVE))] checks clean today — would
   have that name silently misread as a variable in every rule. Diagnosed at the
   atom instead. It bites only models that have one. *)
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

(* A dependency route from [a] to [b], [a] first — polarity ignored, because any
   way back closes the cycle. *)
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

(* §5: blame at ONE [(not …)] on the cycle, naming the whole cycle. Several
   negative edges may lie on it and removing any one of them fixes it, so the
   message must not claim the site it points at is "the" fix. *)
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
  (* Relaxation bounded by the relation count: a stratification, when one
     exists, is reached in at most that many rounds, because the longest route
     without a repeat has that many edges. Still changing afterwards means a
     cycle carrying a negative edge. *)
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
