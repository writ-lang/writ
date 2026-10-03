(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* A numeric column cut into regions by the constants the schema compares it
   against. Every CHECK is constant on a region, so a region can stand in for
   the value losslessly (docs/tractability.md §3). The parser cuts; the
   emitter classifies a seed row's number. *)

let name (k : int) : string =
  if k < 0 then "minus" ^ string_of_int (-k) else string_of_int k

(* The pieces, each with a representative value inside it, in range order.
   An integral column has no piece strictly between two adjacent integers. *)
let pieces ~(integral : bool) (cuts : int list) : (string * float) list =
  let rec go prev = function
    | [] -> []
    | c :: rest ->
        let before =
          match prev with
          | None -> [ ("below-" ^ name c, float_of_int c -. 1.0) ]
          | Some p ->
              if integral && c - p = 1 then []
              else
                [
                  ( "between-" ^ name p ^ "-and-" ^ name c,
                    (float_of_int p +. float_of_int c) /. 2.0 );
                ]
        in
        let after =
          if rest = [] then [ ("above-" ^ name c, float_of_int c +. 1.0) ]
          else []
        in
        before
        @ [ ("exactly-" ^ name c, float_of_int c) ]
        @ after @ go (Some c) rest
  in
  go None cuts

(* The piece a value falls in. *)
let classify (cuts : int list) (x : float) : string =
  let rec find prev = function
    | [] -> (
        match prev with Some p -> "above-" ^ name p | None -> "unbounded")
    | c :: rest ->
        let fc = float_of_int c in
        if x < fc then
          match prev with
          | None -> "below-" ^ name c
          | Some p -> "between-" ^ name p ^ "-and-" ^ name c
        else if x = fc then "exactly-" ^ name c
        else find (Some c) rest
  in
  find None cuts
