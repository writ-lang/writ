(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Text in, squiggles out, from the engine's own front end; the buffer's [Role]
   picks the [Loader] entry. The front end stops at its first error, so this
   yields at most one diagnostic. *)

open Writ_data
open Writ_syntax

let ( let* ) = Result.bind

(* LSP DiagnosticSeverity: 1 = Error, the only kind the front end reports. *)
let severity_error = 1

let mark ~range msg =
  Json.Assoc
    [
      ("range", Text.json_of_range range);
      ("severity", Json.Int severity_error);
      ("source", Json.String "writ");
      ("message", Json.String msg);
    ]

(* An error covers the form it blames. One with no position, or a position in
   a loaded library, goes on the first line with its [file:line:col] in the
   message. *)
let of_error (t : Text.t) ~(file : string) (e : Errors.t) =
  let mine (p : Errors.pos) =
    match p.Errors.file with None -> true | Some f -> f = file
  in
  match e.Errors.pos with
  | Some p when mine p ->
      mark ~range:(Text.form_range t (Text.lsp_of_pos t p)) e.Errors.msg
  | Some _ | None -> mark ~range:(Text.line_range t 0) (Errors.to_string e)

(* None when the buffer does not read; the loader reports that error. *)
let datums_of (t : Text.t) : Reader.t list =
  match Reader.read_string t.Text.src with Ok ds -> ds | Error _ -> []

(* Read, inline and expand without a schema, for a buffer whose sibling model
   does not build. A .rules buffer needs [open_heads], as in
   [Loader.read_rules], or relation heads like `holds` are refused. *)
let structural ?(open_heads = false) (resolve : Loader.resolve) (path : string)
    : (unit, Errors.t) result =
  let* datums =
    Loader.read_datums resolve ~file:path (Filename.basename path)
  in
  let* inlined = Loader.inline resolve datums in
  let* _ = Expander.expand ~open_heads inlined in
  Ok ()

(* A .rules buffer is checked against its sibling model: sorts,
   stratification and range restriction (§1, §4) need its schema. *)
let check_rules (resolve : Loader.resolve) ~(path : string) ~(sibling : string)
    : (unit, Errors.t) result =
  match Loader.read_model resolve sibling with
  | Error _ -> structural ~open_heads:true resolve path
  | Ok model ->
      (* [Loader.read_rules] only parses; [Rules_check] does the checks, as
         [Cli_io.read_rules] does. *)
      let* prog = Loader.read_rules resolve model path in
      Result.map (fun _ -> ()) (Rules_check.check model prog)

let check_claims (resolve : Loader.resolve) ~(path : string) ~(sibling : string)
    : (unit, Errors.t) result =
  match Loader.read_model resolve sibling with
  | Ok model -> Result.map (fun _ -> ()) (Loader.read_claims resolve model path)
  | Error _ -> structural resolve path

let check (t : Text.t) ~(resolve : Loader.resolve) ~(path : string) :
    (unit, Errors.t) result =
  match Role.of_path path (datums_of t) with
  | Role.Model -> Result.map (fun _ -> ()) (Loader.read_model resolve path)
  | Role.Library -> Result.map (fun _ -> ()) (Loader.load_library resolve path)
  | Role.Claims sibling -> check_claims resolve ~path ~sibling
  | Role.Rules sibling -> check_rules resolve ~path ~sibling

let of_text (t : Text.t) ~(resolve : Loader.resolve) ~(path : string) :
    Json.t list =
  match check t ~resolve ~path with
  | Ok () -> []
  | Error e -> [ of_error t ~file:path e ]
