(* [pol] — the standalone command line, the ONLY module with I/O besides the LSP
   process; everything below returns values and strings, which is what keeps the
   engine testable without a filesystem. It links the three engine libraries —
   [Pol_data] (the data model), [Pol_syntax] (the front end), and [Pol_runtime]
   (the interrogator) — and its only sibling module is [Help], the --help text.

   Exit status is the interface (kernel §18): 0 = answered, nothing failed;
   1 = a finding (a failed property, or a violated / unadmitted / stale law);
   2 = unreadable input (a missing file, a parse error, or a bad command line).

   The [(load "FILE")] resolver is built here, over the search order in
   [Pol_loadpath] (design D3) that the LSP process shares; there is no implicit
   prelude. *)

open Pol_data
open Pol_syntax
open Pol_runtime
open Pol_loadpath

let say s = print_string (s ^ "\n")

let die code msg =
  prerr_endline ("pol: " ^ msg);
  exit code

let read_file (path : string) : (string, string) result =
  match open_in_bin path with
  | exception Sys_error e -> Error e
  | ic ->
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      Ok s

(* The [(load "FILE")] resolver. The search ORDER is [Load_path] (design D3),
   shared with the LSP process so the editor and the command line can never
   disagree about where a library lives; the reading is here, because I/O is. *)
let make_resolve (base : string) : Loader.resolve =
 fun name ->
  let rec try_ = function
    | [] -> Error (Load_path.not_found name)
    | p :: rest -> (
        match read_file p with Ok s -> Ok s | Error _ -> try_ rest)
  in
  try_ (Load_path.candidates ~base name)

let load_model (resolve : Loader.resolve) (path : string) : Model.t =
  match Loader.read_model resolve path with
  | Error e -> die 2 (path ^ ": " ^ Errors.to_string e)
  | Ok m -> m

let build_space (path : string) (m : Model.t) : Space.t =
  match Space.build m with Error e -> die 2 (path ^ ": " ^ e) | Ok sp -> sp

let read_claims (resolve : Loader.resolve) (m : Model.t) (path : string) :
    Claims.t =
  match Loader.read_claims resolve m path with
  | Error e -> die 2 (path ^ ": " ^ Errors.to_string e)
  | Ok cl -> cl

(* ------------------------------------------------------------------ check *)

(* Emits the §15 build report always; with a [.claims] file it adds the §16.3
   acknowledgments, the §16.1 property outcomes, and the §16.2 queries at the
   initial situation. A finding — a failing property, or a violated / unadmitted
   / stale law — makes the exit status 1. *)
let check (model : string) (claims_path : string option) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let sp = build_space model m in
  say (Report.build sp);
  let failed =
    ref
      (List.exists
         (fun (l : Observe.law) -> l.violation <> None)
         (Observe.laws sp))
  in
  (match claims_path with
  | None -> ()
  | Some c ->
      let claims = read_claims resolve m c in
      let unadmitted = Observe.unadmitted sp claims in
      let stale = Observe.stale sp claims in
      if unadmitted <> [] || stale <> [] then failed := true;
      let acks = Report.acks unadmitted stale in
      if acks <> "" then say acks;
      List.iter
        (fun (p : Claims.property) ->
          let o = Checker.check sp p in
          (match o with Checker.Fails _ -> failed := true | _ -> ());
          say (Report.outcome sp p o))
        claims.Claims.props;
      List.iter
        (fun (q : Claims.query) ->
          say (Report.query_rows q 0 (Query.run sp q ())))
        claims.Claims.queries);
  flush stdout;
  if !failed then exit 1 else exit 0

(* ------------------------------------------------------------------ query *)

(* The queries live beside the model, in the sibling [.claims] file
   ([MODEL.pol] -> [MODEL.claims]); [pol query] names one and runs it. *)
let claims_beside (model : string) : string =
  Filename.remove_extension model ^ ".claims"

let state_at (sp : Space.t) (spec : string option) : int * State.t =
  match spec with
  | None -> (0, sp.Space.initial)
  | Some s -> (
      match int_of_string_opt s with
      | Some i when i >= 0 && i < Array.length sp.Space.states ->
          (i, sp.Space.states.(i))
      | _ -> die 2 ("--at expects a state index in range: " ^ s))

let query (model : string) (name : string) (at : string option) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let sp = build_space model m in
  let cpath = claims_beside model in
  let claims = read_claims resolve m cpath in
  let q =
    match
      List.find_opt (fun (q : Claims.query) -> q.name = name) claims.queries
    with
    | Some q -> q
    | None -> die 2 ("no query named `" ^ name ^ "` in " ^ cpath)
  in
  let idx, st = state_at sp at in
  say (Report.query_rows q idx (Query.run sp q ~at:st ()));
  flush stdout;
  exit 0

(* ----------------------------------------------------------------- control *)

