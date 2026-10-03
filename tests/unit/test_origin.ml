(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Provenance pragmas (docs/bridges.md): a `; writ:origin TEXT` comment is
   echoed beside the move or law it precedes, and changes nothing else. *)

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

let repo_root () =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.writ") then dir
    else if n = 0 then dir
    else up (Filename.dirname dir) (n - 1)
  in
  up (Sys.getcwd ()) 8

let read p =
  match open_in_bin p with
  | exception Sys_error _ -> None
  | ic ->
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      Some s

let resolve : Loader.resolve =
 fun name ->
  let root = repo_root () in
  match read (Filename.concat root ("tests/unit/fixtures/" ^ name)) with
  | Some s -> Ok s
  | None -> Error { Errors.pos = None; msg = "cannot resolve " ^ name }

let () =
  (* The reader keeps pragmas by line and drops other comments. *)
  let text =
    Option.get
      (read (Filename.concat (repo_root ()) "tests/unit/fixtures/origin.writ"))
  in
  (match Reader.read_string_with_pragmas ~file:"origin.writ" text with
  | Ok (datums, pragmas) ->
      check "reader: datums are read as before" (List.length datums = 8);
      check "reader: three pragmas, none of the plain comments"
        (List.length pragmas = 3);
      check "reader: a pragma carries its line and its text after the prefix"
        (List.mem (7, "origin rules.txt:7") pragmas)
  | Error e -> check ("reader: " ^ Errors.to_string e) false);
  let m =
    match Loader.read_model resolve "origin.writ" with
    | Ok m -> m
    | Error e ->
        check ("read_model: " ^ Errors.to_string e) false;
        exit 1
  in
  let origin_of name =
    List.find_map
      (fun (t : Model.transition) ->
        if t.name = Some name then Some t.origin else None)
      m.Model.transitions
  in
  check "a pragma above a transition is its origin"
    (origin_of "raise" = Some (Some "switches.yaml:3"));
  check "a pragma above a form invocation reaches the move it expands into"
    (origin_of "lower" = Some (Some "switches.yaml:9"));
  check "a plain comment above a move is not an origin"
    (origin_of "blink" = Some None);
  check "a pragma above an equation inside the schema is the law's origin"
    (List.exists
       (fun (e : Schema.equation) ->
         e.name = "never-both" && e.origin = Some "rules.txt:7")
       m.Model.schema.Schema.equations);
  let sp = match Space.build m with Ok sp -> sp | Error e -> failwith e in
  (* Echoed beside the move in a witness, and beside the law. *)
  let p : Claims.property =
    {
      name = "lit";
      text = "";
      modality = Claims.Possible;
      formula =
        Model.Is ({ Value.root = "l"; steps = [ "pos" ] }, Model.Lit "on");
      show = [];
    }
  in
  let out = Report.outcome sp p (Checker.check sp p) in
  check "report: the witness step carries the origin in brackets"
    (contains ~sub:"1. raise   → #1   l.pos: off → on   [switches.yaml:3]" out);
  let j = Json.to_string (Report_json.property sp p (Checker.check sp p)) in
  check "json: the step carries the origin"
    (contains ~sub:"\"origin\":\"switches.yaml:3\"" j);
  print_string ("test_origin: " ^ string_of_int !passed ^ " checks passed\n")
