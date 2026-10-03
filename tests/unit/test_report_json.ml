(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The JSON rendering (docs/json.md). Every object is serialised and parsed
   back. *)

open Writ_data
open Writ_syntax
open Writ_runtime

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let repo_root () =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.writ") then dir
    else if n = 0 then dir
    else up (Filename.dirname dir) (n - 1)
  in
  up (Sys.getcwd ()) 8

let resolve : Loader.resolve =
 fun name ->
  let root = repo_root () in
  let read p =
    match open_in_bin p with
    | exception Sys_error _ -> None
    | ic ->
        let n = in_channel_length ic in
        let s = really_input_string ic n in
        close_in ic;
        Some s
  in
  let rec go = function
    | [] -> Error { Errors.pos = None; msg = "cannot resolve " ^ name }
    | p :: rest -> ( match read p with Some s -> Ok s | None -> go rest)
  in
  go
    [
      Filename.concat root ("core/stdlib/" ^ name);
      Filename.concat root ("tests/unit/fixtures/" ^ name);
    ]

let model path =
  match Loader.read_model resolve path with
  | Ok m -> m
  | Error e ->
      check ("read_model " ^ path ^ ": " ^ Errors.to_string e) false;
      exit 1

let claims m path =
  match Loader.read_claims resolve m path with
  | Ok c -> c
  | Error e ->
      check ("read_claims " ^ path ^ ": " ^ Errors.to_string e) false;
      exit 1

let space m =
  match Space.build m with
  | Ok sp -> sp
  | Error e ->
      check ("build: " ^ e) false;
      exit 1

let roundtrip (j : Json.t) : Json.t =
  match Json_parse.parse (Json.to_string j) with
  | Ok v -> v
  | Error e ->
      check ("parses back: " ^ e) false;
      exit 1

let get k j =
  match Json.member k j with
  | Some v -> v
  | None ->
      check ("has member " ^ k) false;
      exit 1

let nth i = function
  | Json.List l -> (
      match List.nth_opt l i with
      | Some v -> v
      | None ->
          check ("has element " ^ string_of_int i) false;
          exit 1)
  | _ ->
      check "is a list" false;
      exit 1

let str j = Option.get (Json.to_string_opt j)
let int j = Option.get (Json.to_int_opt j)
let len = function Json.List l -> List.length l | _ -> -1

(* --- check ----------------------------------------------------------------- *)

let () =
  let m = model "captured_trap.writ" in
  let sp = space m in
  let cl = claims m "captured_trap.claims" in
  let props =
    List.map (fun (p : Claims.property) -> (p, Checker.check sp p)) cl.props
  in
  let j =
    roundtrip
      (Report_json.check ~queries:[] ~sp ~unadmitted:[] ~stale:[] ~props
         ~answered:[] ~exit:1)
  in
  check "check: states is the space's count"
    (int (get "states" j) = Array.length sp.Space.states);
  check "check: edges is the edge count"
    (int (get "edges" j) = List.length sp.Space.edges);
  check "check: exit carried" (int (get "exit" j) = 1);
  let r = get "regime" j in
  check "check: the regime is named" (str (get "kind" r) = "reversible");
  check "check: with how much of the space lies on cycles"
    (int (get "recurrent" r) > 0
    && int (get "recurrent" r) <= int (get "states" j));
  let p = nth 0 (get "properties" j) in
  check "check: property named" (str (get "name" p) = "accountability");
  check "check: modality spelled" (str (get "modality" p) = "live");
  check "check: a live trap fails" (str (get "verdict" p) = "fails");
  let w = get "witness" p in
  check "check: witness is non-empty" (len w >= 1);
  let last = nth (len w - 1) w in
  check "check: a step names its move"
    (String.length (str (get "move" last)) > 0);
  check "check: stuck_at is the witness's last landing"
    (int (get "stuck_at" p) = int (get "to" last));
  let g = nth 0 (get "gaps" j) in
  check "check: a gap carries its move" (str (get "move" g) <> "");
  check "check: a gap carries its message"
    (String.length (str (get "message" g)) > 0);
  check "check: a gap carries its distance" (int (get "min_moves" g) >= 0)

(* --- queries, laws ---------------------------------------------------------- *)

