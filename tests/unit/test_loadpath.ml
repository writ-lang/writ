(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Everything about resolving a [(load "FILE")]: WHERE the file is looked for,
   and WHO gets blamed when it is not found.

   Both halves are here because both were one bug. The CLI and the LSP process
   carried separate copies of the search order that drifted — the command line
   searched [core/stdlib], the editor searched [lib/] — so a model whose library
   lives in the dev checkout passed `writ check` while showing a red error in the
   buffer. And the error it showed carried no position, so it landed on line 1:
   a squiggle under the comment header while the real fault was the load. *)

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

(* [base] names the file doing the loading, so a load inside a library resolves
   against THAT library's directory — not the model's, and not the process CWD.
   This is what lets a library's own [(load …)] work wherever it is checked out. *)
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

(* A resolver is handed a name, not a datum, so the error it returns carries no
   position. The load datum's position is known to [inline], which must fill it
   in: a positionless error lands on line 1 in an editor, and line 1 is usually
   a comment — a squiggle pointing at prose while the real fault is the load. *)
let () =
  let files = [ ("a.writ", "; a comment line\n(load \"missing.writ\")") ] in
  match Loader.load_library (resolve_of files) "a.writ" with
  | Ok _ -> check "loader: an unresolvable load must fail" false
  | Error e ->
      check "loader: names the unresolvable file"
        (contains_sub ~sub:"missing.writ" e.Errors.msg);
      check "loader: blames the load datum, not the first line"
        (e.Errors.pos = Some { Errors.file = Some "a.writ"; line = 2; col = 1 })

(* An error raised *inside* a loaded library keeps its own position; filling in
   the load site must not clobber one that is already there. *)
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
      (* The load site is line 1 of a.writ; this error came from line 2 of
         b.writ. Both halves matter — that filling in the load site did not
         clobber a position the loaded file already gave, and that the position
         still says which file that was. *)
      check "loader: keeps a position the loaded file already supplied"
        (match e.Errors.pos with
        | Some q -> q.Errors.line = 2 && q.Errors.file = Some "b.writ"
        | None -> false)

(* --- which file the coordinates index (conformance gap 3) ------------------ *)

(* [inline] splices a loaded library's datums into the loading file's list, so
   once it has run the position is the only thing that still knows which file its
   line and column belong to. While the file was supplied by whoever PRINTED the
   error instead, that was the path on the command line, and the two combined
   into a coordinate no file fits: the position below is column 55 of an 84-column
   line in the library, reported against a loading file whose line 1 has 16
   columns. That is why a wrong filename is worse than none — an absent one sends
   the reader looking, a wrong one sends them somewhere definite and sounds sure. *)
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

(* The common case must be no worse. A fault in the file the caller asked about
   names that file under the name the CALLER used — [resolve] is handed a bare
   basename (design D3), but a path is what the reader of the message can act
   on, so the two are not the same string and the position carries the useful
   one. *)
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

(* Text read with no file is not a degraded reading: a query typed on a command
   line and an unnamed buffer have real positions and no name. [file = None] has
   to keep meaning "unnamed" rather than "unpositioned", or something downstream
   prints a filename it was never given. *)
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
