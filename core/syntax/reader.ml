(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* The s-expression datum and its hand-written reader (ADR-13). Every datum
   carries its position so later stages can blame it at a line and column. *)

type pos = Errors.pos = { file : string option; line : int; col : int }
type t = Atom of string * pos | List of t list * pos

let pos_of = function Atom (_, p) -> p | List (_, p) -> p

(* A failure positioned at datum [d]. *)
let err_at (d : t) (msg : string) : ('a, Errors.t) result =
  Errors.err ~pos:(pos_of d) msg

(* ---------------------------------------------------------------- reader *)

type cursor = {
  file : string option;
  src : string;
  mutable off : int;
  mutable line : int;
  mutable col : int;
  (* [; writ:TEXT] comments, by line, for tools such as `writ:origin`
     (docs/bridges.md). The language ignores them. *)
  mutable pragmas : (int * string) list;
}

(* Raised inside the reader, converted to a [result] at the boundary. *)
exception Bad of pos * string

(* The one place that builds a position, so every position carries its file,
   even after [Loader] inlines the datum elsewhere. *)
let at c = { file = c.file; line = c.line; col = c.col }
let eof c = c.off >= String.length c.src
let peek c = if eof c then None else Some c.src.[c.off]

let bump c =
  let ch = c.src.[c.off] in
  c.off <- c.off + 1;
  if ch = '\n' then (
    c.line <- c.line + 1;
    c.col <- 1)
  else c.col <- c.col + 1;
  ch

let skip c = ignore (bump c : char)
let is_space ch = ch = ' ' || ch = '\t' || ch = '\n' || ch = '\r'
let is_delim ch = is_space ch || ch = '(' || ch = ')' || ch = ';' || ch = '"'

(* Whitespace and [;] line comments, in any interleaving. *)
let rec skip_trivia c =
  match peek c with
  | Some ch when is_space ch ->
      skip c;
      skip_trivia c
  | Some ';' ->
      let line = c.line in
      let buf = Buffer.create 32 in
      let rec to_eol () =
        match peek c with
        | None | Some '\n' -> ()
        | Some _ ->
            Buffer.add_char buf (bump c);
            to_eol ()
      in
      to_eol ();
      (* Strip the comment markers, then look for the tool prefix. *)
      let text = Buffer.contents buf in
      let n = String.length text in
      let rec skip_marks i =
        if i < n && (text.[i] = ';' || text.[i] = ' ') then skip_marks (i + 1)
        else i
      in
      let i = skip_marks 0 in
      let body = String.sub text i (n - i) in
      let prefix = "writ:" in
      let lp = String.length prefix in
      if String.length body >= lp && String.sub body 0 lp = prefix then
        c.pragmas <-
          (line, String.trim (String.sub body lp (String.length body - lp)))
          :: c.pragmas;
      skip_trivia c
  | Some _ | None -> ()

let unescape ch =
  match ch with 'n' -> '\n' | 't' -> '\t' | 'r' -> '\r' | c -> c

let read_quoted c =
  let start = at c in
  skip c;
  let buf = Buffer.create 16 in
  let rec go () =
    match peek c with
    | None -> raise (Bad (start, "unterminated string"))
    | Some '"' -> skip c
    | Some '\\' ->
        skip c;
        (match peek c with
        | None -> raise (Bad (start, "unterminated string"))
        | Some e ->
            skip c;
            Buffer.add_char buf (unescape e));
        go ()
    | Some _ ->
        Buffer.add_char buf (bump c);
        go ()
  in
  go ();
  Atom (Buffer.contents buf, start)

let read_bare c =
  let start = at c in
  let buf = Buffer.create 16 in
  let rec go () =
    match peek c with
    | Some ch when not (is_delim ch) ->
        Buffer.add_char buf (bump c);
        go ()
    | Some _ | None -> ()
  in
  go ();
  Atom (Buffer.contents buf, start)

let rec read_datum c =
  skip_trivia c;
  let start = at c in
  match peek c with
  | None -> raise (Bad (start, "unexpected end of input"))
  | Some '(' ->
      skip c;
      let rec items acc =
        skip_trivia c;
        match peek c with
        | None ->
            raise (Bad (start, "unbalanced parenthesis: list never closed"))
        | Some ')' ->
            skip c;
            List (List.rev acc, start)
        | Some _ -> items (read_datum c :: acc)
      in
      items []
  | Some ')' -> raise (Bad (start, "unexpected ')'"))
  | Some '"' -> read_quoted c
  | Some _ -> read_bare c

(* [?file] labels positions; it is never opened. Omit it for unnamed text. *)
let read_string_with_pragmas ?file s =
  let c = { file; src = s; off = 0; line = 1; col = 1; pragmas = [] } in
  let rec go acc =
    skip_trivia c;
    if eof c then Ok (List.rev acc, List.rev c.pragmas)
    else go (read_datum c :: acc)
  in
  try go [] with Bad (p, msg) -> Error { Errors.pos = Some p; msg }

let read_string ?file s = Result.map fst (read_string_with_pragmas ?file s)

(* Split a dotted atom [E.a1.…an] into its words. *)
let split_dots (s : string) : string list = String.split_on_char '.' s

(* --------------------------------------------------------------- printer *)

let needs_quote s =
  s = "" || String.exists (fun ch -> is_delim ch || ch = '\\') s

let quote s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter
    (fun ch ->
      match ch with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\r' -> Buffer.add_string buf "\\r"
      | ch -> Buffer.add_char buf ch)
    s;
  Buffer.add_char buf '"';
  Buffer.contents buf

let rec to_string = function
  | Atom (s, _) -> if needs_quote s then quote s else s
  | List (items, _) -> "(" ^ String.concat " " (List.map to_string items) ^ ")"
