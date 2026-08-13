(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Reading a .sql file down to statements and tokens.

   The job here is smaller than "lex SQL" and the difference matters: `writ sql`
   must survive a whole pg_dump, of which it understands a few statements and
   must SKIP the rest without being derailed. So the lexer's real obligation is
   to find statement boundaries correctly in text it does not otherwise
   understand — which means getting quoting exactly right, since a `;` inside a
   dollar-quoted function body or a string literal is not a boundary and a
   splitter that thinks it is will cut a file into nonsense and report a
   cascade of errors that are all one error.

   Everything else is deliberately shallow: a token stream flat enough that the
   parser can dispatch on the first word and, where it does not recognise it,
   drop the statement with its line number.

   Line numbers are carried on every token rather than on statements alone,
   because a decline should point at the COLUMN it declined, not at the top of
   a forty-column table. *)

type token =
  | Word of string  (** unquoted identifier or keyword, folded to lower *)
  | Quoted of string  (** "quoted identifier" — case preserved *)
  | Str of string  (** 'string literal' *)
  | Num of string
  | Punct of char
  | Op of string  (** = <> != < <= > >= *)

type tok = { tk : token; line : int }
type stmt = { sline : int; toks : tok list }

(* A `-- writ: …` trailing comment. The export writes these to record the two
   facts SQL has no way to state — that an arrow is `fixed`, or that a foreign
   key is not — and the import reads them back, which is what closes the round
   trip for a mutable reference. Keyed by LINE, because that is how a reader
   associates a trailing comment with what it trails. *)
type lexed = { stmts : stmt list; pragmas : (int * string) list }

let is_digit c = c >= '0' && c <= '9'

let is_word_start c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'

let is_word c = is_word_start c || is_digit c || c = '$'

let starts_with ~(prefix : string) (s : string) =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* A dollar quote opens with `$tag$`, tag being a possibly-empty identifier. It
   is not enough to see a `$`: `a$b` is a legal identifier character sequence,
   so the tag must be scanned and the closing `$` found before this is treated
   as a quote at all. *)
let dollar_tag (s : string) (i : int) : string option =
  let n = String.length s in
  if i >= n || s.[i] <> '$' then None
  else
    let j = ref (i + 1) in
    while !j < n && is_word_start s.[!j] do
      incr j
    done;
    if !j < n && s.[!j] = '$' then Some (String.sub s i (!j - i + 1)) else None

let lex (src : string) : lexed =
  let n = String.length src in
  let line = ref 1 in
  let stmts = ref [] and pragmas = ref [] in
  let cur = ref [] and cur_line = ref 1 in
  let emit tk = cur := { tk; line = !line } :: !cur in
  let flush () =
    (match !cur with
    | [] -> ()
    | ts -> stmts := { sline = !cur_line; toks = List.rev ts } :: !stmts);
    cur := [];
    cur_line := !line
  in
  let bump c = if c = '\n' then incr line in
  let i = ref 0 in
  while !i < n do
    let c = src.[!i] in
    if c = '-' && !i + 1 < n && src.[!i + 1] = '-' then begin
      (* line comment; a `writ:` one is kept, the rest discarded *)
      let start = !i + 2 in
      let j = ref start in
      while !j < n && src.[!j] <> '\n' do
        incr j
      done;
      let body = String.trim (String.sub src start (!j - start)) in
      let pragma = "writ:" in
      if starts_with ~prefix:pragma body then begin
        (* length-derived, not a literal: the prefix has changed once
           already, and a stale offset here loses the pragma silently *)
        let k = String.length pragma in
        pragmas :=
          (!line, String.trim (String.sub body k (String.length body - k)))
          :: !pragmas
      end;
      i := !j
    end
    else if c = '/' && !i + 1 < n && src.[!i + 1] = '*' then begin
      (* block comment, nested — PostgreSQL's are *)
      let depth = ref 1 in
      i := !i + 2;
      while !depth > 0 && !i < n do
        if !i + 1 < n && src.[!i] = '/' && src.[!i + 1] = '*' then begin
          incr depth;
          i := !i + 2
        end
        else if !i + 1 < n && src.[!i] = '*' && src.[!i + 1] = '/' then begin
          decr depth;
          i := !i + 2
        end
        else begin
          bump src.[!i];
          incr i
        end
      done
    end
    else if c = '\'' then begin
      let buf = Buffer.create 16 in
      incr i;
      let fin = ref false in
      while (not !fin) && !i < n do
        if src.[!i] = '\'' then
          if !i + 1 < n && src.[!i + 1] = '\'' then begin
            Buffer.add_char buf '\'';
            i := !i + 2
          end
          else begin
            incr i;
            fin := true
          end
        else begin
          bump src.[!i];
          Buffer.add_char buf src.[!i];
          incr i
        end
      done;
      emit (Str (Buffer.contents buf))
    end
    else if c = '"' then begin
      let buf = Buffer.create 16 in
      incr i;
      let fin = ref false in
      while (not !fin) && !i < n do
        if src.[!i] = '"' then
          if !i + 1 < n && src.[!i + 1] = '"' then begin
            Buffer.add_char buf '"';
            i := !i + 2
          end
          else begin
            incr i;
            fin := true
          end
        else begin
          bump src.[!i];
          Buffer.add_char buf src.[!i];
          incr i
        end
      done;
      emit (Quoted (Buffer.contents buf))
    end
    else
      match dollar_tag src !i with
      | Some tag ->
          (* skip the whole dollar-quoted body; nothing inside is ours *)
          let tl = String.length tag in
          i := !i + tl;
          let fin = ref false in
          while (not !fin) && !i < n do
            if !i + tl <= n && String.sub src !i tl = tag then begin
              i := !i + tl;
              fin := true
            end
            else begin
              bump src.[!i];
              incr i
            end
          done;
          emit (Str "")
      | None ->
          if c = ';' then begin
            incr i;
            flush ()
          end
          else if c = ' ' || c = '\t' || c = '\n' || c = '\r' then begin
            bump c;
            incr i;
            if !cur = [] then cur_line := !line
          end
          else if is_word_start c then begin
            let start = !i in
            while !i < n && is_word src.[!i] do
              incr i
            done;
            emit
              (Word (String.lowercase_ascii (String.sub src start (!i - start))))
          end
          else if is_digit c then begin
            let start = !i in
            while !i < n && (is_digit src.[!i] || src.[!i] = '.') do
              incr i
            done;
            emit (Num (String.sub src start (!i - start)))
          end
          else if
            c = '<' && !i + 1 < n && (src.[!i + 1] = '>' || src.[!i + 1] = '=')
          then begin
            emit (Op (String.sub src !i 2));
            i := !i + 2
          end
          else if c = '!' && !i + 1 < n && src.[!i + 1] = '=' then begin
            emit (Op "<>");
            i := !i + 2
          end
          else if c = '>' && !i + 1 < n && src.[!i + 1] = '=' then begin
            emit (Op ">=");
            i := !i + 2
          end
          else if c = '=' || c = '<' || c = '>' then begin
            emit (Op (String.make 1 c));
            incr i
          end
          else begin
            emit (Punct c);
            incr i
          end
  done;
  flush ();
  { stmts = List.rev !stmts; pragmas = List.rev !pragmas }
