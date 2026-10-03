(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ show]: print the situations at the given state indices, the numbering
   `writ derive` and `writ query --at` use. [--at] may repeat. *)

open Writ_runtime
open Cli_io

(* Out of range is a bad command line (2), as in [Cmd_query]. *)
let index (sp : Space.t) (s : string) : int =
  match int_of_string_opt s with
  | Some i when i >= 0 && i < Array.length sp.Space.states -> i
  | _ -> die 2 ("--at expects a state index in range: " ^ s)

(* No [--at] means the initial situation, as for [writ query]. *)
let rec ats (acc : string list) (argv : string list) : string list =
  match argv with
  | [] -> if acc = [] then [ "0" ] else List.rev acc
  | "--at" :: n :: rest -> ats (n :: acc) rest
  | _ -> die 2 "writ show MODEL.writ [--at STATE]…"

let run ?(json = false) (model : string) (argv : string list) =
  let m = load_model (make_resolve model) model in
  let sp = build_space model m in
  let idxs = List.map (index sp) (ats [] argv) in
  say
    (if json then Json.to_string (Report_json.show sp idxs)
     else String.concat "\n\n" (List.map (Report.situation sp) idxs));
  flush stdout;
  exit 0
