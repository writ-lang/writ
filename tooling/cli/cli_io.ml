(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* File I/O shared by every verb: reading files, resolving [(load "FILE")],
   loading models, claims and rules, and dying with the right exit status.

   Exit status is the interface (kernel §18): 0 = answered, nothing failed;
   1 = a finding (a failed or n/a property, or a violated / unadmitted / stale
   law);
   2 = unreadable input or a bad command line. Every failure here is a 2. *)

open Writ_data
open Writ_syntax
open Writ_runtime
open Writ_loadpath

let say s = print_string (s ^ "\n")

let die code msg =
  prerr_endline ("writ: " ^ msg);
  exit code

let read_file (path : string) : (string, string) result =
  match open_in_bin path with
  | exception Sys_error e -> Error e
  | ic ->
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      Ok s

(* The path standing in for a piped model; the resolver below answers it.
   Diagnostics read `<stdin>:12:3: …`, and since its dirname is ".", loads
   from a piped model search the current directory first. *)
let stdin_name = "<stdin>"

(* Read to EOF ([in_channel_length] fails on a pipe). Memoised: stdin drains
   once, and the resolver may be asked for it again. *)
let stdin_text : string option ref = ref None

let read_stdin () : string =
  match !stdin_text with
  | Some s -> s
  | None ->
      let buf = Buffer.create 65536 in
      let chunk = Bytes.create 65536 in
      let rec loop () =
        let n = input stdin chunk 0 65536 in
        if n > 0 then (
          Buffer.add_subbytes buf chunk 0 n;
          loop ())
      in
      (try loop () with End_of_file -> ());
      let s = Buffer.contents buf in
      stdin_text := Some s;
      s

(* The [(load "FILE")] resolver. The search order is [Load_path] (design D3),
   shared with the LSP so editor and command line agree.

   [WRIT_TRACE_LOADS] prints which candidate won and which were skipped. D3
   searches the including file's directory first, so a `stdlib.writ` next to a
   model silently replaces the installed one; this makes that visible. *)
let trace_loads = Sys.getenv_opt "WRIT_TRACE_LOADS" <> None

let make_resolve (base : string) : Loader.resolve =
 fun name ->
  if name = stdin_name then Ok (read_stdin ())
  else
    let rec try_ skipped = function
      | [] -> Error (Load_path.not_found name)
      | p :: rest -> (
          match read_file p with
          | Ok s ->
              if trace_loads then (
                prerr_endline ("writ: resolved \"" ^ name ^ "\" -> " ^ p);
                List.iter
                  (fun q -> prerr_endline ("writ:   (skipped " ^ q ^ ")"))
                  (List.rev skipped));
              Ok s
          | Error _ -> try_ (p :: skipped) rest)
    in
    try_ [] (Load_path.candidates ~base name)

(* Name the file an error's position refers to, once. An error that carries
   its own file (possibly a loaded library) names only that; otherwise it is
   attributed to [path]. *)
let located (path : string) (e : Errors.t) : string =
  match e.Errors.pos with
  | Some { Errors.file = Some _; _ } -> Errors.to_string e
  | Some { Errors.file = None; _ } | None -> path ^ ": " ^ Errors.to_string e

let load_model (resolve : Loader.resolve) (path : string) : Model.t =
  match Loader.read_model resolve path with
  | Error e -> die 2 (located path e)
  | Ok m -> m

let build_space (path : string) (m : Model.t) : Space.t =
  match Space.build m with Error e -> die 2 (path ^ ": " ^ e) | Ok sp -> sp

let read_claims (resolve : Loader.resolve) (m : Model.t) (path : string) :
    Claims.t =
  match Loader.read_claims resolve m path with
  | Error e -> die 2 (located path e)
  | Ok cl -> cl

(* The rules file (extension §1). [Rules_check.check] is the only constructor
   of a [Rules.program], so its rejections are read-time errors: exit 2. *)
let read_rules (resolve : Loader.resolve) (m : Model.t) (path : string) :
    Rules.program =
  match Loader.read_rules resolve m path with
  | Error e -> die 2 (located path e)
  | Ok t -> (
      match Rules_check.check m t with
      | Error e -> die 2 (located path e)
      | Ok p -> p)

(* [MODEL.writ] -> [MODEL.claims], as [writ query] and [writ compare] read it. *)
let claims_beside (model : string) : string =
  Filename.remove_extension model ^ ".claims"
