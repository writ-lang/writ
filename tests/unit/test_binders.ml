(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Binder rejection tests: §7's namespace rule reaching the one construct that
   binds a name locally. Same harness as test_names.ml. *)

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

(* A chain root resolves through bindings before the roster, so a binder
   spelled like an entity would hide it. *)
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

(* A .claims binder is checked against the built model's names (§16). *)
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
