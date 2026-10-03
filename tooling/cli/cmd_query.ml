(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ query]: run one named query from the model's [.claims], at the
   initial situation or at [--at N]. *)

open Writ_data
open Writ_runtime
open Cli_io

(* An index outside the space is a bad command line (2), not an empty answer. *)
let state_at (sp : Space.t) (spec : string option) : int * State.t =
  match spec with
  | None -> (0, sp.Space.initial)
  | Some s -> (
      match int_of_string_opt s with
      | Some i when i >= 0 && i < Array.length sp.Space.states ->
          (i, sp.Space.states.(i))
      | _ -> die 2 ("--at expects a state index in range: " ^ s))

let run ?(json = false) ~(claims : string option) (model : string)
    (name : string) (at : string option) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let sp = build_space model m in
  (* A piped model has no sibling [.claims], so it needs [--claims]. *)
  let cpath =
    match claims with
    | Some p -> p
    | None when model = stdin_name ->
        die 2
          "query: a model read from stdin has no sibling .claims — pass \
           --claims FILE"
    | None -> claims_beside model
  in
  let claims = read_claims resolve m cpath in
  let q =
    match
      List.find_opt (fun (q : Claims.query) -> q.name = name) claims.queries
    with
    | Some q -> q
    | None -> die 2 ("no query named `" ^ name ^ "` in " ^ cpath)
  in
  let idx, st = state_at sp at in
  let rows = Query.run sp q ~at:st () in
  say
    (if json then Json.to_string (Report_json.query_rows q idx rows)
     else Report.query_rows q idx rows);
  flush stdout;
  exit 0
