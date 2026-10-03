(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Resolving a [(load "FILE")]: where the file is looked for (one search order
   for the CLI and the LSP), and who is blamed when it is not found. *)

open Writ_data
open Writ_syntax
open Writ_loadpath

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

let () =
  let c =
    Load_path.candidates ~base:"tests/models/any_model.writ" "stdlib.writ"
  in
  check "load path: the including file's own directory is tried first"
    (List.nth c 0 = "tests/models/stdlib.writ");
  check "load path: the dev checkout's core/stdlib is searched"
    (List.mem "core/stdlib/stdlib.writ" c);
  check "load path: the installed layout is searched"
    (List.exists (contains_sub ~sub:"share/writ/lib") c);
  check "load path: every candidate names the file being loaded"
    (List.for_all (contains_sub ~sub:"stdlib.writ") c);
  check "load path: a bare name is never a candidate on its own"
    (not (List.mem "stdlib.writ" c))

(* A load inside a library resolves against that library's directory. *)
let () =
  let c =
    Load_path.candidates ~base:"core/stdlib/politics.lib.writ" "stdlib.writ"
  in
  check "load path: resolution is relative to the including file"
    (List.nth c 0 = "core/stdlib/stdlib.writ")

let () =
  let e = Load_path.not_found "missing.writ" in
  check "load path: the exhausted-search message names the file"
    (e.Writ_data.Errors.msg = "cannot resolve load: missing.writ");
  check "load path: the exhausted-search error carries no position of its own"
    (e.Writ_data.Errors.pos = None)

(* --- who gets blamed: the loader fills in the load datum's position --------- *)

let resolve_of files name : (string, Errors.t) result =
  match List.assoc_opt name files with
  | Some s -> Ok s
  | None -> Errors.err ("no such file: " ^ name)

(* A resolver sees a name, not a datum, so [inline] fills in the load's
   position; without it the error lands on line 1. *)
let () =
  let files = [ ("a.writ", "; a comment line\n(load \"missing.writ\")") ] in
  match Loader.load_library (resolve_of files) "a.writ" with
  | Ok _ -> check "loader: an unresolvable load must fail" false
  | Error e ->
      check "loader: names the unresolvable file"
        (contains_sub ~sub:"missing.writ" e.Errors.msg);
      check "loader: blames the load datum, not the first line"
        (e.Errors.pos = Some { Errors.file = Some "a.writ"; line = 2; col = 1 })

(* An error inside a loaded library keeps its own position. *)
let () =
  let files =
    [
      ("a.writ", "(load \"b.writ\")");
      ("b.writ", "(schema s (type v (a b)))\n(use s)");
    ]
  in
  match Loader.load_library (resolve_of files) "a.writ" with
  | Ok _ ->
      check "loader: (use …) inside a loaded library must be rejected" false
  | Error e ->
      check "loader: keeps a position the loaded file already supplied"
        (match e.Errors.pos with
        | Some q -> q.Errors.line = 2 && q.Errors.file = Some "b.writ"
        | None -> false)

(* --- which file the coordinates index (conformance gap 3) ------------------ *)

(* After [inline], only the position knows which file its line and column
   index; a wrong filename is worse than none. *)
let () =
  let lib =
    "(schema lib (type v (a b)) (type box (arrow f (to v)) (equation e (= \
     box.f box.f))))"
  in
  let model =
    String.concat "\n"
      [
        "(load \"lib.writ\")";
        "(schema mine (type w (c d)))";
        "(instance i mine)";
        "(use mine)";
        "(initial i)";
      ]
  in
  let files = [ ("m.writ", model); ("lib.writ", lib) ] in
  match Loader.read_model (resolve_of files) "m.writ" with
  | Ok _ ->
      check "loader: an (equation …) inside a (type …) body must be rejected"
        false
  | Error e -> (
      match e.Errors.pos with
      | None ->
          check "loader: a fault inside a loaded library must be positioned"
            false
      | Some p ->
          check "loader: a fault inside a loaded library names that library"
            (p.Errors.file = Some "lib.writ");
          check "loader: the position indexes the library, at the bad datum"
            (p.Errors.line = 1 && p.Errors.col = 55
            && String.sub lib (p.Errors.col - 1) 9 = "(equation");
          check "loader: the loading file could not hold that coordinate"
            (String.length (List.hd (String.split_on_char '\n' model))
            < p.Errors.col);
          check "loader: the rendered diagnostic names the library"
            (contains_sub ~sub:"lib.writ:1:55: " (Errors.to_string e)))

(* [resolve] gets a bare basename (design D3), but the message names the path
   the caller used. *)
let () =
  let model =
    String.concat "\n"
      [
        "(schema mine (type v (a b)) (type box (arrow f (to v)) (equation e (= \
         box.f box.f))))";
        "(instance i mine)";
        "(use mine)";
        "(initial i)";
      ]
  in
  match Loader.read_model (resolve_of [ ("m.writ", model) ]) "sub/m.writ" with
  | Ok _ -> check "loader: the same-file fault must be rejected" false
  | Error e ->
      check "loader: a same-file fault names the path the caller gave"
        (match e.Errors.pos with
        | Some p -> p.Errors.file = Some "sub/m.writ" && p.Errors.line = 1
        | None -> false)

(* [file = None] means "unnamed", not "unpositioned". *)
let () =
  match Reader.read_string "(schema s (type v (a b))" with
  | Ok _ -> check "reader: an unclosed list must be rejected" false
  | Error e ->
      check "reader: text read without a name has a position and no file"
        (e.Errors.pos = Some { Errors.file = None; line = 1; col = 1 });
      check "reader: an unnamed position renders as a bare line:col"
        (contains_sub ~sub:"1:1: " (Errors.to_string e)
        && not (contains_sub ~sub:".writ" (Errors.to_string e)))

let () =
  print_string ("loadpath tests: " ^ string_of_int !passed ^ " checks passed\n")
