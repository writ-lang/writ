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

(* Everything `check` decides, computed once and before any rendering — so the
   prose, the JSON, and the certificate wrapped around the JSON
   ([Cmd_certify]) are three renderings of one set of values. *)
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
              (match o with Checker.Fails _ -> failed := true | _ -> ());
              let fs = if cells = [] then [] else Fiber.outcomes sp cells p in
              if
                List.exists
                  (fun (_, o) ->
                    match o with Checker.Fails _ -> true | _ -> false)
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

(* The certificate: the same answers, wrapped in everything a second checker
   needs to re-derive them ([Certify_json]; docs/certificates.md).

   Written BY DEFAULT, beside the model as [MODEL.cert.json], so that every
   answer writ gives can be checked after the fact without anyone having
   remembered to ask for it. [--certificate FILE] puts it elsewhere and
   [--no-certificate] opts out. A model read from stdin has no name to put one
   beside, so it gets one only when a FILE is named.

   The two cases fail differently, on purpose. A certificate that was ASKED
   for and cannot be written is a bad command line (exit 2). The default one is
   a by-product: a read-only checkout or a mounted volume must not turn a
   successful check into a failure, so it is a warning and the answer stands. *)
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
  (* A fiber names a mutable cell as the report spells it; anything else is a
     bad command line, not an empty answer. *)
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
  (* Written, then checked at once ([Certifier]): a certificate is worth
     something only if somebody runs the checker, so the check runs it. *)
  let certified =
    match certificate_path model certificate with
    | Some (file, asked) when write_certificate ~file ~asked ~version m sp a ->
        Some (Certifier.run file)
    | _ -> None
  in
  let props = a.props in
  (* A refuted report is a finding — the most serious one writ can make about
     itself. *)
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
