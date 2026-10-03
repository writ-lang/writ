(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Extension §1: sorts, by a program-wide least fixpoint over
   [(relation, column) -> sort], seeded by built-ins, typed declarations, an
   unambiguous arrow's [dom] and a path's codomain. It must span rules: in §1's
   transitive closure the recursive rule's [Y] is typed only by the other
   rule. Chain resolution is inside the loop, since an ambiguous arrow seeds
   nothing until the root is typed elsewhere. *)

let ( let* ) = Result.bind

(* Eta-expanded: a bare alias would be weakly polymorphic. *)
let iter_r f xs = Rules_terms.iter_r f xs
let col_why = Rules_terms.col_why

(* ── The tables the fixpoint relaxes ─────────────────────────────────────── *)

(* Each entry keeps what forced it, so a conflict can name both sides (§3). *)
type seed = { srt : Rules.sort; at : Errors.pos; why : string }

type st = {
  m : Model.t;
  tcols : (string * int, seed) Hashtbl.t;
  tvars : (Rules.rule_id * string, seed) Hashtbl.t;
  mutable changed : bool;
}

(* What the fixpoint settled. Variables are keyed by rule, their scope. *)
type t = {
  columns : ((string * int) * Rules.sort) list;
  variables : ((Rules.rule_id * string) * Rules.sort) list;
}

let var_sort (s : t) (rid : Rules.rule_id) (x : string) : Rules.sort option =
  List.assoc_opt (rid, x) s.variables

let col_sort (s : t) (rel : string) (i : int) : Rules.sort option =
  List.assoc_opt (rel, i) s.columns

(* A conflict is blamed at the second occurrence, citing the first. *)
let put st tbl key what (s : seed) : (unit, Errors.t) result =
  match Hashtbl.find_opt tbl key with
  | Some old when old.srt = s.srt -> Ok ()
  | Some old ->
      Errors.err ~pos:s.at
        (what ^ " is "
        ^ Rules_terms.sort_name s.srt
        ^ " here, forced by " ^ s.why ^ ", but at " ^ Rules_terms.pos_str old.at
        ^ " it is "
        ^ Rules_terms.sort_name old.srt
        ^ ", forced by " ^ old.why)
  | None ->
      Hashtbl.replace tbl key s;
      st.changed <- true;
      Ok ()

let seed_var st rid (t : Rules.term) (srt : Rules.sort) (why : string) =
  match t with
  | Rules.Const _ -> Ok ()
  | Rules.Var (x, at) ->
      put st st.tvars (rid, x) ("`" ^ x ^ "`") { srt; at; why }

(* A column and its term each teach the other whichever sort is known. *)
let seed_arg st rid rel i (t : Rules.term) =
  let* () =
    match Hashtbl.find_opt st.tcols (rel, i) with
    | Some c -> seed_var st rid t c.srt (col_why rel i)
    | None -> Ok ()
  in
  match t with
  | Rules.Const _ -> Ok ()
  | Rules.Var (x, at) -> (
      match Hashtbl.find_opt st.tvars (rid, x) with
      | None -> Ok ()
      | Some v ->
          put st st.tcols (rel, i) (col_why rel i)
            { srt = v.srt; at; why = "`" ^ x ^ "`" })

let seed_args st rid rel ts =
  let rec go i = function
    | [] -> Ok ()
    | t :: rest ->
        let* () = seed_arg st rid rel i t in
        go (i + 1) rest
  in
  go 0 ts

(* ── Chain resolution ────────────────────────────────────────────────────── *)

(* The types owning an arrow name (kernel §7); only a single owner seeds. *)
let arrow_doms (s : Schema.t) (name : string) : string list =
  List.sort_uniq String.compare
    (List.filter_map
       (fun (a : Schema.arrow) ->
         if a.Schema.name = name then Some a.Schema.dom else None)
       s.Schema.arrows)

let rec walk (s : Schema.t) (cur : string) = function
  | [] -> Some cur
  | (step, _) :: rest -> (
      match Schema.arrow_in s ~dom:cur step with
      | None -> None
      | Some a -> walk s a.Schema.cod rest)

