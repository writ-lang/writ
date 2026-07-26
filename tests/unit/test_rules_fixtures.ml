(* Rules fixture tests (TRF): the .rules files on disk, read through [Loader]
   and judged by [Rules_check.check].

   The seam this is split at is the input, not the subject. Its sibling
   test_rules_check.ml builds every program from a string literal in the test
   itself, so a case is read where it is asserted; everything here instead
   drives a FILE under tests/unit/fixtures/, which needs the loader, a resolver
   and a repo-root climb, and which the run's fitness gates then drive again
   through the CLI. Keeping the two apart keeps each file's preamble honest
   about what it needs — and keeps both under the 300-line limit. *)

open Pol_data
open Pol_syntax

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

let repo_root () =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.pol") then dir
    else if n = 0 then dir
    else up (Filename.dirname dir) (n - 1)
  in
  up (Sys.getcwd ()) 8

let resolve : Loader.resolve =
 fun name ->
  let p = Filename.concat (repo_root ()) ("tests/unit/fixtures/" ^ name) in
  match open_in_bin p with
  | exception Sys_error _ ->
      Error { Errors.pos = None; msg = "cannot resolve " ^ name }
  | ic ->
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      Ok s

let model_file name =
  match Loader.read_model resolve name with
  | Ok m -> m
  | Error e -> failwith (name ^ ": " ^ Errors.to_string e)

let fixture m name =
  match Loader.read_rules resolve m name with
  | Error e -> Error e
  | Ok t -> Rules_check.check m t

let fixture_rejected name m file ~sub =
  match fixture m file with
  | Ok _ -> check (file ^ ": expected a rejection") false
  | Error e ->
      check (file ^ " is positioned") (e.Errors.pos <> None);
      check
        (file ^ " says `" ^ sub ^ "` (" ^ name ^ "), not " ^ e.Errors.msg)
        (contains_sub ~sub e.Errors.msg)

let () =
  let base = model_file "rules_base.pol" in
  (match fixture base "closure.rules" with
  | Ok _ -> check "closure.rules is a legal program" true
  | Error e -> check ("closure.rules: " ^ Errors.to_string e) false);
  (match fixture base "rules_empty.rules" with
  | Ok p ->
      check "rules_empty.rules declares a relation with no rules"
        (p.Rules.rules = [] && List.length p.Rules.relations = 1)
  | Error e -> check ("rules_empty.rules: " ^ Errors.to_string e) false);
  fixture_rejected "stratification" base "neg_cycle.rules" ~sub:"negation cycle";
  fixture_rejected "sorts" base "untyped_var.rules" ~sub:"cannot be inferred";
  fixture_rejected "range restriction" base "unsafe.rules" ~sub:"not bound";
  fixture_rejected "the built-in namespace" base "redefine_builtin.rules"
    ~sub:"built-in";
  fixture_rejected "the ALL-CAPS collision"
    (model_file "caps_base.pol")
    "caps_collision.rules" ~sub:"reads as a variable here but names an element"

let () =
  print_string
    ("rules fixture tests: " ^ string_of_int !passed ^ " checks passed\n")
