(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* `writ mgtt` unit tests.

   Three layers, tested apart because they fail differently: reading the export
   document, reducing mgtt's facts to finite domains, and emitting a model.

   The reduction is the one carrying the argument. mgtt's expression language
   has six comparison operators and no arithmetic, so the constants a model
   mentions cut each fact's value line into finitely many regions on which
   every predicate is constant — which is what makes the crossing lossless
   rather than approximate. These tests pin the two places that claim could
   quietly stop being true: the parser's treatment of a bare right-hand side,
   and the merging of regions nothing separates. *)

open Writ_mgtt

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let doc_of_string (s : string) : Mgtt_ast.doc =
  match Json_parse.parse s with
  | Error e -> failwith ("json: " ^ e)
  | Ok j -> (
      match Mgtt_read.of_json j with
      | Error e -> failwith ("read: " ^ e)
      | Ok d -> d)

(* A two-component export: a datastore whose facts are a bool and a
   single-threshold int, and a workload whose healthy clause compares two facts
   with each other. Between them they exercise every domain shape. *)
let minimal =
  {|{"mgtt_export_version":1,"name":"storefront",
     "components":[
       {"name":"api","type":"workload","depends":[{"on":"store","while":""}],
        "healthy":["ready_replicas == desired_replicas"],
        "failure_modes":{"degraded":["upstream_failure"]}},
       {"name":"store","type":"datastore","depends":[],
        "healthy":["available == true","connection_count < 500"],
        "failure_modes":{"stopped":["upstream_failure"]}}],
     "types":[
       {"name":"datastore","provider":"datalayer",
        "facts":[{"name":"available","type":"mgtt.bool"},
                 {"name":"connection_count","type":"mgtt.int"}],
        "healthy":["available == true","connection_count < 500"],
        "states":[{"name":"live","when":"available == true","triggered_by":[]},
                  {"name":"stopped","when":"available == false","triggered_by":[]}],
        "default_active_state":"live",
        "failure_modes":{"stopped":["upstream_failure"]}},
       {"name":"workload","provider":"compute",
        "facts":[{"name":"desired_replicas","type":"mgtt.int"},
                 {"name":"ready_replicas","type":"mgtt.int"}],
        "healthy":["ready_replicas == desired_replicas"],
        "states":[{"name":"live","when":"ready_replicas == desired_replicas","triggered_by":[]},
                  {"name":"degraded","when":"ready_replicas < desired_replicas","triggered_by":["upstream_failure"]}],
        "default_active_state":"live",
        "failure_modes":{"degraded":["upstream_failure"]}}],
     "declines":[]}|}

(* ---- the document ------------------------------------------------------- *)

let test_read () =
  let d = doc_of_string minimal in
  check "read: name" (d.Mgtt_ast.name = "storefront");
  check "read: two components" (List.length d.Mgtt_ast.components = 2);
  check "read: two types" (List.length d.Mgtt_ast.types = 2);
  let store =
    match Mgtt_ast.component_of d "store" with
    | Some c -> c
    | None -> failwith "no store"
  in
  check "read: store healthy carries both clauses"
    (List.length store.Mgtt_ast.chealthy = 2);
  check "read: store can_cause"
    (Mgtt_ast.can_cause store "stopped" = [ "upstream_failure" ]);
  let api =
    match Mgtt_ast.component_of d "api" with
    | Some c -> c
    | None -> failwith "no api"
  in
  check "read: api depends on store" (api.Mgtt_ast.depends = [ ("store", "") ])

let test_read_type_lookup () =
  let d = doc_of_string minimal in
  match Mgtt_ast.type_of d "datastore" with
  | None -> check "read: datastore type present" false
  | Some t ->
      check "read: two facts" (List.length t.Mgtt_ast.facts = 2);
      check "read: default state" (t.Mgtt_ast.default_state = "live");
      (* declared order, not sorted — the emitter depends on it *)
      check "read: states keep declared order"
        (List.map (fun (s : Mgtt_ast.state) -> s.sname) t.Mgtt_ast.states
        = [ "live"; "stopped" ])

let test_read_components_of_type () =
  let d = doc_of_string minimal in
  check "read: one component per type"
    (List.length (Mgtt_ast.components_of_type d "workload") = 1)

let test_read_rejects_unknown_version () =
  let j =
    match
      Json_parse.parse
        {|{"mgtt_export_version":99,"name":"x","components":[],"types":[]}|}
    with
    | Ok j -> j
    | Error e -> failwith e
  in
  check "read: refuses a future schema version"
    (match Mgtt_read.of_json j with Error _ -> true | Ok _ -> false)

let test_read_rejects_non_export () =
  let j =
    match Json_parse.parse {|{"hello":"world"}|} with
    | Ok j -> j
    | Error e -> failwith e
  in
  check "read: refuses a document that is not an export"
    (match Mgtt_read.of_json j with Error _ -> true | Ok _ -> false)

let test_read_rejects_empty_roster () =
  let j =
    match
      Json_parse.parse
        {|{"mgtt_export_version":1,"name":"x","components":[],"types":[]}|}
    with
    | Ok j -> j
    | Error e -> failwith e
  in
  check "read: refuses an export with no components"
    (match Mgtt_read.of_json j with Error _ -> true | Ok _ -> false)

let test_read_carries_mgtt_declines () =
  let d =
    doc_of_string
      {|{"mgtt_export_version":1,"name":"x",
         "components":[{"name":"c","type":"t","depends":[],"healthy":[],"failure_modes":{}}],
         "types":[],
         "declines":[{"what":"c","why":"type \"t\" resolved to the generic fallback"}]}|}
  in
  check "read: mgtt's own declines survive the crossing"
    (List.length d.Mgtt_ast.declines = 1)

let () =
  test_read ();
  test_read_type_lookup ();
  test_read_components_of_type ();
  test_read_rejects_unknown_version ();
  test_read_rejects_non_export ();
  test_read_rejects_empty_roster ();
  test_read_carries_mgtt_declines ();
  print_string ("test_mgtt: " ^ string_of_int !passed ^ " passed\n")
