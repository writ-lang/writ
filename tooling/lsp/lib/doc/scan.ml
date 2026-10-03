(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* What a byte offset is inside, from the raw bytes, for completion on a
   document that does not parse. The scan runs forward from the start: read
   backward, an opening quote looks like a closing one. *)

let is_space ch = ch = ' ' || ch = '\t' || ch = '\n' || ch = '\r'
let is_delim ch = is_space ch || ch = '(' || ch = ')' || ch = ';' || ch = '"'

(* One past the closing quote of the string opening at [o] (backslash escapes
   honoured), or [None] when it never closes. *)
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

(* The newline ending the comment opening at [o], or the end of the source. *)
let comment_stop src n o =
  let rec go i = if i >= n || src.[i] = '\n' then i else go (i + 1) in
  go o

(* One past the delimiter-bounded atom starting at [o]. *)
let atom_stop src n o =
  let rec go i = if i >= n || is_delim src.[i] then i else go (i + 1) in
  go o

let trivia_stop src n o =
  let rec go i =
    if i >= n then i
    else if is_space src.[i] then go (i + 1)
    else if src.[i] = ';' then go (comment_stop src n i)
    else i
  in
  go o

let token_stop src n o =
  if o >= n then o
  else
    match src.[o] with
    | '"' -> string_stop src n o
    | ';' -> comment_stop src n o
    | _ -> atom_stop src n o

(* ------------------------------------------------------------- the state *)

(* [Prose] is inside a string or comment; [Code] holds the offsets of the
   open lists, innermost first. *)
type state = Prose | Code of int list

let state src off =
  let n = String.length src in
  let off = if off < 0 then 0 else if off > n then n else off in
  let rec go i stack =
    if i >= off then Code stack
    else
      match src.[i] with
      | '(' -> go (i + 1) (i :: stack)
      (* A stray ')' closes nothing. *)
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

(* The innermost list open at [off]: its head, the complete atoms before
   [off], and whether [off] is in the head. A partial token is not an
   argument. *)
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
              (* [e <= s] would loop forever *)
              if e >= off || e <= s then List.rev acc
              else go e (String.sub src s (e - s) :: acc)
          in
          Some { head; args = go he []; in_head = false }
