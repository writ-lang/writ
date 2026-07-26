open Pol_data

(* The s-expression datum and its hand-written reader.

   ADR-13 makes s-expressions the canonical model format, read directly by the
   engine with no parser library. Positions live on the datum rather than in a
   separate reader module because the parser downstream reports arity and shape
   errors against them, and a datum that has lost its position cannot be blamed
   at a line and column. *)

(* An alias, not a second record: [Errors.t] carries this position, and a
   diagnostic may exist without one. *)
type pos = Errors.pos = { file : string option; line : int; col : int }
type t = Atom of string * pos | List of t list * pos

let pos_of = function Atom (_, p) -> p | List (_, p) -> p

(* The shape every decoder error takes: a positioned failure at a datum's own
   source position. Lives here so the front end says [Reader.err_at d msg]
   rather than spelling out the position plumbing at each of its call sites. *)
let err_at (d : t) (msg : string) : ('a, Errors.t) result =
  Errors.err ~pos:(pos_of d) msg

(* ---------------------------------------------------------------- reader *)

type cursor = {
  file : string option;
  src : string;
  mutable off : int;
  mutable line : int;
  mutable col : int;
}

(* Raised inside the reader, converted to a [result] at the boundary. *)
exception Bad of pos * string

(* The ONE place in the engine that builds a position — which is why the file
   name is stamped here rather than bolted on by whoever reports the error. Every
   position the front end blames a datum at comes through [at], so every one of
   them knows its own file for free, and keeps knowing it after [Loader] has
   inlined the datum into another file's list. *)
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
      let rec to_eol () =
        match peek c with
        | None | Some '\n' -> ()
        | Some _ ->
            skip c;
            to_eol ()
      in
      to_eol ();
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

(* [?file] is the name the text came from — a name, never a path this reader
   opens: reading text is what it does, finding it is the caller's job. Omitting
   it is not a degraded mode, it is the honest answer for text that has no file
   (a query typed on the command line, an unnamed buffer), and reading that way
   behaves exactly as it always did. *)
let read_string ?file s =
  let c = { file; src = s; off = 0; line = 1; col = 1 } in
  let rec go acc =
    skip_trivia c;
    if eof c then Ok (List.rev acc) else go (read_datum c :: acc)
  in
  try go [] with Bad (p, msg) -> Error { Errors.pos = Some p; msg }

(* Split a dotted atom [E.a1.…an] into its literal words. The parser uses this
   to turn a path atom into a [Value.path]. *)
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
