(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Datums -> a rule's positioned terms, paths and guards. Not [Grammar.guard]:
   errors must land on the variable (extension §1), and sorts are not yet
   known. *)

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

(* A dotted atom has one position, so every step is blamed at the path. *)
let gpath (d : Reader.t) : (Rules.gpath, Errors.t) result =
  match d with
  | Reader.List (_, p) -> Errors.err ~pos:p "expected a path, found a list"
  | Reader.Atom (s, p) -> (
      match Reader.split_dots s with
      | [] | [ _ ] ->
          (* A stepless path evaluates to its root, which would make [is] an
             equality test on atoms. Writ has none. *)
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

(* A [some] binder is a kernel variable. An ALL-CAPS one would shadow a rule
   variable, and Writ has no shadowing (kernel §7). *)
and binder (d : Reader.t) : (string * string * Errors.pos, Errors.t) result =
  match d with
  | Reader.List ([ Reader.Atom (x, xp); Reader.Atom (ty, _) ], _) ->
      if Rules.is_var x then
        Errors.err ~pos:xp
          ("`" ^ x
         ^ "` reads as a rule variable, so it cannot also bind here; Writ has \
            no shadowing")
      else Ok (x, ty, xp)
  | _ -> Reader.err_at d "expected a binder shaped (VAR TYPE)"

(* The G of [(holds S G)] is a guard datum, not a term (extension §2); a
   variable there would be silently joined, so it is rejected. *)
let holds_guard (d : Reader.t) : (Rules.gexp, Errors.t) result =
  match d with
  | Reader.Atom (s, p) when Rules.is_var s ->
      Errors.err ~pos:p
        ("`" ^ s
       ^ "` is a variable, but the G of (holds S G) is a guard datum, not a \
          term")
  | _ -> guard d
