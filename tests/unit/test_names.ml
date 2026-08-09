(* Front-end REJECTION tests: sources built as strings and pushed through the
   real reader, expander and parser, asserting the exact line:col each is blamed
   at. Split from test_data.ml at the input seam — that suite loads real files
   from disk and needs a resolver, these need none — and because the two
   together crossed the 300-line cap.

   Every case below is a verbatim reproduction of a model that used to build
   cleanly and should not have. The suite has outgrown its name: it started on
   §7's namespace and now covers §8's and §10.1's declaration constraints too,
   which belong here for
   the same reason — a source string, the real front end, and one line:col. *)

open Pol_data
open Pol_syntax

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

(* --- §8.3: an arrow's endpoints must be declared types ---------------------- *)

(* What was wrong here was not that the model was accepted — it failed
   eventually — but that it failed at the wrong stage, in
   the wrong file, with no position, complaining about a *cell* and never naming
   the type that does not exist. So each case asserts the position and the
   offending name, not merely that something went wrong. *)
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
  (* The control, and the reason the check cannot live in the arrow decoder: a
     type may be declared AFTER the arrow that points at it, so the schema has
     to be whole before any endpoint can be resolved. *)
  check "a forward reference to a later-declared type still builds"
    (Result.is_ok
       (decodes (model "(schema m (type box (arrow f (to v))) (type v (a b)))")))

(* --- §7: one namespace across the loaded universe --------------------------- *)

(* Five models that all built cleanly and reported `states: 1  edges: 0`
   before this rule existed. Each asserts the
   position, because the point of the rule is that the SECOND declaration is
   blamed — an error naming the first would send the author to the line that was
   fine. *)
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
  (* §7 says ONE namespace, not one per category, so a name taken by a type is
     not available to an entity either. This is the case none of the gap's
     reproductions covered, and the one most likely to be quietly dropped by a
     future refactor that keeps a set per kind. *)
  rejects_at "an entity may not take a name a type already holds"
    "(schema m (type box) (type v (a b)))\n\
     (instance i m (box box))\n\
     (use m)\n\
     (initial i)"
    ~line:2 ~col:20 ~sub:"entity `box` is already declared as a type"

(* --- §8: the declaration constraints (gap 6's sweep) ------------------------ *)

(* Each of these built cleanly and reported `states: 1  edges: 0` before the
   sweep, so what is asserted is the position: the constraint is only useful if
   it names the atom the author has to change. *)
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
  (* The two controls that keep §8.3's freshness scoped to the owner rather than
     global. §7 is explicit that `bureau` and `case` may each own a `status`, and
     pol-problems' river leans on it (traveler.at, cargo.at) — a check keyed on
     the name alone would pass every test above and break the river. The second
     control covers the same pair declared through different syntax, which is the
     case a per-[(type …)]-body check would miss. *)
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
  (* Arrow freshness within one type body — the schema-top declaration site
     the old case paired it with no longer exists. *)
  check "two arrows of one name in one type body are still refused"
    (Result.is_error
       (decodes
          "(schema m (type v (a b)) (type box (arrow f (to v)) (arrow f (to \
           v))))\n\
           (instance i m (box p (f a)) ) (use m) (initial i)"))

(* --- §10.1: exactly one `when`, exactly one `do`, NAME fresh ---------------- *)

(* The two duplicate-clause cases are the sharpest of the sweep, because the
   surplus clause was *discarded in silence*: with `(when (is p.f b))` before
   `(when (is p.f a))` and `p.f = a` initially, the space was `states: 1
   edges: 0` — the false first guard won and the true second one was dropped, so
   the author's move existed nowhere and nothing said so. *)
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
  (* §10.1 says NAME must be fresh and, unlike §8.1, does NOT cite §7 — so the
     namespace is the transitions' own. A move named after a type is legal, and
     this is the control that would fail if the check were folded into [Names]. *)
  check "a transition may take a name a type already holds"
    (Result.is_ok
       (decodes
          "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
           (instance i m (box p (f a)) ) (use m) (initial i)\n\
           (transition box (when (is p.f a)) (do (set p.f b)))"))

(* --- §8.3 / §9.3: what a move may write ------------------------------------- *)

(* These two changed what a model MEANS, which is why they are the ones worth
   being precise about. Writing a fixed cell landed nowhere — [State.build_ctx]
   hoists fixed values out of the state vector — so the move became a phantom
   self-loop on every situation its guard admitted: the `set`-fixed model below
   reported `states: 2  edges: 3` where only one edge is real. Vacating a
   non-vacatable arrow built a situation [build_ctx] rejects in an instance, so
   the engine could reach a state its own totality check forbids. *)
let () =
  rejects_at "§8.3 no move may (set …) a fixed arrow"
    "(schema m (type v (a b)) (type box (arrow f (to v) fixed) (arrow g (to \
     v))))\n\
     (instance i m (box p (f a) (g a)) ) (use m) (initial i)\n\
     (transition setfixed (when (is p.f a)) (do (set p.f b)))"
    ~line:3 ~col:49 ~sub:"arrow `f` is fixed, so no move may set it";
  (* The twin, found by asking whether the other effect had the same hole: it
     did. A `fixed vacatable` arrow is writable by [vacate] and lands nowhere in
     exactly the same way — `states: 2  edges: 3` again. *)
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
  (* The controls: the legal versions of both, which must keep building. *)
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

(* Both were silent overwrites rather than visible faults, which is why neither
   showed up as a wrong answer: a lookup took the first match and the author's
   second line did nothing. *)
let () =
  rejects_at "two instances may not share a name"
    "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
     (instance i m (box p (f a)) )\n\
     (instance i m (box q (f b)) )\n\
     (use m) (initial i)"
    ~line:3 ~col:11 ~sub:"instance `i` is already declared";
  (* Entity-major clauses removed the "across clauses" case for a cell: all of
     an entity's slots live in ONE clause, because entity names are fresh. The
     shape that used to spell it now trips the freshness rule instead, and that
     is the behaviour worth pinning. *)
  rejects_at "the same entity may not head two clauses"
    "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
     (instance i m (box p (f a)) (box p (f b)))\n\
     (use m) (initial i)"
    ~line:2 ~col:34 ~sub:"entity `p` is already declared";
  (* …nor inside ONE clause, which a check written only against the accumulator
     would have missed. *)
  rejects_at "a cell may not be given two values, in one clause"
    "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
     (instance i m (box p (f a) (f b)) )\n\
     (use m) (initial i)"
    ~line:2 ~col:28 ~sub:"`p.f` is already given a value";
  (* The controls: neither check may fire on the legitimate shapes they resemble
     — several cells in one clause, and several instances with distinct names. *)
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
