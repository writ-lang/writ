(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Flag extraction for the dispatch in [Writ], kept in the library so tests
   can link it. Flags are removed before positionals are counted, so each
   verb's positional shapes stay unambiguous. *)

(* Remove every [flag] and report whether it was there. With [--stdin] gone,
   `writ query --stdin health` has one positional: the query name. *)
let take_flag (flag : string) (args : string list) : bool * string list =
  let rest = List.filter (fun a -> a <> flag) args in
  (List.length rest <> List.length args, rest)

let take_stdin = take_flag "--stdin"
let take_json = take_flag "--json"

(* [--fiber CELL], repeatable: every occurrence comes out, in order. *)
let take_fibers (args : string list) : string list * string list =
  let rec go cells acc = function
    | [] -> (List.rev cells, List.rev acc)
    | "--fiber" :: c :: rest -> go (c :: cells) acc rest
    | a :: rest -> go cells (a :: acc) rest
  in
  go [] [] args

(* A trailing [--claims] with no file stays in the list, so it fails the
   positional match and reaches the usage message. *)
let take_claims (args : string list) : string option * string list =
  let rec go acc = function
    | [] -> (None, List.rev acc)
    | "--claims" :: file :: rest -> (Some file, List.rev_append acc rest)
    | a :: rest -> go (a :: acc) rest
  in
  go [] args

let take_certificate (args : string list) : string option * string list =
  let rec go acc = function
    | [] -> (None, List.rev acc)
    | "--certificate" :: file :: rest -> (Some file, List.rev_append acc rest)
    | a :: rest -> go (a :: acc) rest
  in
  go [] args

let take_no_certificate = take_flag "--no-certificate"
