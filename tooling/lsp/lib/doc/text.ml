(* THE coordinate module: the only place LSP positions are constructed, and the
   only file allowed to name the [character] field (the position gate enforces
   this). Every conversion between the engine's coordinates and the wire's lives
   here so the arithmetic exists once.

   Two coordinate systems meet:
   - The engine ([Errors.pos]): [line] is 1-based, [col] is a 1-based BYTE
     column. A '\r' is an ordinary column-advancing byte — only '\n' ends a line
     for the engine, so under CRLF the '\r' is the last byte of the line.
   - LSP ([position]): [line] is 0-based, [character] counts UTF-16 code units.

   UTF-16 width of a byte, by its lead: 0x00-0x7F -> 1, a 2-byte lead
   (0xC0-0xDF) -> 1, a 3-byte lead (0xE0-0xEF) -> 1, a 4-byte lead (0xF0-0xF7) ->
   2 (an astral scalar is a surrogate pair), a continuation byte (0x80-0xBF) ->
   0. Summing that over a byte prefix gives the UTF-16 column. *)

type position = { line : int; character : int }
type range = { start : position; stop : position }

(* Each line keeps its trailing '\r' (we split only on '\n') so the byte column
   matches the engine, which never treats '\r' as special. [src] is retained for
   the offset-based scans ([token_range], [word_at]). *)
type t = { src : string; lines : string array }

let of_string src =
  let n = String.length src in
  let acc = ref [] in
  let start = ref 0 in
  for i = 0 to n - 1 do
    if src.[i] = '\n' then (
      acc := String.sub src !start (i - !start) :: !acc;
      start := i + 1)
  done;
  acc := String.sub src !start (n - !start) :: !acc;
  { src; lines = Array.of_list (List.rev !acc) }

(* UTF-16 code units contributed by a lead byte. *)
let units_of_lead b =
  if b < 0x80 then 1
  else if b < 0xC0 then 0 (* continuation *)
  else if b < 0xF0 then 1 (* 2- or 3-byte lead *)
  else 2 (* 4-byte lead -> surrogate pair *)

(* UTF-16 width of the first [nbytes] bytes of [line]. *)
let units_of_prefix line nbytes =
  let nbytes =
    if nbytes < 0 then 0
    else if nbytes > String.length line then String.length line
    else nbytes
  in
  let u = ref 0 in
  for i = 0 to nbytes - 1 do
    u := !u + units_of_lead (Char.code line.[i])
  done;
  !u

let line_at t i = if i >= 0 && i < Array.length t.lines then t.lines.(i) else ""

(* Byte offset of the start of line [i] in [src]: the sum of prior line lengths
   plus one '\n' each. *)
let base_offset t i =
  let b = ref 0 in
  for k = 0 to i - 1 do
    b := !b + String.length t.lines.(k) + 1
  done;
  !b

(* Engine position (1-based line, 1-based byte col) -> LSP position. *)
let lsp_of_pos t (p : Pol_data.Errors.pos) =
  let line = p.line - 1 in
  { line; character = units_of_prefix (line_at t line) (p.col - 1) }

(* LSP position -> byte offset into [src]. Out-of-range lines and columns clamp
   to the nearest valid boundary; this never raises. *)
let offset_of_lsp t (p : position) =
  let nlines = Array.length t.lines in
  let li =
    if p.line < 0 then 0 else if p.line >= nlines then nlines - 1 else p.line
  in
  let line = t.lines.(li) in
  let len = String.length line in
  let target = if p.character < 0 then 0 else p.character in
  let i = ref 0 and units = ref 0 in
  while !i < len && !units < target do
    units := !units + units_of_lead (Char.code line.[!i]);
    incr i;
    while !i < len && Char.code line.[!i] land 0xC0 = 0x80 do
      incr i
    done
  done;
  base_offset t li + !i

(* Byte offset into [src] -> LSP position (clamping the offset into range). *)
let lsp_of_offset t off =
  let off = if off < 0 then 0 else off in
  let nlines = Array.length t.lines in
  let rec go i acc =
    if i >= nlines - 1 then
      let line = t.lines.(nlines - 1) in
      let b =
        if off - acc > String.length line then String.length line else off - acc
      in
      { line = nlines - 1; character = units_of_prefix line b }
    else
      let len = String.length t.lines.(i) in
      if off <= acc + len then
        { line = i; character = units_of_prefix t.lines.(i) (off - acc) }
      else go (i + 1) (acc + len + 1)
  in
  go 0 0

