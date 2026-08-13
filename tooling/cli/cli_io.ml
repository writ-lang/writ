(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Cli_io] — the filesystem, held in one place. Every verb needs the same four
   things: read a file, resolve a [(load "FILE")], turn a path into a model or a
   claims set, and die with the right exit status when the input is unreadable.
   Keeping them here means the verbs are the only thing that differs between
   [Cmd_check] and its siblings, and that a change to the search order or to an
   error message cannot land in four places and drift in three of them.

   Exit status is the interface (kernel §18): 0 = answered, nothing failed;
   1 = a finding (a failed property, or a violated / unadmitted / stale law);
   2 = unreadable input (a missing file, a parse error, or a bad command line).
   Everything raised in here is a 2. *)

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

(* The [(load "FILE")] resolver. The search ORDER is [Load_path] (design D3),
   shared with the LSP process so the editor and the command line can never
   disagree about where a library lives; the reading is here, because I/O is.

   [WRIT_TRACE_LOADS] prints, per load, which candidate won and which were
   skipped. It exists because D3's FIRST candidate is the including file's own
   directory — deliberately, so a model's libraries sit beside it — and the
   consequence is that a `stdlib.writ` lying next to a model SILENTLY replaces
   the installed one. That is the intended rule, and it is also invisible:
   there is no error, the wrong library simply loads, and the symptom is one
   library form resolving while another does not. An env var rather than a flag
   because it must work identically for every verb, and because [WRIT_LIB] has
   already established that the search order is tuned from the environment. *)
let trace_loads = Sys.getenv_opt "WRIT_TRACE_LOADS" <> None

let make_resolve (base : string) : Loader.resolve =
 fun name ->
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

(* Which file the coordinates index, said ONCE. An error that carries a file of
   its own names it and nothing else: that file may be a library this model
   loaded, whose datums the loader spliced into this one's, in which case the
   path on the command line is not where the reader should look — and printing
   both would make one error claim two locations. An error with no file of its
   own (a positionless failure, or one over text with no name) is attributed to
   the path we were asked about, which is the closest true thing there is to say. *)
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

(* The third file type (extension §1), read exactly as the other two are. It
   goes one step further than [read_claims] because [Rules_check.check] is the
   ONLY constructor of a [Rules.program]: sorts, stratification, range
   restriction and the ALL-CAPS collision check are read-time rejections, so
   they belong to reading the file and every one of them is a 2. *)
let read_rules (resolve : Loader.resolve) (m : Model.t) (path : string) :
    Rules.program =
  match Loader.read_rules resolve m path with
  | Error e -> die 2 (located path e)
  | Ok t -> (
      match Rules_check.check m t with
      | Error e -> die 2 (located path e)
      | Ok p -> p)

(* The questions live beside the model, in the sibling [.claims] file
   ([MODEL.writ] -> [MODEL.claims]) — the convention [writ query] and
   [writ compare] both read the contract by. *)
let claims_beside (model : string) : string =
  Filename.remove_extension model ^ ".claims"
