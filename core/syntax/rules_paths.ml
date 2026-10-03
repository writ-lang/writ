(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Extension §2/§3, after sorting: every path walks the schema and every
   constant lies in its domain. A bare guard has no situation, so its steps
   must be [fixed] arrows; inside [(holds S G)] mutable ones are fine. *)

let ( let* ) = Result.bind
let iter_r f xs = Rules_terms.iter_r f xs
let path_str (p : Rules.gpath) = Rules_terms.path_str p

(* The type a path is rooted at. A [some] binder reads as a [Const] and is
   looked up in [benv]. *)
let root_type (m : Model.t) (sorts : Rules_sorts.t) rid benv (p : Rules.gpath) :
    (string, Errors.t) result =
  match p.Rules.root with
  | Rules.Const (c, cp) -> (
      match List.assoc_opt c benv with
      | Some ty -> Ok ty
      | None -> (
          match Instance.type_of_entity m.Model.initial c with
          | Some ty -> Ok ty
          | None ->
              Errors.err ~pos:cp
                ("`" ^ c ^ "` heads a path but names no entity in the instance")
          ))
  | Rules.Var (x, xp) -> (
      match Rules_sorts.var_sort sorts rid x with
      | Some (Rules.Entity ty) -> Ok ty
      | Some other ->
          Errors.err ~pos:xp
            ("`" ^ x ^ "` is "
            ^ Rules_terms.sort_name other
            ^ ", so it cannot head a path")
      | None -> Errors.err ~pos:xp ("`" ^ x ^ "` heads a path but has no sort"))

let mutable_arrow (p : Rules.gpath) (step : string) =
  "`" ^ step
  ^ "` is a mutable arrow, and a bare guard has no situation to read it in; \
     wrap the guard in (holds S …) to say which situation `" ^ path_str p
  ^ "` is read in"

(* Walk the chain, returning the arrows in path order. *)
let resolve (m : Model.t) (sorts : Rules_sorts.t) rid benv ~(fixed_only : bool)
    (p : Rules.gpath) : (Schema.arrow list, Errors.t) result =
  let* rt = root_type m sorts rid benv p in
  let rec go cur acc = function
    | [] -> Ok (List.rev acc)
    | (step, sp) :: rest -> (
        match Schema.arrow_in m.Model.schema ~dom:cur step with
        | None ->
            Errors.err ~pos:sp ("`" ^ cur ^ "` has no arrow `" ^ step ^ "`")
        | Some a ->
            if fixed_only && not a.Schema.fixed then
              Errors.err ~pos:p.Rules.pos (mutable_arrow p step)
            else go a.Schema.cod (a :: acc) rest)
  in
  go rt [] p.Rules.steps

(* Kernel §5: a constant compared against a path must inhabit its codomain.
   Variables were already sorted from that codomain. *)
let check_value (m : Model.t) benv (arrows : Schema.arrow list) (v : Rules.term)
    =
  match (List.rev arrows, v) with
  | [], _ | _, Rules.Var _ -> Ok ()
  | last :: _, Rules.Const (c, cp) ->
      let cod = last.Schema.cod in
      let ok =
        match Schema.type_of m.Model.schema cod with
        | Some { flavor = Schema.Enumerated _; _ } ->
            List.mem c (Schema.elements_of m.Model.schema cod)
        | Some { flavor = Schema.Open; _ } ->
            List.assoc_opt c benv = Some cod
            || Instance.type_of_entity m.Model.initial c = Some cod
        | None -> true
      in
      if ok then Ok ()
      else Errors.err ~pos:cp ("value `" ^ c ^ "` not in codomain `" ^ cod ^ "`")

