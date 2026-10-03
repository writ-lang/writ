(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ graph]: the state space as D2 (default), DOT or JSON. It draws the
   phase quotient; [--states] draws every situation, up to [Graph.cap].
   [--witness P] highlights a property's route, with P taken from the sibling
   [.claims] or [--claims]. *)

open Writ_data
open Writ_runtime
open Cli_io

type opts = {
  claims : string option;
  format : [ `D2 | `Dot | `Json ];
  witnesses : string list;
  by_states : bool;
}

let rec parse (o : opts) = function
  | [] -> o
  | "--claims" :: f :: rest -> parse { o with claims = Some f } rest
  | "--d2" :: rest -> parse { o with format = `D2 } rest
  | "--dot" :: rest -> parse { o with format = `Dot } rest
  | "--json" :: rest -> parse { o with format = `Json } rest
  | "--witness" :: p :: rest ->
      parse { o with witnesses = o.witnesses @ [ p ] } rest
  | "--states" :: rest -> parse { o with by_states = true } rest
  | a :: _ -> die 2 ("graph: unknown option " ^ a)

let run (model : string) (argv : string list) =
  let o =
    parse
      { claims = None; format = `D2; witnesses = []; by_states = false }
      argv
  in
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let sp = build_space model m in
  let n = Array.length sp.Space.states in
  let g =
    if o.by_states then
      if n > Graph.cap then
        die 2
          (string_of_int n ^ " situations is more than --states will draw (cap "
         ^ string_of_int Graph.cap ^ "); the phase picture has "
          ^ string_of_int (List.length (Graph.phases sp).Graph.nodes)
          ^ " nodes — drop --states")
      else Graph.states sp
    else Graph.phases sp
  in
  let g =
    match o.witnesses with
    | [] -> g
    | names ->
        let cpath =
          match o.claims with
          | Some p -> p
          | None when model = stdin_name ->
              die 2
                "graph: a model read from stdin has no sibling .claims — pass \
                 --claims FILE"
          | None -> claims_beside model
        in
        let claims = read_claims resolve m cpath in
        List.fold_left
          (fun g name ->
            match
              List.find_opt
                (fun (p : Claims.property) -> p.name = name)
                claims.props
            with
            | None -> die 2 ("no property named `" ^ name ^ "` in " ^ cpath)
            | Some p -> (
                match Checker.check sp p with
                | Checker.Holds route | Checker.Fails { route; _ } ->
                    Graph.light sp g route
                | Checker.Not_applicable _ -> g))
          g names
  in
  say
    (match o.format with
    | `D2 -> Graph.to_d2 g
    | `Dot -> Graph.to_dot g
    | `Json -> Json.to_string (Report_json.graph g));
  flush stdout;
  exit 0
