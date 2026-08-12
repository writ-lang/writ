(* [Cmd_show] — the [pol show] verb: print what a situation IS, addressed by the
   index the rest of the tool already uses.

   It exists because `pol derive` answers with state indices. A rules file that
   derives the blocked situations of a protocol says `17, 19, …`, and until now
   the only way to learn what 17 held was to write a query per cell and run
   `pol query --at 17` for each — so the two instruments shared a numbering that
   only one of them could read back. Nothing new is computed here: the space,
   the shortest routes and the cell layout are all built already, and this is
   the verb that reaches them.

   Several [--at] are allowed, and that is the shape the caller has: a
   derivation answers with a set of rows, not with one. *)

open Pol_runtime
open Cli_io

(* An index outside the space is a bad command line (2), not an empty answer —
   the caller is asking about a situation this model never reaches. Same reading
   as [Cmd_query]'s [--at], and the same message shape. *)
let index (sp : Space.t) (s : string) : int =
  match int_of_string_opt s with
  | Some i when i >= 0 && i < Array.length sp.Space.states -> i
  | _ -> die 2 ("--at expects a state index in range: " ^ s)

(* [--at N] repeated, or nothing at all — which shows the initial situation, the
   default [pol query] already uses for the same flag. *)
let rec ats (acc : string list) (argv : string list) : string list =
  match argv with
  | [] -> if acc = [] then [ "0" ] else List.rev acc
  | "--at" :: n :: rest -> ats (n :: acc) rest
  | _ -> die 2 "pol show MODEL.pol [--at STATE]…"

let run (model : string) (argv : string list) =
  let m = load_model (make_resolve model) model in
  let sp = build_space model m in
  let idxs = List.map (index sp) (ats [] argv) in
  say (String.concat "\n\n" (List.map (Report.situation sp) idxs));
  flush stdout;
  exit 0
