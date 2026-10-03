(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Design D3 — the search order for [(load "FILE")], first readable wins:
   (1) the directory of [base], the file doing the loading;
   (2) [$WRIT_LIB], the operator's override;
   (3) the executable's directory, then its [../share/writ/lib] (installed);
   (4) [core/stdlib] (dev checkout, run from the repository root).
   Only paths are computed; the caller opens them. *)

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

(* Shared so the editor and command line report a miss identically. No
   position: [Loader.inline] fills in the load datum's own. *)
let not_found (name : string) : Errors.t =
  { Errors.pos = None; msg = "cannot resolve load: " ^ name }
