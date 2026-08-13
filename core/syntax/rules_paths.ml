(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Extension §2/§3 — does every term inhabit what the schema gives its position?
   Two questions with one answer: a PATH must actually walk the schema, and a
   CONSTANT must lie in the domain it is compared against (a path's codomain, or
   a sorted column). Both run AFTER sorting, and must: a path's root is a term,
   so the type it is rooted at is whatever the fixpoint settled on, and a
   constant has nothing to be checked against until its column has a sort.
   Asking either question earlier would mean asking for the answer. That is also
   why [Grammar.check_guard] cannot be reused — it takes the variable→type
   environment as an argument.

   The rule that is easy to get wrong is the FIXED-arrow restriction. A BARE
   guard literal has no situation to be read in, so §2 evaluates it against
   [sp.initial] and can only be honest about wiring: every step must name a
   [fixed] arrow. Inside [(holds S G)] the situation is explicit, so a mutable
   arrow is perfectly legal — importing the bare-guard restriction there would
   remove the only way in the language to ask "in situation S, where does this
   mutable arrow point", which is the whole point of §2's reversal. So the
   restriction is a flag on this walk, off under [holds], and the rejection
   names the fix that exists. *)

let ( let* ) = Result.bind
let iter_r f xs = Rules_terms.iter_r f xs
let path_str (p : Rules.gpath) = Rules_terms.path_str p

(* The type a path is rooted at. A [some] binder is looked up in [benv]: it is a
   kernel variable scoped to its own guard body, lower case, and so read as a
   [Const] — [Instance] knows nothing about it. *)
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

(* Walk the chain, returning the arrows in path order so the caller can read off
   the last one's codomain. Each step's dom is fixed by the previous step's cod,
   so only the ROOT was ever ambiguous — and by now it is not. *)
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

(* Kernel §5's codomain rule, as [Grammar.check_set] applies it to effects: a
   CONSTANT compared against a path must inhabit the last arrow's codomain. A
   variable there is not re-checked — the fixpoint sorted it from that same
   codomain, so a mismatch would already have been a sort conflict. *)
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

(* A constant does not SEED a sort (§3) — but once its column has one, the
   constant must lie in it. A typo would otherwise name a row that can never
   exist, and the resulting silence would read as an answer. *)
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

(* One column, one constant, one message shape — the [why] is all that differs
   between a user relation's column and a built-in's. *)
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

(* A built-in's columns are the most sharply sorted positions in the language:
   §3 fixes them per position, with no fixpoint to wait for, so the sort is
   known even where the rest of the rule is not. That makes a typo there the
   easiest one to write and the quietest one to leave unchecked — the row it
   names can never exist, and §9 says an empty answer set is an answer. G is
   exempt because it is not a term position, so [builtin_cols] omits it. *)
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
