(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Argument shapes shared by the dispatch and its tests.

   [Writ] is an executable's main module and cannot be linked into a test, so
   the one piece of the dispatch with a decision in it lives here instead of
   being verified only by running the binary. *)

(* Remove [--stdin] wherever it appears and report whether it was there.
   Flags come out before positionals are counted, which is the whole reason
   `writ query --stdin health` is unambiguous: with the model gone from the
   positionals, one argument remains and it can only be the query name. A
   bare `writ query health` could not be told apart from a model named
   `health` with a missing query name, which is why the bare form was
   rejected. *)
let take_flag (flag : string) (args : string list) : bool * string list =
  let rest = List.filter (fun a -> a <> flag) args in
  (List.length rest <> List.length args, rest)

let take_stdin = take_flag "--stdin"

(* [--json] is taken the same way, for the same reason, and before [--stdin]
   is: an output format is orthogonal to every verb's positionals, so it must
   never be counted among them. *)
let take_json = take_flag "--json"

(* Remove [--claims FILE] and report the file, for the same reason: pulling the
   pair out before the positionals are counted keeps every remaining shape the
   arity it already had, so adding the flag costs the match no new cases.

   A trailing [--claims] with nothing after it returns [None] and leaves the
   flag in the list, where it fails the positional match and reaches the usage
   message — which is the right answer, and better than silently querying the
   sibling as though the flag had not been typed. *)
let take_claims (args : string list) : string option * string list =
  let rec go acc = function
    | [] -> (None, List.rev acc)
    | "--claims" :: file :: rest -> (Some file, List.rev_append acc rest)
    | a :: rest -> go (a :: acc) rest
  in
  go [] args
