(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The lexical layer: what a byte offset is inside, from bytes alone.

   Everything above this file works on a datum tree or on editor coordinates.
   This one works on the raw source, because completion runs on a document that
   does NOT parse: the moment the author types [(] the reader returns an error
   and there is no tree at all, which is exactly the keystroke after which the
   kind or value names should be offered.

   THE SCAN RUNS FORWARD from the start of the document, never backward from the
   offset, and the reason is in models/presidential.writ: its (cite "…") holds
   "(veto, override)" INSIDE a quoted atom. Read from the right, an opening quote
   cannot be told from a closing one, so those parentheses count and the depth is
   wrong for the whole rest of the file. Read from the left, strings and comments
   are skipped whole with the same rules the reader uses, and one pass costs
   nothing worth saving. This is a hard lesson from the prior LSP run.

   No LSP coordinate crosses this file — it is offsets and bytes only, so the
   position token stays confined to text.ml. *)

let is_space ch = ch = ' ' || ch = '\t' || ch = '\n' || ch = '\r'
let is_delim ch = is_space ch || ch = '(' || ch = ')' || ch = ';' || ch = '"'

(* One past the closing quote of the string opening at [o], or [None] when it
   never closes — the normal state of a citation half typed. Backslash escapes
   are honoured, so an escaped quote inside the string does not end it. *)
let string_close src n o =
  let rec go i =
    if i >= n then None
    else
      match src.[i] with
      | '"' -> Some (i + 1)
      | '\\' -> go (i + 2)
      | _ -> go (i + 1)
  in
  go (o + 1)

let string_stop src n o =
  match string_close src n o with Some stop -> stop | None -> n

(* The newline that ends the comment opening at [o], or the end of the source.
   The newline is the terminator and not part of the comment. *)
let comment_stop src n o =
  let rec go i = if i >= n || src.[i] = '\n' then i else go (i + 1) in
  go o

(* One past the delimiter-bounded atom starting at [o]. *)
let atom_stop src n o =
  let rec go i = if i >= n || is_delim src.[i] then i else go (i + 1) in
  go o

(* Whitespace and comments, which separate tokens and are never one. *)
let trivia_stop src n o =
  let rec go i =
    if i >= n then i
    else if is_space src.[i] then go (i + 1)
    else if src.[i] = ';' then go (comment_stop src n i)
    else i
  in
  go o

(* One past the token starting at [o]: a list runs to its match, a string to its
   close, a comment to its newline, anything else to the next delimiter. *)
let token_stop src n o =
  if o >= n then o
  else
    match src.[o] with
    | '"' -> string_stop src n o
    | ';' -> comment_stop src n o
    | _ -> atom_stop src n o

(* ------------------------------------------------------------- the state *)

(* [Prose] is inside a citation or a comment: bytes the language never reads,
   where completion owes the author nothing. [Code] carries the byte offsets of
   the lists still open at the position, innermost first.

   Both ends of a span are decided separately. A comment ends AT its newline, so
   an offset equal to [comment_stop] is still inside it — exactly where the
   cursor sits while a note is being typed. A string ends one PAST its closing
   quote; a string that never closes runs to end of source, which is where the
   cursor sits while the citation is being typed. *)
type state = Prose | Code of int list

let state src off =
  let n = String.length src in
  let off = if off < 0 then 0 else if off > n then n else off in
  let rec go i stack =
    if i >= off then Code stack
    else
      match src.[i] with
      | '(' -> go (i + 1) (i :: stack)
      (* A stray ')' closes nothing rather than raising: a normal state of a
         file being typed. *)
      | ')' -> go (i + 1) (match stack with _ :: rest -> rest | [] -> [])
      | '"' -> (
          match string_close src n i with
          | None -> Prose
          | Some stop -> if stop > off then Prose else go stop stack)
      | ';' ->
          let stop = comment_stop src n i in
          if stop >= off then Prose else go stop stack
      | _ -> go (i + 1) stack
  in
  go 0 []

let in_prose src off =
  match state src off with Prose -> true | Code _ -> false

(* ------------------------------------------------------------- open form *)

(* The innermost list still open at [off]: its head atom, the COMPLETE atoms
   written between that head and [off], and whether [off] is still inside the
   head itself. A partial token at the offset is deliberately not an argument —
   [(entity nab] names no kind yet; the client filters the offered names by that
   partial prefix. *)
type form = { head : string; args : string list; in_head : bool }

let open_form src off : form option =
  let n = String.length src in
  let off = if off < 0 then 0 else if off > n then n else off in
  match state src off with
  | Prose | Code [] -> None
  | Code (opening :: _) ->
      let hs = trivia_stop src n (opening + 1) in
      if hs >= off then Some { head = ""; args = []; in_head = true }
      else
        let he = atom_stop src n hs in
        let head = String.sub src hs (he - hs) in
        if he >= off then Some { head; args = []; in_head = true }
        else
          let rec go i acc =
            let s = trivia_stop src n i in
            if s >= off then List.rev acc
            else
              let e = token_stop src n s in
              (* [e >= off] is the token being typed; a scan that fails to
                 advance ([e <= s]) is refused so a request cannot hang. *)
              if e >= off || e <= s then List.rev acc
              else go e (String.sub src s (e - s) :: acc)
          in
          Some { head; args = go he []; in_head = false }