(* The path's root type if known yet; [None] means try next round. *)
let root_type st rid (benv : (string * string) list) (p : Rules.gpath) =
  match p.Rules.root with
  | Rules.Const (c, _) -> (
      match List.assoc_opt c benv with
      | Some ty -> Some ty
      | None -> Instance.type_of_entity st.m.Model.initial c)
  | Rules.Var (x, _) -> (
      match Hashtbl.find_opt st.tvars (rid, x) with
      | Some { srt = Rules.Entity ty; _ } -> Some ty
      | Some _ | None -> None)

let seed_root st rid (p : Rules.gpath) =
  match (p.Rules.root, p.Rules.steps) with
  | Rules.Var (x, _), (a, _) :: _ when not (Hashtbl.mem st.tvars (rid, x)) -> (
      match arrow_doms st.m.Model.schema a with
      | [ dom ] ->
          seed_var st rid p.Rules.root (Rules.Entity dom)
            ("the root of the path `" ^ Rules_terms.path_str p ^ "`")
      (* Ambiguous or missing: seed nothing ([Rules_paths] reports missing). *)
      | _ -> Ok ())
  | _ -> Ok ()

let rec seed_guard st rid benv (g : Rules.gexp) =
  match g with
  | Rules.Is (p, v) -> (
      let* () = seed_root st rid p in
      match root_type st rid benv p with
      | None -> Ok ()
      | Some rt -> (
          match walk st.m.Model.schema rt p.Rules.steps with
          | None -> Ok ()
          | Some cod ->
              seed_var st rid v (Rules.Entity cod)
                ("the codomain of `" ^ Rules_terms.path_str p ^ "`")))
  | Rules.Defined p -> seed_root st rid p
  | Rules.And gs | Rules.Or gs -> iter_r (seed_guard st rid benv) gs
  | Rules.Not (g, _) -> seed_guard st rid benv g
  | Rules.Some_ (x, ty, g, _) -> seed_guard st rid ((x, ty) :: benv) g

(* ── Seeds ───────────────────────────────────────────────────────────────── *)

(* Seeds from [Rules_terms.builtin_cols]; a [holds] guard's contents are
   seeded like a bare guard's. *)
let seed_builtin st rid (b : Rules.builtin) =
  let name, cols = Rules_terms.builtin_cols b in
  let rec go i = function
    | [] -> Ok ()
    | (t, srt) :: rest ->
        let* () = seed_var st rid t srt (Rules_terms.bwhy name i) in
        go (i + 1) rest
  in
  let* () = go 0 cols in
  match b with
  | Rules.Holds (_, g) -> seed_guard st rid [] g
  | Rules.Situation_ _ | Rules.Init _ | Rules.Edge_ _ | Rules.Gap_edge _
  | Rules.Phase _ | Rules.Phase_step _ ->
      Ok ()

let seed_literal st rid (l : Rules.literal) =
  match l with
  | Rules.Pos_rel (r, ts, _) | Rules.Neg_rel (r, ts, _) -> seed_args st rid r ts
  | Rules.Built_in (b, _) -> seed_builtin st rid b
  | Rules.Guard (g, _) -> seed_guard st rid [] g

let seed_rule st (r : Rules.rule) =
  let* () = seed_args st r.Rules.id r.Rules.head r.Rules.head_args in
  iter_r (seed_literal st r.Rules.id) r.Rules.body

let seed_decl st (r : Rules.relation) =
  match r.Rules.cols with
  | Rules.Arity _ -> Ok ()
  | Rules.Sorts ss ->
      let name = r.Rules.rel_name in
      let why = "the declaration of `" ^ name ^ "`" in
      let rec go i = function
        | [] -> Ok ()
        | s :: rest ->
            let* () =
              match s with
              | Rules.Entity ty when Schema.type_of st.m.Model.schema ty = None
                ->
                  Errors.err ~pos:r.Rules.rel_pos
                    (col_why name i ^ " names `" ^ ty
                   ^ "`, which the schema does not declare")
              | Rules.Entity _ | Rules.Situation | Rules.Edge ->
                  put st st.tcols (name, i) (col_why name i)
                    { srt = s; at = r.Rules.rel_pos; why }
            in
            go (i + 1) rest
      in
      go 0 ss

(* ── Verdicts, once nothing more can be learned ──────────────────────────── *)

let unsorted_var st (r : Rules.rule) =
  let bad =
    List.find_map
      (function
        | Rules.Var (x, p) when not (Hashtbl.mem st.tvars (r.Rules.id, x)) ->
            Some (x, p)
        | Rules.Var _ | Rules.Const _ -> None)
      (Rules_terms.terms_of_rule r)
  in
  match bad with
  | None -> Ok ()
  | Some (x, p) ->
      Errors.err ~pos:p
        ("the type of variable `" ^ x
       ^ "` cannot be inferred; put it in a column that has a sort, or give \
          one a sort with (relation NAME (T1 … Tn))")

let unsorted_cols st (r : Rules.relation) =
  let name = r.Rules.rel_name in
  let unknown i =
    if Hashtbl.mem st.tcols (name, i) then None
    else Some (string_of_int (i + 1))
  in
  match List.filter_map unknown (List.init (Rules_terms.arity_of r) Fun.id) with
  | [] -> Ok ()
  | ms ->
      Errors.err ~pos:r.Rules.rel_pos
        ("the sort of column"
        ^ (if List.length ms > 1 then "s " else " ")
        ^ String.concat ", " ms ^ " of `" ^ name
        ^ "` cannot be inferred; declare it as (relation " ^ name
        ^ " (T1 … Tn))")

(* ── The fixpoint ────────────────────────────────────────────────────────── *)

let infer (m : Model.t) (p : Rules_parser.t) : (t, Errors.t) result =
  let st =
    { m; tcols = Hashtbl.create 32; tvars = Hashtbl.create 64; changed = true }
  in
  let* () = iter_r (seed_decl st) p.Rules_parser.relations in
  (* Each changing round fills a table entry, so this terminates; the bound
     (one round per possible key) makes that explicit. *)
  let bound =
    List.fold_left
      (fun n r -> n + Rules_terms.arity_of r)
      0 p.Rules_parser.relations
    + List.fold_left
        (fun n r -> n + List.length (Rules_terms.terms_of_rule r))
        0 p.Rules_parser.rules
    + 1
  in
  let rec loop k =
    if (not st.changed) || k > bound then Ok ()
    else begin
      st.changed <- false;
      let* () = iter_r (seed_rule st) p.Rules_parser.rules in
      loop (k + 1)
    end
  in
  let* () = loop 0 in
  (* Report unsorted variables before columns: §1 wants the error at the
     variable, and its column is unsorted as a consequence. *)
  let* () = iter_r (unsorted_var st) p.Rules_parser.rules in
  let* () = iter_r (unsorted_cols st) p.Rules_parser.relations in
  let entries tbl = Hashtbl.fold (fun k v acc -> (k, v.srt) :: acc) tbl [] in
  Ok
    {
      columns = List.sort compare (entries st.tcols);
      variables = List.sort compare (entries st.tvars);
    }