let is_delim c =
  c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '(' || c = ')' || c = ';'
  || c = '"'

(* Re-scan the token whose start is [start], returning its range. A [String]
   token runs to the closing quote; if the quote never closes (EOF or end of
   line) the range stops there. Any other token runs to the next delimiter. *)
let token_range t start =
  let src = t.src in
  let n = String.length src in
  let s0 = offset_of_lsp t start in
  let e = ref s0 in
  if !e < n && src.[!e] = '"' then (
    incr e;
    let closed = ref false in
    while (not !closed) && !e < n do
      match src.[!e] with
      | '\\' when !e + 1 < n -> e := !e + 2
      | '"' ->
          incr e;
          closed := true
      | '\n' -> closed := true (* unclosed string: stop at the line end *)
      | _ -> incr e
    done)
  else
    while !e < n && not (is_delim src.[!e]) do
      incr e
    done;
  { start; stop = lsp_of_offset t !e }

(* The full extent of a parenthesised form: its opening '(' through the matching
   ')', skipping "strings" and ; comments so a paren inside them does not count.
   token_range returns a ZERO-WIDTH span on a '(' (a delimiter), which cannot
   contain a symbol's selectionRange — an LSP invariant a client enforces by
   rejecting the whole documentSymbol response. A non-'(' start falls back to
   token_range. *)
let form_range t start =
  let src = t.src in
  let n = String.length src in
  let s0 = offset_of_lsp t start in
  if s0 >= n || src.[s0] <> '(' then token_range t start
  else begin
    let e = ref (s0 + 1) and depth = ref 1 in
    while !depth > 0 && !e < n do
      match src.[!e] with
      | '"' ->
          incr e;
          let closed = ref false in
          while (not !closed) && !e < n do
            match src.[!e] with
            | '\\' when !e + 1 < n -> e := !e + 2
            | '"' ->
                incr e;
                closed := true
            | _ -> incr e
          done
      | ';' ->
          while !e < n && src.[!e] <> '\n' do
            incr e
          done
      | '(' ->
          incr depth;
          incr e
      | ')' ->
          decr depth;
          incr e
      | _ -> incr e
    done;
    { start; stop = lsp_of_offset t !e }
  end

(* The maximal run of non-delimiter bytes around byte offset [off], with its
   range. At a delimiter this is the empty word. *)
let word_at t off =
  let src = t.src in
  let n = String.length src in
  let off = if off < 0 then 0 else if off > n then n else off in
  let s = ref off in
  while !s > 0 && not (is_delim src.[!s - 1]) do
    decr s
  done;
  let e = ref off in
  while !e < n && not (is_delim src.[!e]) do
    incr e
  done;
  ( String.sub src !s (!e - !s),
    { start = lsp_of_offset t !s; stop = lsp_of_offset t !e } )

(* The whole of line [i], as a range — where a diagnostic with no datum to blame
   lands (a first-line squiggle rather than a dropped error). *)
let line_range t i =
  let n = if i >= 0 && i < Array.length t.lines then i else 0 in
  let line = line_at t n in
  {
    start = { line = n; character = 0 };
    stop = { line = n; character = units_of_prefix line (String.length line) };
  }

(* --- the wire crossing. LSP positions carry a [character] field, so every JSON
   that mentions one is built and read HERE and nowhere else (the position gate).
   A range's end key is the reserved word "end", hence [stop] renders as "end". *)

let json_of_position (p : position) : Json.t =
  Json.Assoc [ ("line", Json.Int p.line); ("character", Json.Int p.character) ]

let json_of_range (r : range) : Json.t =
  Json.Assoc
    [ ("start", json_of_position r.start); ("end", json_of_position r.stop) ]

let position_of_json (j : Json.t) : position option =
  match (Json.member "line" j, Json.member "character" j) with
  | Some (Json.Int line), Some (Json.Int character) -> Some { line; character }
  | _ -> None
