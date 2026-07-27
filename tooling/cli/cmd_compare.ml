(* [Cmd_compare] — the [pol compare] verb and its [--git] form. It is the
   largest of the verbs because it is the one with I/O of its own: two models
   instead of one, a [--map] file to parse, and a shell out to git. Keeping all
   of that here leaves [Compare] a pure string builder and [Pol] a dispatch.

   [pol compare OLD NEW [--map M]] (kernel §17): the guarantees to weigh come
   from OLD's sibling [.claims] (the old contract), applied to BOTH models;
   [Compare.run] classifies each equation/property preserved / LOST / gained.
   A LOST is a finding -> exit 1. *)

open Pol_data
open Pol_syntax
open Pol_runtime
open Cli_io

let empty_claims : Claims.t = { props = []; queries = []; accepts = [] }

(* Parse a [--map] file: bare [(map X => Y)] rename datums, front end in bin. *)
let parse_map (path : string) : (string * string) list =
  match read_file path with
  | Error e -> die 2 (path ^ ": " ^ e)
  | Ok src -> (
      match Reader.read_string ~file:path src with
      | Error e -> die 2 (located path e)
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

let run (old_p : string) (new_p : string) (map_p : string option) =
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

let run_git (rev1 : string) (rev2 : string) (model : string)
    (map_p : string option) =
  let mp = match map_p with None -> [] | Some p -> parse_map p in
  let r1 = git_resolve model (git_show rev1 model) in
  let r2 = git_resolve model (git_show rev2 model) in
  let old_m = load_model r1 model in
  let old_sp = build_space model old_m in
  let new_sp = build_space model (load_model r2 model) in
  emit_compare old_sp new_sp (claims_for r1 old_m model) mp
