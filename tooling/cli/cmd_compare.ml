(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ compare OLD NEW [--map M]] and its [--git] form (kernel §17). OLD's
   sibling [.claims] is the contract, applied to both models; [Compare.run]
   classifies each equation/property as preserved, LOST or gained. A LOST is
   a finding: exit 1. *)

open Writ_data
open Writ_syntax
open Writ_runtime
open Cli_io

let empty_claims : Claims.t = { props = []; queries = []; accepts = [] }

(* A [--map] file: bare [(map X => Y)] rename datums. *)
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

let emit_compare ~(json : bool) (old_sp : Space.t) (new_sp : Space.t)
    (claims : Claims.t) (mp : (string * string) list) =
  let report, any_lost = Compare.run old_sp new_sp claims mp in
  let code = if any_lost then 1 else 0 in
  if json then
    let equations = Compare.equation_rows mp old_sp new_sp in
    let properties = Compare.property_rows mp old_sp new_sp claims in
    say
      (Json.to_string
         (Report_json.compare ~new_sp ~equations ~properties ~exit:code))
  else say report;
  flush stdout;
  exit code

let run ?(json = false) (old_p : string) (new_p : string)
    (map_p : string option) =
  let mp = match map_p with None -> [] | Some p -> parse_map p in
  let old_r = make_resolve old_p and new_r = make_resolve new_p in
  let old_m = load_model old_r old_p in
  let old_sp = build_space old_p old_m in
  let new_sp = build_space new_p (load_model new_r new_p) in
  emit_compare ~json old_sp new_sp (claims_for old_r old_m old_p) mp

(* [git show REV:path] via a temp file, to stay Stdlib-only (no [unix]). *)
let git_show (rev : string) (path : string) : string =
  let tmp = Filename.temp_file "writ-git-" ".writ" in
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

(* Serves the revision's source as the model and every [(load …)] from the
   working tree: library changes across revisions are not tracked. *)
let git_resolve (model : string) (content : string) : Loader.resolve =
  let base = make_resolve model in
  let entry = Filename.basename model in
  fun name -> if String.equal name entry then Ok content else base name

let run_git ?(json = false) (rev1 : string) (rev2 : string) (model : string)
    (map_p : string option) =
  let mp = match map_p with None -> [] | Some p -> parse_map p in
  let r1 = git_resolve model (git_show rev1 model) in
  let r2 = git_resolve model (git_show rev2 model) in
  let old_m = load_model r1 model in
  let old_sp = build_space model old_m in
  let new_sp = build_space model (load_model r2 model) in
  emit_compare ~json old_sp new_sp (claims_for r1 old_m model) mp
