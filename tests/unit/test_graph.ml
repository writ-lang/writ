(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* `writ graph` over captured_trap, whose one-way capture is the crossing edge
   the trap's witness lights. *)

open Writ_data
open Writ_syntax
open Writ_runtime

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let contains ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

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

let load path =
  match Loader.read_model resolve path with
  | Ok m -> (
      match Space.build m with Ok sp -> (m, sp) | Error e -> failwith e)
  | Error e -> failwith (Errors.to_string e)

let () =
  let m, sp = load "captured_trap.writ" in
  let g = Graph.phases sp in
  let n = Array.length sp.Space.states in
  check "phases: fewer nodes than situations" (List.length g.Graph.nodes < n);
  check "phases: sizes add up to the space"
    (List.fold_left (fun a (x : Graph.node) -> a + x.Graph.size) 0 g.Graph.nodes
    = n);
  check "phases: exactly one initial node"
    (List.length
       (List.filter (fun (x : Graph.node) -> x.Graph.initial) g.Graph.nodes)
    = 1);
  check "phases: the initial node is #0"
    (List.exists
       (fun (x : Graph.node) -> x.Graph.initial && x.Graph.id = 0)
       g.Graph.nodes);
  check "phases: a final node exists"
    (List.exists (fun (x : Graph.node) -> x.Graph.final) g.Graph.nodes);
  check "phases: the gap is attached to some node"
    (List.exists (fun (x : Graph.node) -> x.Graph.gaps <> []) g.Graph.nodes);
  check "phases: a crossing is named after the capture"
    (List.exists
       (fun (e : Graph.edge) -> List.mem "capture-watchdog" e.Graph.moves)
       g.Graph.edges);
  check "phases: no edge stays inside a node"
    (List.for_all
       (fun (e : Graph.edge) -> e.Graph.src <> e.Graph.dst)
       g.Graph.edges);
  (* The witness of the failing live: one capture, lighting one crossing. *)
  let cl =
    match Loader.read_claims resolve m "captured_trap.claims" with
    | Ok c -> c
    | Error e -> failwith (Errors.to_string e)
  in
  let p = List.hd cl.Claims.props in
  let route =
    match Checker.check sp p with
    | Checker.Fails { route; _ } -> route
    | _ -> failwith "expected the trap to fail"
  in
  let lit = Graph.light sp g route in
  check "light: the initial node is lit" (List.mem 0 lit.Graph.lit_nodes);
  check "light: one crossing is lit" (List.length lit.Graph.lit_edges = 1);
  check "light: the lit crossing leaves the initial phase"
    (match lit.Graph.lit_edges with [ (0, _) ] -> true | _ -> false);
  let d2 = Graph.to_d2 lit in
  check "d2: declares the witness class"
    (contains ~sub:"classes: { witness:" d2);
  check "d2: the start node is labelled" (contains ~sub:"\"start #0" d2);
  check "d2: the capture labels a crossing"
    (contains ~sub:"capture-watchdog" d2);
  check "d2: the lit crossing carries the class"
    (contains ~sub:"{class: witness}" d2);
  check "d2: the gap is a dashed exit"
    (contains ~sub:"gap {style.stroke-dash: 3}" d2);
  let dot = Graph.to_dot lit in
  check "dot: is a digraph" (contains ~sub:"digraph writ {" dot);
  check "dot: a final node is double-bordered"
    (contains ~sub:"peripheries=2" dot);
  check "dot: the lit crossing is coloured" (contains ~sub:"penwidth=3" dot);
  let raw = Graph.states sp in
  check "states: one node per situation" (List.length raw.Graph.nodes = n);
  check "states: every node has size 1"
    (List.for_all (fun (x : Graph.node) -> x.Graph.size = 1) raw.Graph.nodes);
  let lit_raw = Graph.light sp raw route in
  check "states: the witness lights its landing"
    (List.length lit_raw.Graph.lit_nodes = 2
    && List.length lit_raw.Graph.lit_edges = 1);
  print_string ("test_graph: " ^ string_of_int !passed ^ " checks passed\n")
