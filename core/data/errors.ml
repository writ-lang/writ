(* A positioned diagnostic: what was wrong, and where. [pos] is [None] for the
   errors that hold no datum to blame, so an editor can tell "put a squiggle
   here" from "there is nowhere to put one" without parsing a string back.

   The file rides on the POSITION rather than being attached by whoever prints
   the error, because [Loader] inlines a loaded library's datums into the loading
   file's list: after that splice, the only thing that still knows which file a
   line and column index is the coordinate itself. A printer that labels the
   error with the path it was handed is right for a single file and wrong for
   every load — and a WRONG filename is worse than no filename at all. An absent
   one sends the reader looking; a wrong one sends them somewhere specific and
   tells them, with false confidence, that the fault is there.

   [file = None] is meaningful and is not "no position": it means the text was
   read from a string that has no name — a query typed on the command line, a
   buffer checked for its shape. The line and column are no less real for it. *)

type pos = { file : string option; line : int; col : int }
type t = { pos : pos option; msg : string }

let to_string d =
  match d.pos with
  | None -> d.msg
  | Some p ->
      let where = string_of_int p.line ^ ":" ^ string_of_int p.col in
      (match p.file with Some f -> f ^ ":" ^ where | None -> where)
      ^ ": " ^ d.msg

(* Build a failed [result] carrying a diagnostic. [pos] is optional so the
   callers that have a datum to blame supply one and the rest do not. *)
let err ?pos msg : ('a, t) result = Error { pos; msg }