(* Emits the model's move list as data: an instance of the standard library's
   [quiver] schema (kernel §17). [Control.quiver] builds the string; [bin] does
   the printing. The instance name is the model's basename + [-control]. *)
let control (model : string) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let name = Filename.remove_extension (Filename.basename model) in
  say (Control.quiver name m);
  flush stdout;
  exit 0

(* ----------------------------------------------------------------- compare *)

(* [pol compare OLD NEW [--map M]] (kernel §17): the guarantees to weigh come
   from OLD's sibling [.claims] (the old contract), applied to BOTH models;
   [Compare.run] classifies each equation/property preserved / LOST / gained.
   A LOST is a finding -> exit 1. All I/O (files, git, the [--map] parse) lives
   here; [Compare] is a pure string builder. *)

let empty_claims : Claims.t = { props = []; queries = []; accepts = [] }

(* Parse a [--map] file: bare [(map X => Y)] rename datums, front end in bin. *)
let parse_map (path : string) : (string * string) list =
  match read_file path with
  | Error e -> die 2 (path ^ ": " ^ e)
  | Ok src -> (
      match Reader.read_string src with
      | Error e -> die 2 (path ^ ": " ^ Errors.to_string e)
      | Ok datums ->
          List.map
            (function
              | Reader.List
                  ( [
                      Reader.Atom ("map", _);
                      Reader.Atom (x, _);
                      Reader.Atom ("=>", _);
                      Reader.Atom (y, _);
                    ],
                    _ ) ->
                  (x, y)
              | d ->
                  die 2
                    ("bad map datum, want (map X => Y): " ^ Reader.to_string d))
            datums)

let claims_for (resolve : Loader.resolve) (m : Model.t) (old_path : string) :
    Claims.t =
  let cpath = claims_beside old_path in
  if Sys.file_exists cpath then read_claims resolve m cpath else empty_claims

let emit_compare (old_sp : Space.t) (new_sp : Space.t) (claims : Claims.t)
    (mp : (string * string) list) =
  let report, any_lost = Compare.run old_sp new_sp claims mp in
  say report;
  flush stdout;
  if any_lost then exit 1 else exit 0

let compare (old_p : string) (new_p : string) (map_p : string option) =
  let mp = match map_p with None -> [] | Some p -> parse_map p in
  let old_r = make_resolve old_p and new_r = make_resolve new_p in
  let old_m = load_model old_r old_p in
  let old_sp = build_space old_p old_m in
  let new_sp = build_space new_p (load_model new_r new_p) in
  emit_compare old_sp new_sp (claims_for old_r old_m old_p) mp

(* Fetch a revision of a file with [git show REV:path] into a temp file, read
   it back, and delete it — Stdlib only ([Sys.command] + [Filename.temp_file]),
   no [unix] dependency. *)
let git_show (rev : string) (path : string) : string =
  let tmp = Filename.temp_file "pol-git-" ".pol" in
  let cmd =
    "git show "
    ^ Filename.quote (rev ^ ":" ^ path)
    ^ " > " ^ Filename.quote tmp ^ " 2>/dev/null"
  in
  if Sys.command cmd <> 0 then (
    Sys.remove tmp;
    die 2 ("git show failed for " ^ rev ^ ":" ^ path));
  match read_file tmp with
  | Ok s ->
      Sys.remove tmp;
      s
  | Error e ->
      Sys.remove tmp;
      die 2 e

(* A resolver that serves [content] as the model's own basename (the revision's
   source) and defers every [(load …)] target to the working tree — a
   documented simplification: cross-revision library drift is not tracked. *)
let git_resolve (model : string) (content : string) : Loader.resolve =
  let base = make_resolve model in
  let entry = Filename.basename model in
  fun name -> if String.equal name entry then Ok content else base name

let compare_git (rev1 : string) (rev2 : string) (model : string)
    (map_p : string option) =
  let mp = match map_p with None -> [] | Some p -> parse_map p in
  let r1 = git_resolve model (git_show rev1 model) in
  let r2 = git_resolve model (git_show rev2 model) in
  let old_m = load_model r1 model in
  let old_sp = build_space model old_m in
  let new_sp = build_space model (load_model r2 model) in
  emit_compare old_sp new_sp (claims_for r1 old_m model) mp

(* ------------------------------------------------------------------- main *)

let usage =
  String.concat "\n"
    [
      "usage:";
      "  pol check   MODEL [--claims FILE]";
      "  pol query   MODEL NAME [--at STATE]";
      "  pol compare OLD NEW [--map M]";
      "  pol compare --git REV1 REV2 MODEL [--map M]";
      "  pol control MODEL";
      "  pol --help | -h";
      "  pol --version | -V";
    ]

(* [pol], [pol -h], [pol --help] and [pol help] print the full help and exit 0;
   a misuse prints the short [usage] to stderr and exits 2. *)
let help () =
  print_string Help.text;
  exit 0

(* [Version.v] is generated by dune from the package version in dune-project, so
   the binary, the opam package and the release tarball cannot disagree about
   which pol this is — the first question asked of any installed tool, and the
   one a hand-maintained constant always eventually answers wrongly. *)
let version () =
  say ("pol " ^ Version.v);
  say "Copyright (C) 2026 Alex Kunich.  License AGPL-3.0-or-later.";
  say "This is free software: you are free to change and redistribute it.";
  say "There is NO WARRANTY, to the extent permitted by law.";
  exit 0

let () =
  match Array.to_list Sys.argv with
  | [ _ ] | [ _; ("-h" | "--help" | "help") ] -> help ()
  | [ _; ("-V" | "--version" | "version") ] -> version ()
  | _ :: "check" :: model :: rest -> (
      match rest with
      | [] -> check model None
      | [ "--claims"; c ] -> check model (Some c)
      | _ -> die 2 usage)
  | _ :: "query" :: model :: name :: rest -> (
      match rest with
      | [] -> query model name None
      | [ "--at"; s ] -> query model name (Some s)
      | _ -> die 2 usage)
  | [ _; "control"; model ] -> control model
  | _ :: "compare" :: rest -> (
      match rest with
      | "--git" :: r1 :: r2 :: model :: mrest -> (
          match mrest with
          | [] -> compare_git r1 r2 model None
          | [ "--map"; mp ] -> compare_git r1 r2 model (Some mp)
          | _ -> die 2 usage)
      | old_p :: new_p :: mrest -> (
          match mrest with
          | [] -> compare old_p new_p None
          | [ "--map"; mp ] -> compare old_p new_p (Some mp)
          | _ -> die 2 usage)
      | _ -> die 2 usage)
  | _ -> die 2 usage