let rec check_guard m sorts rid benv ~fixed_only (g : Rules.gexp) =
  match g with
  | Rules.Is (p, v) ->
      let* arrows = resolve m sorts rid benv ~fixed_only p in
      check_value m benv arrows v
  | Rules.Defined p ->
      let* _ = resolve m sorts rid benv ~fixed_only p in
      Ok ()
  | Rules.And gs | Rules.Or gs ->
      iter_r (check_guard m sorts rid benv ~fixed_only) gs
  | Rules.Not (g, _) -> check_guard m sorts rid benv ~fixed_only g
  | Rules.Some_ (x, ty, g, bp) ->
      if Schema.type_of m.Model.schema ty = None then
        Errors.err ~pos:bp
          ("`" ^ ty ^ "` is not a type the schema declares, so `" ^ x
         ^ "` cannot range over it")
      else check_guard m sorts rid ((x, ty) :: benv) ~fixed_only g

let check_literal m sorts rid (l : Rules.literal) =
  match l with
  | Rules.Guard (g, _) -> check_guard m sorts rid [] ~fixed_only:true g
  | Rules.Built_in (Rules.Holds (_, g), _) ->
      check_guard m sorts rid [] ~fixed_only:false g
  | Rules.Built_in _ | Rules.Pos_rel _ | Rules.Neg_rel _ -> Ok ()

(* ── Constants in sorted columns ─────────────────────────────────────────── *)

(* A constant does not seed a sort (§3), but must lie in its column's sort;
   otherwise a typo silently yields an empty answer. *)
let const_ok (m : Model.t) (srt : Rules.sort) (c : string) =
  match srt with
  (* §9: a situation is a bare non-negative index, in and out. *)
  | Rules.Situation -> (
      match int_of_string_opt c with Some n -> n >= 0 | None -> false)
  (* An edge is a transition's name, or the positional label the space
     generates for an unnamed one. *)
  | Rules.Edge ->
      List.exists
        (fun (t : Model.transition) -> t.Model.name = Some c)
        m.Model.transitions
      || String.length c > 1
         && c.[0] = '#'
         && int_of_string_opt (String.sub c 1 (String.length c - 1)) <> None
  | Rules.Entity ty ->
      List.mem c (Schema.elements_of m.Model.schema ty)
      || Instance.type_of_entity m.Model.initial c = Some ty

let check_col m ~why i (t : Rules.term) (srt : Rules.sort option) =
  match (t, srt) with
  | Rules.Const (c, p), Some srt when not (const_ok m srt c) ->
      Errors.err ~pos:p
        ("`" ^ c ^ "` is not " ^ Rules_terms.sort_name srt ^ ", which is what "
       ^ why i ^ " takes")
  | (Rules.Const _ | Rules.Var _), _ -> Ok ()

let check_args m sorts rel ts =
  let rec go i = function
    | [] -> Ok ()
    | t :: rest ->
        let* () =
          check_col m ~why:(Rules_terms.col_why rel) i t
            (Rules_sorts.col_sort sorts rel i)
        in
        go (i + 1) rest
  in
  go 0 ts

(* A built-in's columns have fixed sorts (§3), so constants there are always
   checkable. *)
let check_builtin m (b : Rules.builtin) =
  let name, cols = Rules_terms.builtin_cols b in
  let rec go i = function
    | [] -> Ok ()
    | (t, srt) :: rest ->
        let* () = check_col m ~why:(Rules_terms.bwhy name) i t (Some srt) in
        go (i + 1) rest
  in
  go 0 cols

let check_rule m sorts (r : Rules.rule) =
  let* () = iter_r (check_literal m sorts r.Rules.id) r.Rules.body in
  let* () = check_args m sorts r.Rules.head r.Rules.head_args in
  iter_r
    (function
      | Rules.Pos_rel (rel, ts, _) | Rules.Neg_rel (rel, ts, _) ->
          check_args m sorts rel ts
      | Rules.Built_in (b, _) -> check_builtin m b
      | Rules.Guard _ -> Ok ())
    r.Rules.body

let check (m : Model.t) (sorts : Rules_sorts.t) (rules : Rules.rule list) :
    (unit, Errors.t) result =
  iter_r (check_rule m sorts) rules
