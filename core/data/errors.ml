(* A positioned diagnostic: what was wrong, and where. [pos] is [None] for the
   errors that hold no datum to blame, so an editor can tell "put a squiggle
   here" from "there is nowhere to put one" without parsing a string back. *)

type pos = { line : int; col : int }
type t = { pos : pos option; msg : string }

let to_string d =
  match d.pos with
  | None -> d.msg
  | Some p -> string_of_int p.line ^ ":" ^ string_of_int p.col ^ ": " ^ d.msg

(* Build a failed [result] carrying a diagnostic. [pos] is optional so the
   callers that have a datum to blame supply one and the rest do not. *)
let err ?pos msg : ('a, t) result = Error { pos; msg }
