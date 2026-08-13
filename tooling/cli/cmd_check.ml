(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Cmd_check] — the [pol check] verb, on its own so that the dispatch in [Pol]
   stays a table of verbs rather than a file that grows by one implementation
   every time the tool learns a new question.

   Emits the §15 build report always; with a [.claims] file it adds the §16.3
   acknowledgments, the §16.1 property outcomes, and the §16.2 queries at the
   initial situation. A finding — a failing property, or a violated / unadmitted
   / stale law — makes the exit status 1. *)

open Pol_data
open Pol_runtime
open Cli_io

let run (model : string) (claims_path : string option) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let sp = build_space model m in
  say (Report.build sp);
  let failed =
    ref
      (List.exists
         (fun (l : Observe.law) -> l.violation <> None)
         (Observe.laws sp))
  in
  (match claims_path with
  | None -> ()
  | Some c ->
      let claims = read_claims resolve m c in
      let unadmitted = Observe.unadmitted sp claims in
      let stale = Observe.stale sp claims in
      if unadmitted <> [] || stale <> [] then failed := true;
      let acks = Report.acks unadmitted stale in
      if acks <> "" then say acks;
      List.iter
        (fun (p : Claims.property) ->
          let o = Checker.check sp p in
          (match o with Checker.Fails _ -> failed := true | _ -> ());
          say (Report.outcome sp p o))
        claims.Claims.props;
      List.iter
        (fun (q : Claims.query) ->
          say (Report.query_rows q 0 (Query.run sp q ())))
        claims.Claims.queries);
  flush stdout;
  if !failed then exit 1 else exit 0
