(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* The walk over a rule's terms in written order, which the checks must agree
   on, and the spellings their diagnostics use. *)

let ( let* ) = Result.bind

let rec iter_r f = function
  | [] -> Ok ()
  | x :: xs ->
      let* () = f x in
      iter_r f xs

let arity_of (r : Rules.relation) : int =
  match r.Rules.cols with
  | Rules.Arity a -> a
  | Rules.Sorts ss -> List.length ss

(* ── Terms, in written order ─────────────────────────────────────────────── *)

let rec guard_terms (g : Rules.gexp) : Rules.term list =
  match g with
  | Rules.Is (p, v) -> [ p.Rules.root; v ]
  | Rules.Defined p -> [ p.Rules.root ]
  | Rules.And gs | Rules.Or gs -> List.concat_map guard_terms gs
  | Rules.Not (g, _) -> guard_terms g
  (* The binder is a kernel variable and is skipped; ALL-CAPS terms in the body
     are rule variables. *)
  | Rules.Some_ (_, _, g, _) -> guard_terms g

let literal_terms (l : Rules.literal) : Rules.term list =
  match l with
  | Rules.Pos_rel (_, ts, _) | Rules.Neg_rel (_, ts, _) -> ts
  | Rules.Guard (g, _) -> guard_terms g
  | Rules.Built_in (b, _) -> (
      match b with
      | Rules.Situation_ t | Rules.Init t -> [ t ]
      | Rules.Edge_ (e, s1, s2) -> [ e; s1; s2 ]
      | Rules.Gap_edge (e, s) -> [ e; s ]
      | Rules.Phase (s, p) -> [ s; p ]
      | Rules.Phase_step (p, q) -> [ p; q ]
      (* G is not a term (extension §2), but its contents are. *)
      | Rules.Holds (s, g) -> s :: guard_terms g)

let terms_of_rule (r : Rules.rule) : Rules.term list =
  r.Rules.head_args @ List.concat_map literal_terms r.Rules.body

(* ── Spellings ───────────────────────────────────────────────────────────── *)

let pos_str (p : Errors.pos) =
  string_of_int p.Errors.line ^ ":" ^ string_of_int p.Errors.col

let sort_name = function
  | Rules.Situation -> "a situation"
  | Rules.Edge -> "an edge"
  | Rules.Entity t -> "an entity of `" ^ t ^ "`"

let term_name = function Rules.Var (x, _) -> x | Rules.Const (c, _) -> c

let path_str (p : Rules.gpath) =
  String.concat "." (term_name p.Rules.root :: List.map fst p.Rules.steps)

let col_why rel i = "column " ^ string_of_int (i + 1) ^ " of `" ^ rel ^ "`"
let bwhy k i = "column " ^ string_of_int (i + 1) ^ " of built-in `" ^ k ^ "`"

(* Each built-in's name and term positions with their fixed sorts (§3), shared
   by [Rules_sorts] and [Rules_paths]. [holds]'s G is not a term. *)
let builtin_cols (b : Rules.builtin) : string * (Rules.term * Rules.sort) list =
  match b with
  | Rules.Situation_ s -> ("situation", [ (s, Rules.Situation) ])
  | Rules.Init s -> ("init", [ (s, Rules.Situation) ])
  | Rules.Edge_ (e, s1, s2) ->
      ("edge", [ (e, Rules.Edge); (s1, Rules.Situation); (s2, Rules.Situation) ])
  | Rules.Gap_edge (e, s) ->
      ("gap-edge", [ (e, Rules.Edge); (s, Rules.Situation) ])
  (* A phase is named by its least-indexed situation, so it joins with the
     other built-ins without a sort of its own. *)
  | Rules.Phase (s, p) ->
      ("phase", [ (s, Rules.Situation); (p, Rules.Situation) ])
  | Rules.Phase_step (p, q) ->
      ("phase-step", [ (p, Rules.Situation); (q, Rules.Situation) ])
  | Rules.Holds (s, _) -> ("holds", [ (s, Rules.Situation) ])
