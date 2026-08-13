(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Rules tests (TR): the two functions in core/data/rules.ml — the substitution
   that lowers a positioned source guard into the kernel guard, and the ALL-CAPS
   variable test. Everything else in that module is types.

   No I/O and no model: [lower] is a pure substitution, so it is checked by
   comparing the [Model.guard] it builds against the one written out by hand. *)

open Writ_data

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

(* Positions are irrelevant to lowering — they exist so the CHECKER can blame a
   variable — so the fixtures use one throwaway position throughout. *)
let p = { Errors.file = None; line = 1; col = 1 }
let v name = Rules.Var (name, p)
let c name = Rules.Const (name, p)

let path root steps =
  { Rules.root; steps = List.map (fun s -> (s, p)) steps; pos = p }

(* A bound variable in the VALUE position of [is] is replaced by its binding. *)
let () =
  let g = Rules.Is (path (c "nabu") [ "reports-to" ], v "Y") in
  match Rules.lower g [ ("Y", "mid") ] with
  | Model.Is ({ Value.root = "nabu"; steps = [ "reports-to" ] }, Model.Lit "mid")
    ->
      check "lower: a bound variable is substituted in an is value" true
  | _ -> check "lower: a bound variable is substituted in an is value" false

(* A bound variable in the ROOT position too: the root is a term like any
   other, which is what lets a rule ask about an entity the body found. *)
let () =
  let g = Rules.Is (path (v "X") [ "reports-to" ], c "cabinet") in
  match Rules.lower g [ ("X", "nabu"); ("Y", "mid") ] with
  | Model.Is
      ({ Value.root = "nabu"; steps = [ "reports-to" ] }, Model.Lit "cabinet")
    ->
      check "lower: a bound variable is substituted in a path root" true
  | _ -> check "lower: a bound variable is substituted in a path root" false

(* A constant is carried through untouched, binding or no binding. *)
let () =
  let g = Rules.Is (path (c "nabu") [ "reports-to" ], c "mid") in
  match Rules.lower g [ ("mid", "SHOULD-NOT-APPLY") ] with
  | Model.Is ({ Value.root = "nabu"; steps = [ "reports-to" ] }, Model.Lit "mid")
    ->
      check "lower: a constant is left alone" true
  | _ -> check "lower: a constant is left alone" false

(* An unbound variable lowers to its own name rather than raising: [Model.Is]
   holds a raw string, so the result is a test that does not hold. Range
   restriction is what keeps this from happening; [lower] stays total. *)
let () =
  let g = Rules.Is (path (c "nabu") [ "reports-to" ], v "Y") in
  match Rules.lower g [] with
  | Model.Is (_, Model.Lit "Y") ->
      check "lower: an unbound variable lowers to itself" true
  | _ -> check "lower: an unbound variable lowers to itself" false

(* A nested shape: substitution reaches under [not], through the conjuncts of an
   [and], and into a [some] body — while the [some] BINDER, a kernel variable
   and not a rule variable, is left exactly as written. *)
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

(* [or] is the remaining shape; lowering it is the same recursion. *)
let () =
  let g = Rules.Or [ Rules.Defined (path (v "X") [ "role" ]) ] in
  match Rules.lower g [ ("X", "nabu") ] with
  | Model.Or [ Model.Defined { Value.root = "nabu"; steps = [ "role" ] } ] ->
      check "lower: or recurses into its disjuncts" true
  | _ -> check "lower: or recurses into its disjuncts" false

(* ALL-CAPS reads as a variable; anything holding a lower-case letter does not.
   [s3] is the case that matters: it is a legal entity name, and a rule that
   silently read it as a variable would answer a question nobody asked. *)
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
