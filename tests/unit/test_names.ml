(* Front-end REJECTION tests: sources built as strings and pushed through the
   real reader, expander and parser, asserting the exact line:col each is blamed
   at. Split from test_data.ml at the input seam — that suite loads real files
   from disk and needs a resolver, these need none — and because the two
   together crossed the 300-line cap.

   Both groups close gaps recorded in docs/conformance-gaps.md, where every case
   below is a verbatim reproduction that used to build cleanly. *)

open Pol_data
open Pol_syntax

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

(* --- §8.3: an arrow's endpoints must be declared types ---------------------- *)

(* The gap this closes (docs/conformance-gaps.md #2) was not that the model was
   accepted — it failed eventually — but that it failed at the wrong stage, in
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
        (e.Errors.pos = Some { Errors.line; col }
        && contains_sub ~sub e.Errors.msg)

let () =
  let model body =
    body ^ "\n(instance i (of m) (box p))\n(use m)\n(initial i)"
  in
  rejects_at "an arrow's codomain must be a declared type"
    (model "(schema m (type v (a b)) (type box (arrow f (to nosuchtype))))")
    ~line:1 ~col:49 ~sub:"undeclared type `nosuchtype`";
  rejects_at "an explicit (of TYPE) domain must be a declared type too"
    (model
       "(schema m (type v (a b)) (type box) (arrow f (of nosuchdom) (to v)))")
    ~line:1 ~col:50 ~sub:"undeclared type `nosuchdom`";
  (* The control, and the reason the check cannot live in the arrow decoder: a
     type may be declared AFTER the arrow that points at it, so the schema has
     to be whole before any endpoint can be resolved. *)
  check "a forward reference to a later-declared type still builds"
    (Result.is_ok
       (decodes (model "(schema m (type box (arrow f (to v))) (type v (a b)))")))

(* --- §7: one namespace across the loaded universe --------------------------- *)

(* The five cases are docs/conformance-gaps.md #1's own reproductions, which all
   built cleanly and reported `states: 1  edges: 0` before this. Each asserts the
   position, because the point of the rule is that the SECOND declaration is
   blamed — an error naming the first would send the author to the line that was
   fine. *)
let () =
  rejects_at "two types of one name in one schema"
    "(schema m (type v (a b)) (type v (c d)))\n\
     (instance i (of m))\n\
     (use m)\n\
     (initial i)"
    ~line:1 ~col:32 ~sub:"type `v` is already declared";
  rejects_at "two types of one name across two schemas"
    "(schema one (type v (a b)))\n\
     (schema two (type v (c d)))\n\
     (instance i (of two))\n\
     (use two)\n\
     (initial i)"
    ~line:2 ~col:19 ~sub:"type `v` is already declared";
  rejects_at "two entities of one name in one roster"
    "(schema m (type box) (type v (a b)))\n\
     (instance i (of m) (box e) (box e))\n\
     (use m)\n\
     (initial i)"
    ~line:2 ~col:33 ~sub:"entity `e` is already declared";
  rejects_at "two equations of one name"
    "(schema m (type v (a b)) (type box (arrow f (to v)) (arrow g (to v)))\n\
    \  (equation e (= box.f box.g))\n\
    \  (equation e (= box.g box.f)))\n\
     (instance i (of m) (box p) (f (p a)) (g (p a)))\n\
     (use m)\n\
     (initial i)"
    ~line:3 ~col:13 ~sub:"equation `e` is already declared";
  (* §7 says ONE namespace, not one per category, so a name taken by a type is
     not available to an entity either. This is the case none of the gap's
     reproductions covered, and the one most likely to be quietly dropped by a
     future refactor that keeps a set per kind. *)
  rejects_at "an entity may not take a name a type already holds"
    "(schema m (type box) (type v (a b)))\n\
     (instance i (of m) (box box))\n\
     (use m)\n\
     (initial i)"
    ~line:2 ~col:25 ~sub:"entity `box` is already declared as a type"

let () =
  print_string ("name tests: " ^ string_of_int !passed ^ " checks passed\n")
