(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Compare tests (T3): load the fixture pair through the real front end, run
   [Compare.run], and assert the §17 classification — a genuinely lost guarantee
   is reported LOST with the new model's witness, and a preserved equation stays
   preserved. Stdlib only; the resolver reads tests/unit/fixtures then core/stdlib. *)

open Writ_data
open Writ_syntax
open Writ_runtime

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let contains ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

(* Ascend from the cwd to the repo root (the nearest ancestor with
   core/stdlib/stdlib.writ), then resolve a name under core/stdlib/ then
   tests/unit/fixtures/ — dune runs the test from _build/default/tests/unit, not
   the repo root. *)
let repo_root () =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.writ") then dir
    else if n = 0 then dir
    else up (Filename.dirname dir) (n - 1)
  in
  up (Sys.getcwd ()) 8

let resolve : Loader.resolve =
 fun name ->
  let root = repo_root () in
  let read p =
    match open_in_bin p with
    | exception Sys_error _ -> None
    | ic ->
        let n = in_channel_length ic in
        let s = really_input_string ic n in
        close_in ic;
        Some s
  in
  let rec go = function
    | [] -> Error { Errors.pos = None; msg = "cannot resolve " ^ name }
    | p :: rest -> ( match read p with Some s -> Ok s | None -> go rest)
  in
  go
    [
      Filename.concat root ("core/stdlib/" ^ name);
      Filename.concat root ("tests/unit/fixtures/" ^ name);
    ]

let model path =
  match Loader.read_model resolve path with
  | Ok m -> m
  | Error e ->
      check ("read_model " ^ path ^ ": " ^ Errors.to_string e) false;
      exit 1

let space path m =
  match Space.build m with
  | Ok sp -> sp
  | Error e ->
      check ("build " ^ path ^ ": " ^ e) false;
      exit 1

let () =
  let old_m = model "compare_old.writ" in
  let new_m = model "compare_new.writ" in
  let old_sp = space "compare_old.writ" old_m in
  let new_sp = space "compare_new.writ" new_m in
  let claims =
    match Loader.read_claims resolve old_m "compare_old.claims" with
    | Ok c -> c
    | Error e ->
        check ("read_claims: " ^ Errors.to_string e) false;
        exit 1
  in
  let report, any_lost = Compare.run old_sp new_sp claims [] in
  check "compare: a guarantee is LOST" any_lost;
  check "compare: report shows the LOST status" (contains ~sub:"LOST" report);
  check "compare: LOST row carries a witness" (contains ~sub:"witness:" report);
  check "compare: report has a properties section"
    (contains ~sub:"properties:" report);
  (* identity map on matching schemas changes nothing *)
  let report', any_lost' = Compare.run old_sp new_sp claims [] in
  check "compare: deterministic" (report = report' && any_lost = any_lost');
  print_string ("compare tests: " ^ string_of_int !passed ^ " checks passed\n")
