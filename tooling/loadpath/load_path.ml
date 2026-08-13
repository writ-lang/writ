(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Design D3 — the search order for [(load "FILE")], first readable wins:

   (1) the directory of the INCLUDING file: a model's own libraries sit beside
       it, and this is the only candidate that depends on who is loading;
   (2) [$WRIT_LIB]: the operator's override, ahead of every built-in location;
   (3) the executable's own directory, then its [../share/writ/lib]: the
       installed layout, so a machine that only ran `opam install writ` still
       resolves the standard library;
   (4) [core/stdlib]: the dev checkout, run from the repository root.

   [base] is the path of the file doing the loading — for the LSP, the path of
   the document the [(load …)] appears in. Only paths are computed here; opening
   them belongs to the caller, which is what keeps this library I/O-free. *)

let candidates ~(base : string) (name : string) : string list =
  let exe_dir = Filename.dirname Sys.executable_name in
  let env_dir =
    match Sys.getenv_opt "WRIT_LIB" with
    | Some d -> [ Filename.concat d name ]
    | None -> []
  in
  (Filename.concat (Filename.dirname base) name :: env_dir)
  @ [
      Filename.concat exe_dir name;
      Filename.concat (Filename.concat exe_dir "../share/writ/lib") name;
      Filename.concat "core/stdlib" name;
    ]

(* The one message for an exhausted search, so the editor and the command line
   report a missing library identically. No position: a resolver is handed a
   name, not a datum — [Loader.inline] fills in the load datum's own position,
   without which the diagnostic lands on line 1. *)
let not_found (name : string) : Errors.t =
  { Errors.pos = None; msg = "cannot resolve load: " ^ name }
