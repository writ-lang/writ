(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ control]: the model's move list as an instance of the standard
   library's [quiver] schema (kernel §17), named after the model's basename. *)

open Writ_runtime
open Cli_io

let run (model : string) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let name = Filename.remove_extension (Filename.basename model) in
  say (Control.quiver name m);
  flush stdout;
  exit 0
