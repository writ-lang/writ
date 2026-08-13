(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Pol_data

(* Datums -> the POSITIONED atoms of a rule: terms, paths and guards
   ([Rules.term], [Rules.gpath], [Rules.gexp]).

   Split out of [Rules_parser] at the seam the whole positioned mirror exists
   along. Terms live here beside guards rather than with the literals that hold
   them because they are one type, not two: a guard's free variables ARE the
   rule's variables (see [Rules.term]), so whatever reads one must read the
   other the same way.

   Guards are decoded here rather than through [Grammar.guard] — the one choice
   in this module a future reader is likely to undo. Two reasons, both
   load-bearing. [Model.guard] carries no positions, and extension §1 requires
   the error for an unsortable variable to land ON the variable, so a rule's
   guards must be read into the positioned mirror and lowered only once their
   variables are bound. And [Grammar.check_guard] needs a variable→type
   environment up front, which is precisely what the sort fixpoint has yet to
   compute; calling it here would demand the answer as the price of asking the
   question. [Claims_parser] defers path resolution for the same reason. *)

let ( let* ) = Result.bind

let rec map_r f = function
  | [] -> Ok []
  | x :: xs ->
      let* y = f x in
      let* ys = map_r f xs in
      Ok (y :: ys)

(* ALL-CAPS reads as a variable, matching extension §1's notation. *)
let atom_term (s : string) (p : Errors.pos) : Rules.term =
  if Rules.is_var s then Rules.Var (s, p) else Rules.Const (s, p)

let term (d : Reader.t) : (Rules.term, Errors.t) result =
  match d with
  | Reader.Atom (s, p) ->
      if s = "" then Errors.err ~pos:p "empty term atom" else Ok (atom_term s p)
  | Reader.List (_, p) ->
      Errors.err ~pos:p "expected a variable or a constant, found a list"

(* The reader hands back one position for a whole dotted atom, so every step of
   a path is blamed at the path. That is enough for §1: what has to be findable
   is the variable at the root. *)
let gpath (d : Reader.t) : (Rules.gpath, Errors.t) result =
  match d with
  | Reader.List (_, p) -> Errors.err ~pos:p "expected a path, found a list"
  | Reader.Atom (s, p) -> (
      match Reader.split_dots s with
      | [] | [ _ ] ->
          (* [Value.path] permits no steps at all and the evaluator answers
             [Some (Filled root)], so this would quietly become an equality
             primitive. Pol has none, and this run does not add one by
             accident. *)
          Errors.err ~pos:p
            ("a rule body needs a path with at least one arrow; `" ^ s
           ^ "` is not an equality test")
      | root :: steps ->
          if root = "" || List.exists (fun st -> st = "") steps then
            Errors.err ~pos:p ("malformed dotted path `" ^ s ^ "`")
          else
            Ok
              {
                Rules.root = atom_term root p;
                steps = List.map (fun st -> (st, p)) steps;
                pos = p;
              })

let rec guard (d : Reader.t) : (Rules.gexp, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom (k, kp) :: args, _) -> (
      match (k, args) with
      | "and", gs ->
          let* gs = map_r guard gs in
          Ok (Rules.And gs)
      | "or", gs ->
          let* gs = map_r guard gs in
          Ok (Rules.Or gs)
      | "not", [ g ] ->
          let* g = guard g in
          Ok (Rules.Not (g, kp))
      | "is", [ pd; vd ] ->
          let* pth = gpath pd in
          let* v = term vd in
          Ok (Rules.Is (pth, v))
      | "defined", [ pd ] ->
          let* pth = gpath pd in
          Ok (Rules.Defined pth)
      | "some", [ b; body ] ->
          let* x, ty, bp = binder b in
          let* g = guard body in
          Ok (Rules.Some_ (x, ty, g, bp))
      | _ -> Errors.err ~pos:kp "malformed guard clause")
  | Reader.List (_, p) -> Errors.err ~pos:p "malformed guard clause"
  | Reader.Atom (_, p) ->
      Errors.err ~pos:p "expected a guard clause, found a bare atom"

(* A [some] binder names a KERNEL variable, scoped to its own guard body. An
   ALL-CAPS one would also read as a rule variable and shadow it, and kernel §7
   is explicit that Pol has no shadowing — so it is rejected at the binder. *)
and binder (d : Reader.t) : (string * string * Errors.pos, Errors.t) result =
  match d with
  | Reader.List ([ Reader.Atom (x, xp); Reader.Atom (ty, _) ], _) ->
      if Rules.is_var x then
        Errors.err ~pos:xp
          ("`" ^ x
         ^ "` reads as a rule variable, so it cannot also bind here; Pol has \
            no shadowing")
      else Ok (x, ty, xp)
  | _ -> Reader.err_at d "expected a binder shaped (VAR TYPE)"

(* The G of [(holds S G)] is a guard DATUM, never a term (extension §3). A
   variable written there would otherwise be silently joined against the rest of
   the body, so it is rejected at the atom rather than passed on. *)
let holds_guard (d : Reader.t) : (Rules.gexp, Errors.t) result =
  match d with
  | Reader.Atom (s, p) when Rules.is_var s ->
      Errors.err ~pos:p
        ("`" ^ s
       ^ "` is a variable, but the G of (holds S G) is a guard datum, not a \
          term")
  | _ -> guard d
