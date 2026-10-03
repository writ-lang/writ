(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ check]: the §15 build report, and with a [.claims] file the §16.3
   acknowledgments, §16.1 property outcomes and §16.2 queries. A finding makes
   the exit status 1. [--json] prints the same answers as one object. *)

open Writ_data
open Writ_runtime
open Cli_io

(* Everything `check` decides, computed before any rendering, so the prose,
   the JSON and the certificate cannot disagree. *)
type answers = {
  unadmitted : (string * string) list;
  stale : (string * string) list;
  props :
    (Claims.property * Checker.outcome * (Fiber.fiber * Checker.outcome) list)
    list;
  queries : (Claims.query * int * (string * string) list list) list;
  defined : Claims.query list;
  claims : Claims.t option;
  exit_code : int;
}

let answer ?(cells = []) resolve (m : Model.t) (sp : Space.t)
    (claims_path : string option) : answers =
  let failed =
    ref
      (List.exists
         (fun (l : Observe.law) -> l.violation <> None)
         (Observe.laws sp))
  in
  let unadmitted, stale, props, queries, defined, claims =
    match claims_path with
    | None -> ([], [], [], [], [], None)
    | Some c ->
        let claims = read_claims resolve m c in
        let unadmitted = Observe.unadmitted sp claims in
        let stale = Observe.stale sp claims in
        if unadmitted <> [] || stale <> [] then failed := true;
        let props =
          List.map
            (fun (p : Claims.property) ->
              let o = Checker.check sp p in
              (* An n/a is a question left unanswered — usually because an
                 edit deleted what it asked about — so it is a finding, as
                 compare and the MCP server already treat it. *)
              (match o with
              | Checker.Fails _ | Checker.Not_applicable _ -> failed := true
              | Checker.Holds _ -> ());
              let fs = if cells = [] then [] else Fiber.outcomes sp cells p in
              if
                List.exists
                  (fun (_, o) ->
                    match o with
                    | Checker.Fails _ | Checker.Not_applicable _ -> true
                    | Checker.Holds _ -> false)
                  fs
              then failed := true;
              (p, o, fs))
            claims.Claims.props
        in
        let queries =
          List.map
            (fun (q : Claims.query) -> (q, 0, Query.run sp q ()))
            claims.Claims.queries
        in
        (unadmitted, stale, props, queries, claims.Claims.queries, Some claims)
  in
  {
    unadmitted;
    stale;
    props;
    queries;
    defined;
    claims;
    exit_code = (if !failed then 1 else 0);
  }

let report_json (sp : Space.t) (a : answers) : Json.t =
  Report_json.check ~queries:a.defined ~sp ~unadmitted:a.unadmitted
    ~stale:a.stale
    ~props:(List.map (fun (p, o, _) -> (p, o)) a.props)
    ~answered:a.queries ~exit:a.exit_code

(* The certificate: the answers plus what a second checker needs to re-derive
   them (docs/certificates.md). Written by default as [MODEL.cert.json];
   a piped model gets one only with [--certificate FILE].

   An explicitly requested certificate that cannot be written is exit 2; the
   default one only warns, so a read-only checkout does not fail the check. *)
type certificate = Off | Beside | To of string

let certificate_path (model : string) = function
  | To f -> Some (f, true)
  | Beside when model <> stdin_name ->
      Some (Filename.remove_extension model ^ ".cert.json", false)
  | Beside | Off -> None

let write_certificate ~(file : string) ~(asked : bool) ~(version : string)
    (m : Model.t) (sp : Space.t) (a : answers) : bool =
  let j =
    Certify_json.certificate ~version ~sp ~model_:m ~claims:a.claims
      ~report:(report_json sp a)
  in
  match open_out_bin file with
  | exception Sys_error e ->
      if asked then die 2 ("--certificate: " ^ e)
      else (
        prerr_endline ("writ: no certificate written (" ^ e ^ ")");
        false)
  | oc ->
      output_string oc (Json.to_string j);
      output_char oc '\n';
      close_out oc;
      true

let run ?(json = false) ?(fibers = []) ?(certificate = Off) ?(version = "")
    (model : string) (claims_path : string option) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let sp = build_space model m in
  (* An unknown fiber cell is a bad command line. *)
  let cells =
    List.map
      (fun c ->
        match Fiber.cell_index sp c with
        | Some ci -> ci
        | None ->
            die 2
              ("--fiber names no mutable cell `" ^ c ^ "` (spell it SRC.ARROW)"))
      fibers
  in
  let a = answer ~cells resolve m sp claims_path in
  (* A written certificate is checked at once ([Certifier]). *)
  let certified =
    match certificate_path model certificate with
    | Some (file, asked) when write_certificate ~file ~asked ~version m sp a ->
        Some (Certifier.run file)
    | _ -> None
  in
  let props = a.props in
  (* A refuted report is a finding. *)
  let exit_code =
    match certified with
    | Some (Certify_json.Disagrees _) -> 1
    | _ -> a.exit_code
  in
  if json then
    let j = report_json sp a in
    (* The fibers ride on each property, by position. *)
    let with_fibers = function
      | Json.Assoc kvs when cells <> [] ->
          Json.Assoc
            (List.map
               (fun (k, v) ->
                 match (k, v) with
                 | "properties", Json.List ps ->
                     ( k,
                       Json.List
                         (List.map2
                            (fun pj (_, _, fs) ->
                              match pj with
                              | Json.Assoc pk ->
                                  Json.Assoc
                                    (pk
                                    @ [ ("fibers", Report_json.fibers sp fs) ])
                              | other -> other)
                            ps props) )
                 | _ -> (k, v))
               kvs)
      | other -> other
    in
    let with_certification = function
      | Json.Assoc kvs -> (
          match certified with
          | Some v ->
              let kvs =
                List.map
                  (fun (k, x) ->
                    if k = "exit" then (k, Json.Int exit_code) else (k, x))
                  kvs
              in
              Json.Assoc
                (kvs @ [ ("certification", Certify_json.verdict_json v) ])
          | None -> Json.Assoc kvs)
      | other -> other
    in
    say (Json.to_string (with_certification (with_fibers j)))
  else begin
    say (Report.build sp);
    let acks = Report.acks a.unadmitted a.stale in
    if acks <> "" then say acks;
    List.iter
      (fun (p, o, fs) ->
        say (Report.outcome ~queries:a.defined sp p o);
        List.iter say (Report.fiber_lines sp fs))
      props;
    List.iter (fun (q, i, rows) -> say (Report.query_rows q i rows)) a.queries;
    Option.iter (fun v -> say (Certify_json.verdict_line v)) certified
  end;
  flush stdout;
  exit exit_code
