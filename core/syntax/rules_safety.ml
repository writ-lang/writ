(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Extension §4 — range restriction, by simulating the join.

   Body literals are joined in WRITTEN order, so this pass walks a body in that
   order carrying the set of variables an earlier literal could have bound, and
   rejects the first literal that uses one nothing before it could reach — at
   that variable. Written order also governs the CONJUNCTS of a top-level [and]:
   [(and (not (is X.a b)) (is X.c Y))] is rejected at [X], because only the
   second conjunct would have bound it. One rule for literals and conjuncts
   alike, so the rejection is predictable and the fix is to reorder.

   What binds, per §2's compilation of a guard literal:

   - a positive relation literal, and every built-in except [holds], binds all
     its variables;
   - a top-level [(is PATH V)] is FUNCTIONAL — it binds V from the cell, and
     binds its root by enumerating that sort's roster;
   - everything else — [defined], [not], [or], [some], a negated relation — is a
     closed test: it binds nothing and every rule variable in it must already be
     bound.

   [(holds S G)] composes with all of it. S must be ALREADY bound, because
   [holds] never generates situations and a body that let it would silently ask
   the guard of every situation in the space. G is a datum, not a term, so it
   neither binds nor needs binding as a column — but G's CONTENTS bind exactly
   what a bare guard in that position binds, which is what makes §2's reversal
   usable rather than notional.

   A [some] binder needs no carve-out in the code, and that is worth saying
   because the reading it implements is not obvious: "must already be bound"
   applies to RULE variables, and a binder's variable is bound by construction.
   It never reaches here as a [Var] because it is lower case (an ALL-CAPS one is
   rejected at the binder, since it would shadow, and Writ has no shadowing). So
   [(holds S (not (some (a account) (is a.role admin))))] is a closed test with
   no free rule variables at all — accepted, as the oracle needs. *)

let ( let* ) = Result.bind
let iter_r f xs = Rules_terms.iter_r f xs

let unbound x =
  "`" ^ x
  ^ "` is not bound by any earlier literal; a body joins in written order \
     (extension §4), and nothing before this point could have bound it"

let need bound (t : Rules.term) =
  match t with
  | Rules.Const _ -> Ok ()
  | Rules.Var (x, p) ->
      if List.mem x !bound then Ok () else Errors.err ~pos:p (unbound x)

let bind bound (t : Rules.term) =
  match t with
  | Rules.Const _ -> ()
  | Rules.Var (x, _) -> if not (List.mem x !bound) then bound := x :: !bound

let closed bound (g : Rules.gexp) =
  iter_r (need bound) (Rules_terms.guard_terms g)

(* A path root is enumerable only when its sort names a roster to enumerate. In
   practice the sort pass has already given it one and the path pass has already
   proved it is an entity type, so the fallback is unreachable defence — but it
   is the honest reading of §4's "only if the root's sort is known". *)
let bind_root sorts rid bound (p : Rules.gpath) =
  match p.Rules.root with
  | Rules.Const _ -> Ok ()
  | Rules.Var (x, _) when List.mem x !bound -> Ok ()
  | Rules.Var (x, _) -> (
      match Rules_sorts.var_sort sorts rid x with
      | Some (Rules.Entity _) ->
          bind bound p.Rules.root;
          Ok ()
      | Some (Rules.Situation | Rules.Edge) | None -> need bound p.Rules.root)

let rec top sorts rid bound (g : Rules.gexp) =
  match g with
  | Rules.Is (p, v) ->
      let* () = bind_root sorts rid bound p in
      bind bound v;
      Ok ()
  | Rules.And gs -> iter_r (top sorts rid bound) gs
  | Rules.Defined _ | Rules.Or _ | Rules.Not _ | Rules.Some_ _ -> closed bound g

let literal sorts rid bound (l : Rules.literal) =
  match l with
  | Rules.Pos_rel (_, ts, _) ->
      List.iter (bind bound) ts;
      Ok ()
  | Rules.Neg_rel (_, ts, _) -> iter_r (need bound) ts
  | Rules.Guard (g, _) -> top sorts rid bound g
  | Rules.Built_in (b, _) -> (
      match b with
      | Rules.Situation_ t | Rules.Init t ->
          bind bound t;
          Ok ()
      | Rules.Edge_ (e, s1, s2) ->
          List.iter (bind bound) [ e; s1; s2 ];
          Ok ()
      | Rules.Gap_edge (e, s) ->
          List.iter (bind bound) [ e; s ];
          Ok ()
      (* Both phase relations are extensional and complete before stratum 0, so
         either position may GENERATE: [(phase S P)] with neither bound
         enumerates the whole map, which is what lets a rule read a situation's
         phase and a phase's members with one literal. *)
      | Rules.Phase (s, p) ->
          List.iter (bind bound) [ s; p ];
          Ok ()
      | Rules.Phase_step (p, q) ->
          List.iter (bind bound) [ p; q ];
          Ok ()
      | Rules.Holds (s, g) ->
          let* () = need bound s in
          top sorts rid bound g)

let head_bound bound (r : Rules.rule) =
  iter_r
    (function
      | Rules.Const _ -> Ok ()
      | Rules.Var (x, p) ->
          if List.mem x !bound then Ok ()
          else
            Errors.err ~pos:p
              ("`" ^ x
             ^ "` is in the head but is not bound by the body; every head \
                variable must be bound (extension §4)"))
    r.Rules.head_args

let check_rule sorts (r : Rules.rule) =
  let bound = ref [] in
  let* () = iter_r (literal sorts r.Rules.id bound) r.Rules.body in
  head_bound bound r

let check (sorts : Rules_sorts.t) (rules : Rules.rule list) :
    (unit, Errors.t) result =
  iter_r (check_rule sorts) rules
