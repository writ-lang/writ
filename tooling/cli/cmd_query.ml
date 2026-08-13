(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Cmd_query] — the [writ query] verb: name one of the questions in the model's
   sibling [.claims] file and run just that one, optionally at a state other
   than the initial one. Its own module for the same reason as its siblings —
   the dispatch in [Writ] should read as a list of verbs, not contain them. *)

open Writ_data
open Writ_runtime
open Cli_io

(* [--at] indexes the enumerated space, so a value outside it is a bad command
   line (2), not an empty answer — an out-of-range index means the caller is
   asking about a situation this model never reaches. *)
let state_at (sp : Space.t) (spec : string option) : int * State.t =
  match spec with
  | None -> (0, sp.Space.initial)
  | Some s -> (
      match int_of_string_opt s with
      | Some i when i >= 0 && i < Array.length sp.Space.states ->
          (i, sp.Space.states.(i))
      | _ -> die 2 ("--at expects a state index in range: " ^ s))

let run (model : string) (name : string) (at : string option) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let sp = build_space model m in
  let cpath = claims_beside model in
  let claims = read_claims resolve m cpath in
  let q =
    match
      List.find_opt (fun (q : Claims.query) -> q.name = name) claims.queries
    with
    | Some q -> q
    | None -> die 2 ("no query named `" ^ name ^ "` in " ^ cpath)
  in
  let idx, st = state_at sp at in
  say (Report.query_rows q idx (Query.run sp q ~at:st ()));
  flush stdout;
  exit 0
