(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Cmd_check] — the [writ check] verb, on its own so that the dispatch in [Writ]
   stays a table of verbs rather than a file that grows by one implementation
   every time the tool learns a new question.

   Emits the §15 build report always; with a [.claims] file it adds the §16.3
   acknowledgments, the §16.1 property outcomes, and the §16.2 queries at the
   initial situation. A finding — a failing property, or a violated / unadmitted
   / stale law — makes the exit status 1.

   With [--json] the same answers go out as one object ([Report_json.check])
   and nothing else is printed. The verdicts are computed ONCE, into values,
   and only then rendered one way or the other — so the two renderings cannot
   disagree about what was found. *)

open Writ_data
open Writ_runtime
open Cli_io

let run ?(json = false) (model : string) (claims_path : string option) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let sp = build_space model m in
  let failed =
    ref
      (List.exists
         (fun (l : Observe.law) -> l.violation <> None)
         (Observe.laws sp))
  in
  let unadmitted, stale, props, queries, defined =
    match claims_path with
    | None -> ([], [], [], [], [])
    | Some c ->
        let claims = read_claims resolve m c in
        let unadmitted = Observe.unadmitted sp claims in
        let stale = Observe.stale sp claims in
        if unadmitted <> [] || stale <> [] then failed := true;
        let props =
          List.map
            (fun (p : Claims.property) ->
              let o = Checker.check sp p in
              (match o with Checker.Fails _ -> failed := true | _ -> ());
              (p, o))
            claims.Claims.props
        in
        let queries =
          List.map
            (fun (q : Claims.query) -> (q, 0, Query.run sp q ()))
            claims.Claims.queries
        in
        (unadmitted, stale, props, queries, claims.Claims.queries)
  in
  let exit_code = if !failed then 1 else 0 in
  if json then
    say
      (Json.to_string
         (Report_json.check ~queries:defined ~sp ~unadmitted ~stale ~props
            ~answered:queries ~exit:exit_code))
  else begin
    say (Report.build sp);
    let acks = Report.acks unadmitted stale in
    if acks <> "" then say acks;
    List.iter (fun (p, o) -> say (Report.outcome ~queries:defined sp p o)) props;
    List.iter (fun (q, i, rows) -> say (Report.query_rows q i rows)) queries
  end;
  flush stdout;
  exit exit_code
