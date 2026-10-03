(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The guard language (§10.2). Both a transition's [when] and a
   [Schema.equation] hold one, so it sits below [Schema] and depends only on
   [Value]. *)

(* The right-hand side of [is]: a literal, or a chain if the atom has a dot
   (§5.2). A bare binder there is a literal, which [Grammar.lit_fault]
   refuses. *)
type rhs = Lit of string | Chain of Value.path

type t =
  | And of t list
  | Or of t list
  | Not of t
  | Is of Value.path * rhs
  | Defined of Value.path
  | Some_ of string * string * t

(* Every chain a guard mentions, ignoring scope ([free_roots] respects it). *)
let rec paths (g : t) : Value.path list =
  match g with
  | And gs | Or gs -> List.concat_map paths gs
  | Not g -> paths g
  | Some_ (_, _, g) -> paths g
  | Defined p -> [ p ]
  | Is (p, Lit _) -> [ p ]
  | Is (p, Chain q) -> [ p; q ]

(* The arrow names a guard reads; [Observe] uses it to skip moves that cannot
   affect a law. *)
let arrows (g : t) : string list =
  List.concat_map (fun (p : Value.path) -> p.Value.steps) (paths g)

(* The free roots (not bound by an enclosing [some]), deduplicated, in
   first-mention order. In a law these are the subject (§8.6), and there must
   be exactly one. *)
let free_roots (g : t) : string list =
  let seen = ref [] in
  let note bound (p : Value.path) =
    let r = p.Value.root in
    if (not (List.mem r bound)) && not (List.mem r !seen) then
      seen := r :: !seen
  in
  let rec go bound g =
    match g with
    | And gs | Or gs -> List.iter (go bound) gs
    | Not g -> go bound g
    | Some_ (x, _, g) -> go (x :: bound) g
    | Defined p -> note bound p
    | Is (p, Lit _) -> note bound p
    | Is (p, Chain q) ->
        note bound p;
        note bound q
  in
  go [] g;
  List.rev !seen

(* Structural equality, written out as in [Value.compare_cell]. [Compare] uses
   it to decide whether a law survived a version change. *)
let rec equal (a : t) (b : t) : bool =
  match (a, b) with
  | And xs, And ys | Or xs, Or ys ->
      List.length xs = List.length ys && List.for_all2 equal xs ys
  | Not x, Not y -> equal x y
  | Defined p, Defined q -> Value.compare_path p q = 0
  | Is (p, r), Is (q, s) -> Value.compare_path p q = 0 && equal_rhs r s
  | Some_ (x, tx, gx), Some_ (y, ty, gy) ->
      String.equal x y && String.equal tx ty && equal gx gy
  | _ -> false

and equal_rhs (a : rhs) (b : rhs) : bool =
  match (a, b) with
  | Lit x, Lit y -> String.equal x y
  | Chain p, Chain q -> Value.compare_path p q = 0
  | _ -> false
