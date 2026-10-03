(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Front-end rejection tests: each fault is blamed at an exact line:col. *)

open Writ_data
open Writ_syntax

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

(* --- §8.3: an arrow's endpoints must be declared types ---------------------- *)

(* Each case asserts the position and the name of the missing type. *)
let contains_sub ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

let decodes src =
  match Reader.read_string src with
  | Error e -> Error e
  | Ok ds -> (
      match Expander.expand ds with
      | Error e -> Error e
      | Ok ex -> Parser.parse_model ex)

let rejects_at name src ~line ~col ~sub =
  match decodes src with
  | Ok _ -> check (name ^ " — accepted, but must be rejected") false
  | Error e ->
      check name
        (e.Errors.pos = Some { Errors.file = None; line; col }
        && contains_sub ~sub e.Errors.msg)

let () =
  let model body = body ^ "\n(instance i m (box p))\n(use m)\n(initial i)" in
  rejects_at "an arrow's codomain must be a declared type"
    (model "(schema m (type v (a b)) (type box (arrow f (to nosuchtype))))")
    ~line:1 ~col:49 ~sub:"undeclared type `nosuchtype`";
  (* Endpoints resolve once the schema is whole. *)
  check "a forward reference to a later-declared type still builds"
    (Result.is_ok
       (decodes (model "(schema m (type box (arrow f (to v))) (type v (a b)))")))

(* --- §7: one namespace across the loaded universe --------------------------- *)

(* The second declaration is the one blamed. *)
let () =
  rejects_at "two types of one name in one schema"
    "(schema m (type v (a b)) (type v (c d)))\n\
     (instance i m)\n\
     (use m)\n\
     (initial i)"
    ~line:1 ~col:32 ~sub:"type `v` is already declared";
  rejects_at "two types of one name across two schemas"
    "(schema one (type v (a b)))\n\
     (schema two (type v (c d)))\n\
     (instance i two)\n\
     (use two)\n\
     (initial i)"
    ~line:2 ~col:19 ~sub:"type `v` is already declared";
  rejects_at "two entities of one name in one roster"
    "(schema m (type box) (type v (a b)))\n\
     (instance i m (box e) (box e))\n\
     (use m)\n\
     (initial i)"
    ~line:2 ~col:28 ~sub:"entity `e` is already declared";
  rejects_at "two equations of one name"
    "(schema m (type v (a b)) (type box (arrow f (to v)) (arrow g (to v)))\n\
    \  (equation e (= box.f box.g))\n\
    \  (equation e (= box.g box.f)))\n\
     (instance i m (box p (f a) (g a)) )\n\
     (use m)\n\
     (initial i)"
    ~line:3 ~col:13 ~sub:"equation `e` is already declared";
  rejects_at "an entity may not take a name a type already holds"
    "(schema m (type box) (type v (a b)))\n\
     (instance i m (box box))\n\
     (use m)\n\
     (initial i)"
    ~line:2 ~col:20 ~sub:"entity `box` is already declared as a type"

(* --- §8: the declaration constraints (gap 6's sweep) ------------------------ *)

let () =
  rejects_at "§8.1 two schemas may not share a name"
    "(schema m (type v (a b)))\n\
     (schema m (type w (c d)))\n\
     (instance i m) (use m) (initial i)"
    ~line:2 ~col:9 ~sub:"schema `m` is already declared";
  rejects_at "§8.2 an enumerated type's values must be distinct"
    "(schema m (type v (a a)))\n(instance i m) (use m) (initial i)" ~line:1
    ~col:22 ~sub:"`a` is already a value of type `v`";
  rejects_at "§8.3 a flag may not be repeated"
    "(schema m (type v (a b)) (type box (arrow f (to v) fixed fixed)))\n\
     (instance i m (box p (f a)) ) (use m) (initial i)"
    ~line:1 ~col:58 ~sub:"repeats the flag `fixed`";
  rejects_at "§8.3 one type may not declare two arrows of one name"
    "(schema m (type v (a b)) (type box (arrow f (to v)) (arrow f (to v))))\n\
     (instance i m (box p (f a)) ) (use m) (initial i)"
    ~line:1 ~col:60 ~sub:"arrow `f` is already declared on `box`";
  (* Controls: arrow freshness is per owner (§7); the river model relies on
     it. *)
  check "two types may each own an arrow of the same name"
    (Result.is_ok
       (decodes
          "(schema m (type v (a b)) (type box (arrow at (to v)))\n\
          \  (type crate (arrow at (to v))))\n\
           (instance i m (box p (at a)) (crate q (at a)) )\n\
           (use m) (initial i)"));
  check "a fixed and a vacatable flag together are each still once"
    (Result.is_ok
       (decodes
          "(schema m (type v (a b)) (type box (arrow f (to v) fixed vacatable) \
           (arrow g (to v))))\n\
           (instance i m (box p (f a) (g a)) ) (use m) (initial i)"));
  check "two arrows of one name in one type body are still refused"
    (Result.is_error
       (decodes
          "(schema m (type v (a b)) (type box (arrow f (to v)) (arrow f (to \
           v))))\n\
           (instance i m (box p (f a)) ) (use m) (initial i)"))

(* --- §10.1: exactly one `when`, exactly one `do`, NAME fresh ---------------- *)

(* A duplicate clause used to be dropped silently. *)
let () =
  rejects_at "§10.1 a transition has exactly one (when …)"
    "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
     (instance i m (box p (f a)) ) (use m) (initial i)\n\
     (transition t (when (is p.f b)) (when (is p.f a)) (do (set p.f b)))"
    ~line:3 ~col:34 ~sub:"exactly one (when GUARD)";
  rejects_at "§10.1 a transition has exactly one (do …)"
    "(schema m (type v (a b)) (type box (arrow f (to v)) (arrow g (to v))))\n\
     (instance i m (box p (f a) (g a)) ) (use m) (initial i)\n\
     (transition t (when (is p.f a)) (do (set p.f b)) (do (set p.g b)))"
    ~line:3 ~col:51 ~sub:"exactly one (do EFFECT…)";
  rejects_at "§10.1 two transitions may not share a name"
    "(schema m (type v (a b)) (type box (arrow f (to v)) (arrow g (to v))))\n\
     (instance i m (box p (f a) (g a)) ) (use m) (initial i)\n\
     (transition dup (when (is p.f a)) (do (set p.f b)))\n\
     (transition dup (when (is p.g a)) (do (set p.g b)))"
    ~line:4 ~col:13 ~sub:"transition `dup` is already declared";
  (* §10.1's freshness is the transitions' own namespace. *)
  check "a transition may take a name a type already holds"
    (Result.is_ok
       (decodes
          "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
           (instance i m (box p (f a)) ) (use m) (initial i)\n\
           (transition box (when (is p.f a)) (do (set p.f b)))"))

(* --- §8.3 / §9.3: what a move may write ------------------------------------- *)

(* A write to a fixed cell lands nowhere ([State.build_ctx] hoists fixed
   values), a phantom self-loop; vacating a non-vacatable arrow breaks
   totality. *)
let () =
  rejects_at "§8.3 no move may (set …) a fixed arrow"
    "(schema m (type v (a b)) (type box (arrow f (to v) fixed) (arrow g (to \
     v))))\n\
     (instance i m (box p (f a) (g a)) ) (use m) (initial i)\n\
     (transition setfixed (when (is p.f a)) (do (set p.f b)))"
    ~line:3 ~col:49 ~sub:"arrow `f` is fixed, so no move may set it";
  (* A `fixed vacatable` arrow has the same hole through [vacate]. *)
  rejects_at "§8.3 no move may (vacate …) a fixed arrow either"
    "(schema m (type v (a b)) (type box (arrow f (to v) fixed vacatable) \
     (arrow g (to v))))\n\
     (instance i m (box p (f a) (g a)) ) (use m) (initial i)\n\
     (transition vacfixed (when (is p.f a)) (do (vacate p.f)))"
    ~line:3 ~col:52 ~sub:"arrow `f` is fixed, so no move may empty it";
  rejects_at "§9.3 no move may (vacate …) a non-vacatable arrow"
    "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
     (instance i m (box p (f a)) ) (use m) (initial i)\n\
     (transition emptyit (when (is p.f a)) (do (vacate p.f)))"
    ~line:3 ~col:51 ~sub:"arrow `f` is not vacatable, so no move may empty it";
  check "a move may set a mutable arrow"
    (Result.is_ok
       (decodes
          "(schema m (type v (a b)) (type box (arrow f (to v) fixed) (arrow g \
           (to v))))\n\
           (instance i m (box p (f a) (g a)) ) (use m) (initial i)\n\
           (transition setstate (when (is p.g a)) (do (set p.g b)))"));
  check "a move may vacate a vacatable arrow"
    (Result.is_ok
       (decodes
          "(schema m (type v (a b)) (type box (arrow f (to v) vacatable)))\n\
           (instance i m (box p (f a)) ) (use m) (initial i)\n\
           (transition emptyit (when (is p.f a)) (do (vacate p.f)))"))

(* --- §9.1 and §8.3: the two the sweep found last ---------------------------- *)

(* Both were silent overwrites: the second line did nothing. *)
let () =
  rejects_at "two instances may not share a name"
    "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
     (instance i m (box p (f a)) )\n\
     (instance i m (box q (f b)) )\n\
     (use m) (initial i)"
    ~line:3 ~col:11 ~sub:"instance `i` is already declared";
  (* Entity names are fresh, so all of an entity's slots are in one clause. *)
  rejects_at "the same entity may not head two clauses"
    "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
     (instance i m (box p (f a)) (box p (f b)))\n\
     (use m) (initial i)"
    ~line:2 ~col:34 ~sub:"entity `p` is already declared";
  rejects_at "a cell may not be given two values, in one clause"
    "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
     (instance i m (box p (f a) (f b)) )\n\
     (use m) (initial i)"
    ~line:2 ~col:28 ~sub:"`p.f` is already given a value";
  check "two entities valued in one clause still build"
    (Result.is_ok
       (decodes
          "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
           (instance i m (box p (f a)) (box q (f b)) ) (use m) (initial i)"));
  check "two instances of different names still build"
    (Result.is_ok
       (decodes
          "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
           (instance i m (box p (f a)) )\n\
           (instance j m (box q (f b)) ) (use m) (initial i)"))

let () =
  print_string ("name tests: " ^ string_of_int !passed ^ " checks passed\n")