let () =
  let m = model "query_rows.writ" in
  let sp = space m in
  let cl = claims m "query_rows.claims" in
  let q = List.hd cl.Claims.queries in
  let rows = Query.run sp q () in
  let j = roundtrip (Report_json.query_rows q 0 rows) in
  check "query: named" (str (get "name" j) = "captured");
  check "query: at the initial situation" (int (get "at" j) = 0);
  let r = nth 0 (get "rows" j) in
  check "query: a row binds its variable" (str (get "b" r) = "watchdog");
  let m = model "equations.writ" in
  let sp = space m in
  let j =
    roundtrip
      (Report_json.check ~queries:[] ~sp
         ~unadmitted:[ ("m", "law") ]
         ~stale:[] ~props:[] ~answered:[] ~exit:1)
  in
  check "laws: an equation is listed" (len (get "equations" j) >= 1);
  let u = nth 0 (get "unadmitted" j) in
  check "acks: unadmitted carries move and law"
    (str (get "move" u) = "m" && str (get "law" u) = "law")

(* --- show ------------------------------------------------------------------- *)

let () =
  let m = model "captured_trap.writ" in
  let sp = space m in
  let j = roundtrip (Report_json.show sp [ 0; 1 ]) in
  let s0 = nth 0 (get "situations" j) in
  check "show: index" (int (get "index" s0) = 0);
  check "show: the initial situation says so" (get "initial" s0 = Json.Bool true);
  check "show: initial route is empty" (len (get "route" s0) = 0);
  check "show: moves out are listed" (len (get "moves" s0) >= 1);
  let s1 = nth 1 (get "situations" j) in
  check "show: a later situation has a route" (len (get "route" s1) = 1);
  check "show: the route lands where it says"
    (int (get "to" (nth 0 (get "route" s1))) = 1);
  (* A vacant cell is null, not the prose's sigil. *)
  let cells = get "cells" s0 in
  check "show: cells is an object"
    (match cells with Json.Assoc _ -> true | _ -> false)

(* --- compare ---------------------------------------------------------------- *)

let () =
  let old_m = model "compare_old.writ" and new_m = model "compare_new.writ" in
  let old_sp = space old_m and new_sp = space new_m in
  let cl = claims old_m "compare_old.claims" in
  let equations = Compare.equation_rows [] old_sp new_sp in
  let properties = Compare.property_rows [] old_sp new_sp cl in
  let j =
    roundtrip (Report_json.compare ~new_sp ~equations ~properties ~exit:1)
  in
  check "compare: exit carried" (int (get "exit" j) = 1);
  let lost =
    match get "properties" j with
    | Json.List l -> List.find_opt (fun r -> str (get "status" r) = "LOST") l
    | _ -> None
  in
  check "compare: a LOST property is reported" (lost <> None);
  check "compare: the LOST property carries a witness with landings"
    (match lost with
    | Some r ->
        len (get "witness" r) >= 1
        && Json.to_int_opt (get "to" (nth 0 (get "witness" r))) <> None
    | None -> false)

(* --- route ------------------------------------------------------------------ *)

let () =
  let m = model "captured_trap.writ" in
  let sp = space m in
  let s1 = sp.Space.states.(1) in
  let route = Space.shortest_path sp s1 in
  check "route: walk lands on the state the path reaches"
    (Route.walk sp route = [ 1 ]);
  check "route: an unknown move stops the walk"
    (Route.walk sp [ "no-such-move" ] = []);
  check "route: deltas between a state and itself are none"
    (Route.deltas sp s1 s1 = []);
  check "route: a move changes at least one cell"
    (Route.deltas sp sp.Space.initial s1 <> [])

(* --- fibers ------------------------------------------------------------------ *)

let () =
  let m = model "captured_trap.writ" in
  let sp = space m in
  let cl = claims m "captured_trap.claims" in
  let p = List.hd cl.Claims.props in
  let cell = Option.get (Fiber.cell_index sp "gov.regime") in
  let fs = Fiber.outcomes sp [ cell ] p in
  let j = roundtrip (Report_json.fibers sp fs) in
  check "fibers: one object per value" (len j = 2);
  let f0 = nth 0 j in
  check "fibers: the cell and its value are named"
    (str (get "gov.regime" (get "cells" f0)) = "normal");
  check "fibers: a verdict per fiber" (str (get "verdict" f0) = "fails");
  check "fibers: a failing fiber carries a witness with landings"
    (len (get "witness" f0) >= 1)

(* --- (show QUERY…) ----------------------------------------------------------- *)

let () =
  let m = model "query_rows.writ" in
  let sp = space m in
  let cl = claims m "shown.claims" in
  let p = List.hd cl.Claims.props in
  check "show: the clause is parsed onto the property"
    (p.Claims.show = [ "captured" ]);
  let oc = Checker.check sp p in
  (* Broken at the initial situation: empty route, query answered at #0. *)
  let rows = Report.shown_rows ~queries:cl.Claims.queries sp p oc in
  check "show: answered at the violating situation"
    (match rows with
    | [ (_, 0, [ [ ("b", "watchdog") ] ]) ] -> true
    | _ -> false);
  let prose = Report.outcome ~queries:cl.Claims.queries sp p oc in
  check "show: the prose carries the query block under the verdict"
    (let needle = "  captured  (at state 0)\n    b = watchdog" in
     let ls = String.length needle and lp = String.length prose in
     let rec go i =
       i + ls <= lp && (String.sub prose i ls = needle || go (i + 1))
     in
     go 0);
  let j = roundtrip (Report_json.property ~queries:cl.Claims.queries sp p oc) in
  let shown = nth 0 (get "show" j) in
  check "show: the JSON carries the answered query"
    (str (get "name" shown) = "captured");
  check "show: at the same situation" (int (get "at" shown) = 0);
  check "show: with its rows"
    (str (get "b" (nth 0 (get "rows" shown))) = "watchdog");
  (* A holding never singles out no situation, so nothing is shown. *)
  let never_holds =
    {
      p with
      Claims.formula =
        Model.Is
          ( { Value.root = "watchdog"; steps = [ "independence" ] },
            Model.Lit "independent" );
    }
  in
  check "show: a holding never shows nothing"
    (Report.shown_rows ~queries:cl.Claims.queries sp never_holds
       (Checker.check sp never_holds)
    = []);
  check "show: an undeclared query name is a read-time error"
    (match Loader.read_claims resolve m "shown_unknown.claims" with
    | Error e ->
        let s = Errors.to_string e in
        let needle = "names no query" in
        let ls = String.length needle and lp = String.length s in
        let rec go i =
          i + ls <= lp && (String.sub s i ls = needle || go (i + 1))
        in
        go 0
    | Ok _ -> false)

(* --- the certificate (docs/certificates.md) --------------------------------- *)

(* The certificate carries the model, questions and answers, not the graph. *)
let () =
  let m = model "captured_trap.writ" in
  let sp = space m in
  let cl = claims m "captured_trap.claims" in
  let props =
    List.map (fun (p : Claims.property) -> (p, Checker.check sp p)) cl.props
  in
  let report =
    Report_json.check ~queries:[] ~sp ~unadmitted:[] ~stale:[] ~props
      ~answered:[] ~exit:1
  in
  let j =
    roundtrip
      (Certify_json.certificate ~version:"test" ~sp ~model_:m ~claims:(Some cl)
         ~report)
  in
  check "certificate: format" (str (get "format" j) = "writ-certificate");
  check "certificate: version" (int (get "version" j) = 2);
  let n = Array.length sp.Space.states in
  let ntr = List.length sp.Space.transitions in
  check "certificate: no state graph — the checker builds its own"
    (Json.member "space" j = None);
  check "certificate: the layout is the state width"
    (len (get "layout" (get "model" j)) = Array.length sp.Space.initial);
  check "certificate: every move is exported"
    (len (get "transitions" (get "model" j)) = ntr);
  check "certificate: every property is exported"
    (len (get "properties" j) = List.length cl.Claims.props);
  check "certificate: the report rides along"
    (int (get "states" (get "report" j)) = n)

(* All n/a and no query: the certified line must not claim the claims. *)
let () =
  let na = Checker.Not_applicable "x" and held = Checker.Holds [] in
  let line nothing_decided =
    Certify_json.verdict_line ~nothing_decided Certify_json.Certified
  in
  let has sub s =
    let n = String.length sub in
    let rec go i =
      i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
    in
    go 0
  in
  check "nothing decided: all n/a, no query"
    (Certify_json.nothing_decided [ na; na ] ~queries:0);
  check "decided: one property held"
    (not (Certify_json.nothing_decided [ na; held ] ~queries:0));
  check "decided: a query was answered"
    (not (Certify_json.nothing_decided [ na ] ~queries:1));
  check "decided: no claims at all is not all-n/a"
    (not (Certify_json.nothing_decided [] ~queries:0));
  check "certified line says n/a when nothing was decided"
    (has "every property is n/a" (line true));
  check "certified line unchanged otherwise"
    (line false
   = "certified: every answer re-derived from the model (writ-cert)")

let () =
  print_string
    ("test_report_json: " ^ string_of_int !passed ^ " checks passed\n")
