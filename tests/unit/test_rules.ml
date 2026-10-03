(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Rules tests: [Rules.lower], a pure substitution checked against guards
   written by hand, and the ALL-CAPS variable test. *)

open Writ_data

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let p = { Errors.file = None; line = 1; col = 1 }
let v name = Rules.Var (name, p)
let c name = Rules.Const (name, p)

let path root steps =
  { Rules.root; steps = List.map (fun s -> (s, p)) steps; pos = p }

let () =
  let g = Rules.Is (path (c "nabu") [ "reports-to" ], v "Y") in
  match Rules.lower g [ ("Y", "mid") ] with
  | Model.Is ({ Value.root = "nabu"; steps = [ "reports-to" ] }, Model.Lit "mid")
    ->
      check "lower: a bound variable is substituted in an is value" true
  | _ -> check "lower: a bound variable is substituted in an is value" false

(* The root is a term like any other. *)
let () =
  let g = Rules.Is (path (v "X") [ "reports-to" ], c "cabinet") in
  match Rules.lower g [ ("X", "nabu"); ("Y", "mid") ] with
  | Model.Is
      ({ Value.root = "nabu"; steps = [ "reports-to" ] }, Model.Lit "cabinet")
    ->
      check "lower: a bound variable is substituted in a path root" true
  | _ -> check "lower: a bound variable is substituted in a path root" false

let () =
  let g = Rules.Is (path (c "nabu") [ "reports-to" ], c "mid") in
  match Rules.lower g [ ("mid", "SHOULD-NOT-APPLY") ] with
  | Model.Is ({ Value.root = "nabu"; steps = [ "reports-to" ] }, Model.Lit "mid")
    ->
      check "lower: a constant is left alone" true
  | _ -> check "lower: a constant is left alone" false

(* An unbound variable lowers to its own name; [lower] stays total. *)
let () =
  let g = Rules.Is (path (c "nabu") [ "reports-to" ], v "Y") in
  match Rules.lower g [] with
  | Model.Is (_, Model.Lit "Y") ->
      check "lower: an unbound variable lowers to itself" true
  | _ -> check "lower: an unbound variable lowers to itself" false

(* The [some] binder, a kernel variable, is left as written. *)
let () =
  let g =
    Rules.Not
      ( Rules.And
          [
            Rules.Defined (path (v "X") [ "reports-to" ]);
            Rules.Some_
              ("a", "account", Rules.Is (path (c "a") [ "role" ], v "R"), p);
          ],
        p )
  in
  match Rules.lower g [ ("X", "nabu"); ("R", "admin") ] with
  | Model.Not
      (Model.And
         [
           Model.Defined { Value.root = "nabu"; steps = [ "reports-to" ] };
           Model.Some_
             ( "a",
               "account",
               Model.Is
                 ({ Value.root = "a"; steps = [ "role" ] }, Model.Lit "admin")
             );
         ]) ->
      check "lower: substitutes through not/and/some, binder untouched" true
  | _ -> check "lower: substitutes through not/and/some, binder untouched" false

let () =
  let g = Rules.Or [ Rules.Defined (path (v "X") [ "role" ]) ] in
  match Rules.lower g [ ("X", "nabu") ] with
  | Model.Or [ Model.Defined { Value.root = "nabu"; steps = [ "role" ] } ] ->
      check "lower: or recurses into its disjuncts" true
  | _ -> check "lower: or recurses into its disjuncts" false

(* [s3] is a legal entity name, not a variable. *)
let () =
  check "is_var: X" (Rules.is_var "X");
  check "is_var: SOME-VAR" (Rules.is_var "SOME-VAR");
  check "is_var: not x" (not (Rules.is_var "x"));
  check "is_var: not some-var" (not (Rules.is_var "some-var"));
  check "is_var: not s3" (not (Rules.is_var "s3"));
  check "is_var: not the empty atom" (not (Rules.is_var ""));
  check "is_var: not a digits-only atom" (not (Rules.is_var "3"))

let () =
  print_string ("rules tests: " ^ string_of_int !passed ^ " checks passed\n")
