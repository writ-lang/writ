(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Extension §1: range restriction, simulating the join in written order (of
   literals, and of a top-level [and]'s conjuncts). Positive relations and
   built-ins bind their variables; a top-level [(is PATH V)] binds V and
   enumerates its root; anything else is a closed test. In [(holds S G)], S
   must already be bound and G binds as a bare guard would. *)

let ( let* ) = Result.bind
let iter_r f xs = Rules_terms.iter_r f xs

let unbound x =
  "`" ^ x
  ^ "` is not bound by any earlier literal; a body joins in written order \
     (extension §1), and nothing before this point could have bound it"

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

(* A path root is enumerable only when its sort is an entity type (§4). Earlier
   passes guarantee that, so the fallback is defensive. *)
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
  | Rules.Defined _ | Rules.Is_path _ | Rules.Or _ | Rules.Not _ | Rules.Some_ _
    ->
      closed bound g

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
      (* Phase relations are complete before stratum 0, so either position
         may generate. *)
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
                variable must be bound (extension §1)"))
    r.Rules.head_args

let check_rule sorts (r : Rules.rule) =
  let bound = ref [] in
  let* () = iter_r (literal sorts r.Rules.id bound) r.Rules.body in
  head_bound bound r

let check (sorts : Rules_sorts.t) (rules : Rules.rule list) :
    (unit, Errors.t) result =
  iter_r (check_rule sorts) rules
