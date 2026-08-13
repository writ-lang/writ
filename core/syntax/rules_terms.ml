(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Pol_data

(* The vocabulary the read-time checks share: the walk over a rule's terms in
   WRITTEN order, and the handful of spellings a diagnostic needs.

   Written order is load-bearing in three separate places — sort inference
   blames the first occurrence it cannot type, range restriction simulates the
   join in exactly that order, and the ALL-CAPS collision check reports the
   first misread atom. Three private copies of the walk would be three chances
   for them to disagree about what "first" means, so there is one. *)

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
  (* A [some] BINDER is a kernel variable, not a rule variable, and never
     appears here — it is lower case, so the reader made it a [Const], and an
     ALL-CAPS one is rejected at the binder because it would shadow. The body is
     still walked: an ALL-CAPS term written inside it IS a rule variable, and is
     sorted and bound like any other. *)
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
      (* G is not a term (extension §3) and is not one of these; its CONTENTS
         are, and they are rule variables like any other. *)
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

(* Extension §3's fixed per-position sorts: the built-in's name, then its TERM
   positions in written order, each with the sort that position always has.

   One table, because two readings of it have to agree about which sort sits in
   which column — what a built-in SEEDS ([Rules_sorts]) and what a constant
   written there must INHABIT ([Rules_paths]). Two copies would be two chances
   to disagree, and the disagreement would be silent in exactly the direction
   that matters: a column checked against the wrong sort.

   [(holds S G)]'s G is deliberately absent. It is the language's one non-term
   position — a guard datum, never sorted, never unified — so it has no column
   here; its CONTENTS are walked as a bare guard's are. *)
let builtin_cols (b : Rules.builtin) : string * (Rules.term * Rules.sort) list =
  match b with
  | Rules.Situation_ s -> ("situation", [ (s, Rules.Situation) ])
  | Rules.Init s -> ("init", [ (s, Rules.Situation) ])
  | Rules.Edge_ (e, s1, s2) ->
      ("edge", [ (e, Rules.Edge); (s1, Rules.Situation); (s2, Rules.Situation) ])
  | Rules.Gap_edge (e, s) ->
      ("gap-edge", [ (e, Rules.Edge); (s, Rules.Situation) ])
  (* A phase is named by a situation — its least-indexed member — so both
     columns are [Situation]. That is the whole reason the representative is
     exposed rather than an opaque handle: a phase joins against [situation],
     [edge] and [holds] with no conversion, and no sixth sort enters the
     language to be inferred, blamed and documented. *)
  | Rules.Phase (s, p) ->
      ("phase", [ (s, Rules.Situation); (p, Rules.Situation) ])
  | Rules.Phase_step (p, q) ->
      ("phase-step", [ (p, Rules.Situation); (q, Rules.Situation) ])
  | Rules.Holds (s, _) -> ("holds", [ (s, Rules.Situation) ])
