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

(* The questions live beside the model, in the sibling [.claims] file
   ([MODEL.pol] -> [MODEL.claims]) — the convention [pol query] and
   [pol compare] both read the contract by. *)
let claims_beside (model : string) : string =
  Filename.remove_extension model ^ ".claims"
