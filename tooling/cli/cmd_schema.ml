(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ schema]: the model's schema as an instance of the standard library's
   [olog] schema (kernel §17). A schema is static, so no space is built. *)

open Writ_data
open Writ_runtime
open Cli_io

let run (model : string) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let name = Filename.remove_extension (Filename.basename model) in
  say (Schema_data.olog name m.Model.schema);
  flush stdout;
  exit 0
