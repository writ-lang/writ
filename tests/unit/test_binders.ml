(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Binder REJECTION tests. Split from test_names.ml for the reason that suite
   was itself split from test_data.ml — the 300-line cap — and they belong
   together conceptually: this is §7's namespace rule reaching the one
   construct in the language that binds a name locally.

   Same shape as its parent suite: a source string, the real reader, expander
   and parser, and the exact line:col the binder is blamed at. *)

open Writ_data
open Writ_syntax

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

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

(* §7's "There is no shadowing" was silent about the one construct in the
   language that binds a name locally. [Eval.eval_path] resolves a chain root
   through the binding environment BEFORE the roster, so a binder spelled like
   an entity silently hides it — the same invisible winner-picking gap 1 closed
   for declarations. Binders stay reusable across DISJOINT scopes; what is
   forbidden is colliding with a global name. *)
let () =
  rejects_at "a binder may not shadow an entity"
    "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
     (instance i m (box lo (f a)) )\n\
     (transition t (when (some (lo box) (is lo.f a))) (do (set lo.f b)))\n\
     (use m) (initial i)"
    ~line:3 ~col:28 ~sub:"binder `lo`";
  check "the same binder name in two disjoint scopes still builds"
    (Result.is_ok
       (decodes
          "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
           (instance i m (box p (f a)) (box q (f a)) )\n\
           (transition s (when (some (x box) (is x.f a))) (do (set p.f b)))\n\
           (transition t (when (some (x box) (is x.f b))) (do (set q.f b)))\n\
           (use m) (initial i)"))

(* The same rule reached from the other side: a .claims file is parsed against
   an already-built model (§16), so its binders are checked against the model's
   names rather than a second scan of the universe. *)
let decodes_claims model_src claims_src =
  match decodes model_src with
  | Error e -> Error e
  | Ok m -> (
      match Reader.read_string claims_src with
      | Error e -> Error e
      | Ok ds -> (
          match Expander.expand ds with
          | Error e -> Error e
          | Ok ex -> (
              match Claims_parser.parse m.Model.schema m.Model.initial ex with
              | Error e -> Error e
              | Ok _ -> Ok ())))

let model_src =
  "(schema m (type v (a b)) (type box (arrow f (to v))))\n\
   (instance i m (box lo (f a)) )\n\
   (use m) (initial i)"

let () =
  (match decodes_claims model_src "(query q (where (lo box)) (is lo.f a))" with
  | Ok () ->
      check
        "a query binder may not shadow an entity — accepted, but must be \
         rejected"
        false
  | Error e ->
      check "a query binder may not shadow an entity"
        (contains_sub ~sub:"binder `lo`" e.Errors.msg));
  check "a query binder that shadows nothing still builds"
    (Result.is_ok
       (decodes_claims model_src "(query q (where (x box)) (is x.f a))"))

let () =
  print_string ("binder tests: " ^ string_of_int !passed ^ " checks passed\n")
