(* Everything about resolving a [(load "FILE")]: WHERE the file is looked for,
   and WHO gets blamed when it is not found.

   Both halves are here because both were one bug. The CLI and the LSP process
   carried separate copies of the search order that drifted — the command line
   searched [core/stdlib], the editor searched [lib/] — so a model whose library
   lives in the dev checkout passed `pol check` while showing a red error in the
   buffer. And the error it showed carried no position, so it landed on line 1:
   a squiggle under the comment header while the real fault was the load. *)

open Pol_data
open Pol_syntax
open Pol_loadpath

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
    Load_path.candidates ~base:"tests/models/any_model.pol" "stdlib.pol"
  in
  check "load path: the including file's own directory is tried first"
    (List.nth c 0 = "tests/models/stdlib.pol");
  check "load path: the dev checkout's core/stdlib is searched"
    (List.mem "core/stdlib/stdlib.pol" c);
  check "load path: the installed layout is searched"
    (List.exists (contains_sub ~sub:"share/pol/lib") c);
  check "load path: every candidate names the file being loaded"
    (List.for_all (contains_sub ~sub:"stdlib.pol") c);
  check "load path: a bare name is never a candidate on its own"
    (not (List.mem "stdlib.pol" c))

(* [base] names the file doing the loading, so a load inside a library resolves
   against THAT library's directory — not the model's, and not the process CWD.
   This is what lets a library's own [(load …)] work wherever it is checked out. *)
let () =
  let c =
    Load_path.candidates ~base:"core/stdlib/politics.lib.pol" "stdlib.pol"
  in
  check "load path: resolution is relative to the including file"
    (List.nth c 0 = "core/stdlib/stdlib.pol")

let () =
  let e = Load_path.not_found "missing.pol" in
  check "load path: the exhausted-search message names the file"
    (e.Pol_data.Errors.msg = "cannot resolve load: missing.pol");
  check "load path: the exhausted-search error carries no position of its own"
    (e.Pol_data.Errors.pos = None)

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
  let files = [ ("a.pol", "; a comment line\n(load \"missing.pol\")") ] in
  match Loader.load_library (resolve_of files) "a.pol" with
  | Ok _ -> check "loader: an unresolvable load must fail" false
  | Error e ->
      check "loader: names the unresolvable file"
        (contains_sub ~sub:"missing.pol" e.Errors.msg);
      check "loader: blames the load datum, not the first line"
        (e.Errors.pos = Some { Errors.line = 2; col = 1 })

(* An error raised *inside* a loaded library keeps its own position; filling in
   the load site must not clobber one that is already there. *)
let () =
  let files =
    [
      ("a.pol", "(load \"b.pol\")");
      ("b.pol", "(schema s (type v (a b)))\n(use s)");
    ]
  in
  match Loader.load_library (resolve_of files) "a.pol" with
  | Ok _ ->
      check "loader: (use …) inside a loaded library must be rejected" false
  | Error e ->
      (* The load site is line 1 of a.pol; this error came from line 2 of
         b.pol. Asserting the line alone is what matters — that filling in the
         load site did not clobber a position the loaded file already gave. *)
      check "loader: keeps a position the loaded file already supplied"
        (match e.Errors.pos with Some q -> q.Errors.line = 2 | None -> false)

let () =
  print_string ("loadpath tests: " ^ string_of_int !passed ^ " checks passed\n")
