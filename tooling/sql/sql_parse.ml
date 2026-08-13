(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* DDL -> [Sql_ast.db]. A recursive-descent reader over [Sql_lex]'s tokens that
   recognises the handful of statements carrying schema MEANING and declines
   everything else by name and line.

   The rule throughout: never repair, never guess. A construct half-understood
   is worse than one refused, because the refusal appears in the report and the
   half-understanding does not. *)

open Sql_lex
open Sql_ast

let ident_of = function Word w -> Some w | Quoted q -> Some q | _ -> None

(* ---- token-list helpers ------------------------------------------------- *)

(* Split at top-level commas, so the `10,2` inside `numeric(10,2)` does not cut
   a column definition in half. *)
let split_commas (ts : tok list) : tok list list =
  let out = ref [] and cur = ref [] and depth = ref 0 in
  List.iter
    (fun t ->
      match t.tk with
      | Punct (('(' | '[') as c) ->
          incr depth;
          cur := { t with tk = Punct c } :: !cur
      | Punct ((')' | ']') as c) ->
          decr depth;
          cur := { t with tk = Punct c } :: !cur
      | Punct ',' when !depth = 0 ->
          out := List.rev !cur :: !out;
          cur := []
      | _ -> cur := t :: !cur)
    ts;
  if !cur <> [] then out := List.rev !cur :: !out;
  List.rev !out

(* The balanced group opened by the leading `(`, and what follows it. *)
let balanced (ts : tok list) : (tok list * tok list) option =
  match ts with
  | { tk = Punct '('; _ } :: rest ->
      let rec go depth acc = function
        | [] -> None
        | ({ tk = Punct '('; _ } as t) :: tl -> go (depth + 1) (t :: acc) tl
        | { tk = Punct ')'; _ } :: tl when depth = 0 -> Some (List.rev acc, tl)
        | ({ tk = Punct ')'; _ } as t) :: tl -> go (depth - 1) (t :: acc) tl
        | t :: tl -> go depth (t :: acc) tl
      in
      go 0 [] rest
  | _ -> None

(* A possibly schema-qualified name: `public.orders` is the table `orders`. The
   qualifier is dropped rather than folded in, because a type named
   `public-orders` would export to a table of that name in the default schema —
   a different database. *)
let rec qualified_name (ts : tok list) : (string * tok list) option =
  match ts with
  | t :: rest -> (
      match ident_of t.tk with
      | None -> None
      | Some n -> (
          match rest with
          | { tk = Punct '.'; _ } :: more -> (
              match qualified_name more with
              | Some r -> Some r
              | None -> Some (n, rest))
          | _ -> Some (n, rest)))
  | [] -> None

let show_tok = function
  | Word w -> w
  | Quoted q -> q
  | Str _ -> "'…'"
  | Num x -> x
  | Punct c -> String.make 1 c
  | Op o -> o

(* The first few words of a statement, for a decline's `what`. *)
let head_words (n : int) (ts : tok list) : string =
  let rec take k = function
    | [] -> []
    | _ when k = 0 -> []
    | t :: tl -> show_tok t.tk :: take (k - 1) tl
  in
  String.concat " " (take n ts)

(* PostgreSQL writes casts throughout the CHECK expressions it dumps —
   `((status)::text = ANY (ARRAY['draft'::character varying]))` — and every one
   is noise to a language with no types to cast between. Stripping them first
   is what lets one grammar read both a hand-written constraint and pg_dump's
   rendering of the same constraint. *)
let strip_casts (ts : tok list) : tok list =
  let rec go acc = function
    | { tk = Punct ':'; _ } :: { tk = Punct ':'; _ } :: rest ->
        let rec ty = function
          | { tk = Word _; _ } :: tl -> ty tl
          | { tk = Punct '('; _ } :: _ as tl -> (
              match balanced tl with Some (_, r) -> ty r | None -> tl)
          | { tk = Punct '['; _ } :: { tk = Punct ']'; _ } :: tl -> ty tl
          | tl -> tl
        in
        go acc (ty rest)
    | t :: rest -> go (t :: acc) rest
    | [] -> List.rev acc
  in
  go [] ts

(* pg_dump also parenthesises bare operands — `((status)::text = …)` — and a
   grammar that reads `(` as "a nested expression begins" cannot tell that
   group from a real one. Unwrapping the groups whose whole contents is a
   column reference is exact rather than heuristic: a lone name is never an
   expression this fragment could have meant. *)
let rec unwrap_operands (ts : tok list) : tok list =
  match ts with
  | { tk = Punct '('; _ } :: _ -> (
      match balanced ts with
      | Some (inner, rest) -> (
          match qualified_name inner with
          | Some (_, []) -> inner @ unwrap_operands rest
          | _ ->
              let lp = List.hd ts in
              (lp :: unwrap_operands inner)
              @ ({ lp with tk = Punct ')' } :: unwrap_operands rest))
      | None -> ts)
  | t :: rest -> t :: unwrap_operands rest
  | [] -> []

let strings (ts : tok list) : string list =
  List.filter_map (fun t -> match t.tk with Str s -> Some s | _ -> None) ts

(* ---- CHECK expressions -------------------------------------------------- *)

(* The expressible fragment: boolean structure over null-ness and membership.
   Anything else — arithmetic, ordering, a function call, a subquery — returns
   [None] and becomes a decline. That boundary is not this parser's limitation
   but the target language's: pol has no numbers, so `price > 0` has no
   reading, and inventing one would be the first lie the tool told. *)
let rec p_or (ts : tok list) : check option * tok list =
  match p_and ts with
  | None, r -> (None, r)
  | Some first, r ->
      let rec more acc ts =
        match ts with
        | { tk = Word "or"; _ } :: rest -> (
            match p_and rest with
            | None, r -> (None, r)
            | Some x, r -> more (x :: acc) r)
        | _ ->
            ( Some
                (match acc with [ one ] -> one | many -> C_or (List.rev many)),
              ts )
      in
      more [ first ] r

and p_and (ts : tok list) : check option * tok list =
  match p_factor ts with
  | None, r -> (None, r)
  | Some first, r ->
      let rec more acc ts =
        match ts with
        | { tk = Word "and"; _ } :: rest -> (
            match p_factor rest with
            | None, r -> (None, r)
            | Some x, r -> more (x :: acc) r)
        | _ ->
            ( Some
                (match acc with
                | [ one ] -> one
                | many -> C_and (List.rev many)),
              ts )
      in
      more [ first ] r

and p_factor (ts : tok list) : check option * tok list =
  match ts with
  | { tk = Word "not"; _ } :: rest -> (
      match p_factor rest with
      | None, r -> (None, r)
      | Some x, r -> (Some (C_not x), r))
  | { tk = Punct '('; _ } :: _ -> (
      match balanced ts with
      | None -> (None, [])
      | Some (inner, rest) -> (
          match p_or inner with
          | Some x, [] -> (Some x, rest)
          | _ -> (None, rest)))
  | _ -> p_atom ts

and p_atom (ts : tok list) : check option * tok list =
  match qualified_name ts with
  | None -> (None, ts)
  | Some (col, rest) -> (
      let c = Sql_names.ident_to_pol col in
      match rest with
      | { tk = Word "is"; _ } :: { tk = Word "null"; _ } :: r ->
          (Some (C_null c), r)
      | { tk = Word "is"; _ }
        :: { tk = Word "not"; _ }
        :: { tk = Word "null"; _ }
        :: r ->
          (Some (C_notnull c), r)
      | { tk = Word "in"; _ } :: ({ tk = Punct '('; _ } :: _ as r) -> (
          match balanced r with
          | Some (inner, rest') -> (Some (C_in (c, strings inner)), rest')
          | None -> (None, r))
      (* `= ANY (ARRAY[…])` is pg_dump's rendering of `IN (…)`; the members are
         the string literals in the group, whatever shape it takes. *)
      | { tk = Op "="; _ }
        :: { tk = Word "any"; _ }
        :: ({ tk = Punct '('; _ } :: _ as r) -> (
          match balanced r with
          | Some (inner, rest') -> (Some (C_in (c, strings inner)), rest')
          | None -> (None, r))
      | { tk = Op "="; _ } :: { tk = Str v; _ } :: r -> (Some (C_is (c, v)), r)
      (* a boolean column compares against a keyword, not a literal *)
      | { tk = Op "="; _ } :: { tk = Word (("true" | "false") as v); _ } :: r ->
          (Some (C_is (c, v)), r)
      | { tk = Word "is"; _ } :: { tk = Word (("true" | "false") as v); _ } :: r
        ->
          (Some (C_is (c, v)), r)
      | { tk = Word "is"; _ }
        :: { tk = Word "not"; _ }
        :: { tk = Word (("true" | "false") as v); _ }
        :: r ->
          (Some (C_not (C_is (c, v))), r)
      | { tk = Op "<>"; _ } :: { tk = Str v; _ } :: r ->
          (Some (C_not (C_is (c, v))), r)
      | _ -> (None, rest))

let parse_check (ts : tok list) : check option =
  match p_or (unwrap_operands (strip_casts ts)) with
  | Some c, [] -> Some c
  | _ -> None

(* ---- column definitions ------------------------------------------------- *)

(* Where a type name stops and its modifiers begin. `timestamp with time zone`
   is three words of type; `timestamp not null` is one. *)
let modifier_words =
  [
    "not";
    "null";
    "default";
    "primary";
    "references";
    "unique";
    "check";
    "generated";
    "collate";
    "constraint";
    "always";
    "identity";
  ]

let rec type_words acc = function
  | { tk = Word w; _ } :: rest when not (List.mem w modifier_words) ->
      type_words (w :: acc) rest
  | rest -> (List.rev acc, rest)

(* Skip an expression (a DEFAULT, an identity clause) to the next modifier. *)
let rec skip_expr = function
  | { tk = Word w; _ } :: _ as tl when List.mem w modifier_words -> tl
  | { tk = Punct '('; _ } :: _ as tl -> (
      match balanced tl with Some (_, rr) -> skip_expr rr | None -> [])
  | _ :: tl -> skip_expr tl
  | [] -> []

type coldef = {
  col : column option;
  ck : (string * check) list;
  cdecl : decline list;
}

let parse_column ~(tname : string) ~(pragmas : (int * string) list)
    (ts : tok list) : coldef =
  let line = match ts with t :: _ -> t.line | [] -> 0 in
  let dec why = { dline = line; what = head_words 4 ts; why } in
  let fail why = { col = None; ck = []; cdecl = [ dec why ] } in
  match qualified_name ts with
  | None -> fail "unreadable column definition"
  | Some (raw_name, rest) ->
      if not (Sql_names.translatable raw_name) then
        fail "column name is not a pol atom"
      else
        let base, rest = type_words [] rest in
        let args, rest =
          match rest with
          | { tk = Punct '('; _ } :: _ -> (
              match balanced rest with
              | Some (inner, r) ->
                  ( List.filter_map
                      (fun t ->
                        match t.tk with
                        | Num x -> Some x
                        | Word w -> Some w
                        | _ -> None)
                      inner,
                    r )
              | None -> ([], rest))
          | _ -> ([], rest)
        in
        let is_array, rest =
          match rest with
          | { tk = Punct '['; _ } :: { tk = Punct ']'; _ } :: r -> (true, r)
          | _ -> (false, rest)
        in
        if base = [] then fail "column has no type"
        else if is_array then
          fail "array column — pol has no unbounded collections"
        else begin
          let decls = ref []
          and checks = ref []
          and nullable = ref true
          and refs = ref None in
          let rec mods = function
            | [] -> ()
            | { tk = Word "not"; _ } :: { tk = Word "null"; _ } :: r ->
                nullable := false;
                mods r
            | { tk = Word "null"; _ } :: r -> mods r
            | { tk = Word "primary"; _ } :: { tk = Word "key"; _ } :: r ->
                nullable := false;
                mods r
            | { tk = Word "references"; _ } :: r -> (
                match qualified_name r with
                | Some (t, r') ->
                    refs := Some (Sql_names.ident_to_pol t);
                    let r' =
                      match r' with
                      | { tk = Punct '('; _ } :: _ -> (
                          match balanced r' with
                          | Some (_, rr) -> rr
                          | None -> r')
                      | _ -> r'
                    in
                    mods r'
                | None -> ())
            | { tk = Word "unique"; _ } :: r ->
                decls :=
                  dec
                    "UNIQUE — a pol law ranges over one entity, so \"no two \
                     rows agree\" has no spelling"
                  :: !decls;
                mods r
            | { tk = Word "check"; _ } :: ({ tk = Punct '('; _ } :: _ as r) -> (
                match balanced r with
                | Some (inner, rr) ->
                    (match parse_check inner with
                    | Some c -> checks := c :: !checks
                    | None ->
                        decls :=
                          dec
                            "CHECK outside the expressible fragment \
                             (null-ness, membership, boolean structure)"
                          :: !decls);
                    mods rr
                | None -> ())
            | { tk = Word "default"; _ } :: r ->
                decls := dec "DEFAULT" :: !decls;
                mods (skip_expr r)
            | { tk = Word "generated"; _ } :: r -> mods (skip_expr r)
            | { tk = Word "constraint"; _ } :: _ :: r -> mods r
            | _ :: r -> mods r
          in
          mods rest;
          let cname = Sql_names.ident_to_pol raw_name in
          (* A reference is wiring by default: a `fixed` arrow is not part of a
             state at all, so the assuming import builds the smaller model, and
             promoting one to mutable is a modelling decision made with the
             move that motivates it. A `-- pol:` pragma overrides either way. *)
          let fixed =
            match List.assoc_opt line pragmas with
            | Some "fixed" -> true
            | Some "mutable" -> false
            | _ -> !refs <> None
          in
          let named =
            List.mapi
              (fun i c ->
                ( (tname ^ "-" ^ cname
                  ^ if i = 0 then "" else "-" ^ string_of_int i),
                  c ))
              (List.rev !checks)
          in
          {
            col =
              Some
                {
                  cname;
                  sql_name = raw_name;
                  domain = Sql_names.domain_of_sql (String.concat " " base) args;
                  nullable = !nullable;
                  fixed;
                  refs = !refs;
                  comment = None;
                  cline = line;
                };
            ck = named;
            cdecl = List.rev !decls;
          }
        end

(* ---- table constraints -------------------------------------------------- *)

type tcon =
  | Tc_pk of string list
  | Tc_fk of string * string  (** column, referenced table *)
  | Tc_check of string * check
  | Tc_declined of decline

let constraint_leader =
  [ "constraint"; "primary"; "foreign"; "unique"; "check"; "exclude"; "like" ]

let parse_constraint ~(tname : string) (ts : tok list) : tcon =
  let line = match ts with t :: _ -> t.line | [] -> 0 in
  let dec why = Tc_declined { dline = line; what = head_words 5 ts; why } in
  let name, body =
    match ts with
    | { tk = Word "constraint"; _ } :: n :: rest -> (
        match ident_of n.tk with
        | Some n -> (Some (Sql_names.ident_to_pol n), rest)
        | None -> (None, rest))
    | _ -> (None, ts)
  in
  let cols group =
    List.filter_map
      (fun t ->
        match ident_of t.tk with
        | Some n -> Some (Sql_names.ident_to_pol n)
        | None -> None)
      group
  in
  match body with
  | { tk = Word "primary"; _ } :: { tk = Word "key"; _ } :: rest -> (
      match balanced rest with
      | Some (inner, _) -> Tc_pk (cols inner)
      | None -> dec "unreadable PRIMARY KEY")
  | { tk = Word "foreign"; _ } :: { tk = Word "key"; _ } :: rest -> (
      match balanced rest with
      | Some (inner, after) -> (
          match (cols inner, after) with
          | [ c ], { tk = Word "references"; _ } :: r -> (
              match qualified_name r with
              | Some (t, _) -> Tc_fk (c, Sql_names.ident_to_pol t)
              | None -> dec "unreadable FOREIGN KEY target")
          | _ :: _ :: _, _ ->
              dec
                "composite FOREIGN KEY — an arrow has one source, so a \
                 multi-column reference has no single arrow to be"
          | _ -> dec "unreadable FOREIGN KEY")
      | None -> dec "unreadable FOREIGN KEY")
  | { tk = Word "unique"; _ } :: _ ->
      dec
        "UNIQUE — a pol law ranges over one entity, so \"no two rows agree\" \
         has no spelling"
  | { tk = Word "check"; _ } :: ({ tk = Punct '('; _ } :: _ as rest) -> (
      match balanced rest with
      | Some (inner, _) -> (
          match parse_check inner with
          | Some c ->
              let n =
                match name with
                | Some n -> n
                | None -> tname ^ "-check-" ^ string_of_int line
              in
              Tc_check (n, c)
          | None ->
              dec
                "CHECK outside the expressible fragment (null-ness, \
                 membership, boolean structure)")
      | None -> dec "unreadable CHECK")
  | _ -> dec "table constraint"

(* ---- statements --------------------------------------------------------- *)

let is_constraint_item (ts : tok list) =
  match ts with
  | { tk = Word w; _ } :: _ -> List.mem w constraint_leader
  | _ -> false

let parse_create_table ~(pragmas : (int * string) list) (st : stmt)
    (rest : tok list) (db : db) : db =
  let rest =
    match rest with
    | { tk = Word "if"; _ }
      :: { tk = Word "not"; _ }
      :: { tk = Word "exists"; _ }
      :: r ->
        r
    | r -> r
  in
  match qualified_name rest with
  | None ->
      {
        db with
        declines =
          {
            dline = st.sline;
            what = head_words 4 st.toks;
            why = "unreadable CREATE TABLE";
          }
          :: db.declines;
      }
  | Some (raw, after) -> (
      match balanced after with
      | None ->
          {
            db with
            declines =
              {
                dline = st.sline;
                what = "create table " ^ raw;
                why = "CREATE TABLE without a column list (PARTITION OF, AS …)";
              }
              :: db.declines;
          }
      | Some (inner, _) ->
          let tname = Sql_names.ident_to_pol raw in
          let items = split_commas inner in
          let cols = ref []
          and checks = ref []
          and pk = ref []
          and fks = ref []
          and decls = ref [] in
          List.iter
            (fun item ->
              if is_constraint_item item then
                match parse_constraint ~tname item with
                | Tc_pk cs -> pk := cs
                | Tc_fk (c, t) -> fks := (c, t) :: !fks
                | Tc_check (n, c) -> checks := (n, c) :: !checks
                | Tc_declined d -> decls := d :: !decls
              else
                let r = parse_column ~tname ~pragmas item in
                (match r.col with
                | Some c ->
                    cols := c :: !cols;
                    (* a column-level PRIMARY KEY *)
                    if
                      List.exists
                        (fun t ->
                          match t.tk with Word "primary" -> true | _ -> false)
                        item
                    then pk := [ c.cname ]
                | None -> ());
                checks := r.ck @ !checks;
                decls := List.rev_append r.cdecl !decls)
            items;
          (* attach table-level foreign keys to their columns *)
          let cols =
            List.rev_map
              (fun c ->
                match List.assoc_opt c.cname !fks with
                | None -> c
                | Some target ->
                    let fixed =
                      match List.assoc_opt c.cline pragmas with
                      | Some "fixed" -> true
                      | Some "mutable" -> false
                      | _ -> true
                    in
                    { c with refs = Some target; fixed })
              !cols
          in
          {
            db with
            tables =
              {
                tname;
                sql_tname = raw;
                columns = cols;
                pk = !pk;
                checks = List.rev !checks;
                comment = None;
                tline = st.sline;
              }
              :: db.tables;
            declines = List.rev_append !decls db.declines;
          })

let parse_create_type (st : stmt) (rest : tok list) (db : db) : db =
  match qualified_name rest with
  | Some (raw, { tk = Word "as"; _ } :: { tk = Word "enum"; _ } :: after) -> (
      match balanced after with
      | Some (inner, _) ->
          {
            db with
            enums =
              { ename = Sql_names.ident_to_pol raw; emembers = strings inner }
              :: db.enums;
          }
      | None ->
          {
            db with
            declines =
              {
                dline = st.sline;
                what = "create type " ^ raw;
                why = "unreadable ENUM";
              }
              :: db.declines;
          })
  | _ ->
      {
        db with
        declines =
          {
            dline = st.sline;
            what = head_words 4 st.toks;
            why = "CREATE TYPE that is not an ENUM";
          }
          :: db.declines;
      }

(* pg_dump emits every foreign key as its own ALTER TABLE, so this path is not
   an optional convenience — without it a dumped schema imports with no arrows
   at all, which is to say as no olog. *)
let parse_alter_table ~(pragmas : (int * string) list) (st : stmt)
    (rest : tok list) (db : db) : db =
  let rest = match rest with { tk = Word "only"; _ } :: r -> r | r -> r in
  let decline why =
    {
      db with
      declines =
        { dline = st.sline; what = head_words 5 st.toks; why } :: db.declines;
    }
  in
  match qualified_name rest with
  | Some (raw, { tk = Word "add"; _ } :: body) -> (
      let tname = Sql_names.ident_to_pol raw in
      match List.find_opt (fun t -> t.tname = tname) db.tables with
      | None -> decline "ALTER TABLE on a table that was not read"
      | Some t -> (
          match parse_constraint ~tname body with
          | Tc_pk cs ->
              let tables =
                List.map
                  (fun x -> if x.tname = tname then { x with pk = cs } else x)
                  db.tables
              in
              { db with tables }
          | Tc_fk (c, target) ->
              let cols =
                List.map
                  (fun col ->
                    if col.cname <> c then col
                    else
                      let fixed =
                        match List.assoc_opt col.cline pragmas with
                        | Some "fixed" -> true
                        | Some "mutable" -> false
                        | _ -> true
                      in
                      { col with refs = Some target; fixed })
                  t.columns
              in
              let tables =
                List.map
                  (fun x ->
                    if x.tname = tname then { x with columns = cols } else x)
                  db.tables
              in
              { db with tables }
          | Tc_check (n, c) ->
              let tables =
                List.map
                  (fun x ->
                    if x.tname = tname then
                      { x with checks = x.checks @ [ (n, c) ] }
                    else x)
                  db.tables
              in
              { db with tables }
          | Tc_declined d -> { db with declines = d :: db.declines }))
  | _ -> decline "ALTER TABLE that adds no constraint"

let parse_comment (st : stmt) (rest : tok list) (db : db) : db =
  let text ts =
    match List.rev ts with { tk = Str s; _ } :: _ -> Some s | _ -> None
  in
  match rest with
  | { tk = Word "table"; _ } :: r -> (
      match (qualified_name r, text r) with
      | Some (raw, _), Some s ->
          let n = Sql_names.ident_to_pol raw in
          {
            db with
            tables =
              List.map
                (fun t ->
                  if t.tname = n then { t with comment = Some s } else t)
                db.tables;
          }
      | _ -> db)
  | { tk = Word "column"; _ } :: r -> (
      (* the name here is table.column, so the qualifier is the table *)
      match r with
      | tt :: { tk = Punct '.'; _ } :: cc :: _ -> (
          match (ident_of tt.tk, ident_of cc.tk, text r) with
          | Some t, Some c, Some s ->
              let tn = Sql_names.ident_to_pol t
              and cn = Sql_names.ident_to_pol c in
              {
                db with
                tables =
                  List.map
                    (fun tb ->
                      if tb.tname <> tn then tb
                      else
                        {
                          tb with
                          columns =
                            List.map
                              (fun col ->
                                if col.cname = cn then
                                  { col with comment = Some s }
                                else col)
                              tb.columns;
                        })
                    db.tables;
              }
          | _ -> db)
      | _ -> db)
  | _ ->
      {
        db with
        declines =
          {
            dline = st.sline;
            what = head_words 3 st.toks;
            why = "COMMENT ON something other than a table or column";
          }
          :: db.declines;
      }

let literal (t : tok) : string option option =
  match t.tk with
  | Word "null" -> Some None
  | Word w -> Some (Some w)
  | Quoted q -> Some (Some q)
  | Str s -> Some (Some s)
  | Num n -> Some (Some n)
  | _ -> None

let parse_insert (st : stmt) (rest : tok list) (db : db) : db =
  let rest = match rest with { tk = Word "into"; _ } :: r -> r | r -> r in
  match qualified_name rest with
  | None -> db
  | Some (raw, after) ->
      let tname = Sql_names.ident_to_pol raw in
      let named, after =
        match after with
        | { tk = Punct '('; _ } :: _ -> (
            match balanced after with
            | Some (inner, r) ->
                ( List.filter_map
                    (fun t ->
                      match ident_of t.tk with
                      | Some n -> Some (Sql_names.ident_to_pol n)
                      | None -> None)
                    inner,
                  r )
            | None -> ([], after))
        | _ -> ([], after)
      in
      let after =
        match after with { tk = Word "values"; _ } :: r -> r | r -> r
      in
      (* each parenthesised group is one row *)
      let rec groups acc ts =
        match ts with
        | { tk = Punct '('; _ } :: _ -> (
            match balanced ts with
            | Some (inner, r) ->
                let line = match ts with t :: _ -> t.line | [] -> st.sline in
                let vals =
                  List.filter_map literal (List.concat (split_commas inner))
                in
                groups ((line, vals) :: acc) r
            | None -> List.rev acc)
        | { tk = Punct ','; _ } :: r -> groups acc r
        | _ -> List.rev acc
      in
      let rows =
        List.map
          (fun (line, vals) ->
            let rvals =
              if named = [] then List.map (fun v -> ("", v)) vals
              else
                let rec zip cs vs =
                  match (cs, vs) with
                  | c :: cs', v :: vs' -> (c, v) :: zip cs' vs'
                  | _ -> []
                in
                zip named vals
            in
            { rtable = tname; rvals; rline = line })
          (groups [] after)
      in
      { db with rows = db.rows @ rows }

(* ---- the resolve pass --------------------------------------------------- *)

(* Two things can only be decided once every statement has been read: whether a
   column's type names an enum declared elsewhere in the file, and whether a
   surviving CHECK compares against members that exist. Both are deferred here
   rather than guessed at the point of parse. *)

let is_textual = function
  | Sql_names.Opaque n -> (
      match String.split_on_char '-' n with
      | "text" :: _ | "varchar" :: _ | "char" :: _ -> true
      | _ -> false)
  | _ -> false

(* A column-level `CHECK (c IN ('a','b'))` over a textual column is not a law
   about the column — it IS the column's type, spelled in the only notation SQL
   has for one. Promoting it is what lets those members cross with their
   identities intact instead of collapsing into one opaque value. *)
let promote_enums (db : db) : db =
  let extra_enums = ref [] and decls = ref [] in
  let tables =
    List.map
      (fun t ->
        let cols = ref t.columns in
        let keep =
          List.filter
            (fun (_, c) ->
              match c with
              | C_in (col, members) -> (
                  match column_named t col with
                  | Some column when is_textual column.domain ->
                      if List.for_all Sql_names.translatable members then begin
                        let ename = t.tname ^ "-" ^ col in
                        extra_enums :=
                          {
                            ename;
                            emembers = List.map Sql_names.ident_to_pol members;
                          }
                          :: !extra_enums;
                        cols :=
                          List.map
                            (fun x ->
                              if x.cname = col then
                                { x with domain = Sql_names.Enum ename }
                              else x)
                            !cols;
                        false
                      end
                      else begin
                        decls :=
                          {
                            dline = column.cline;
                            what = "CHECK " ^ col ^ " IN (…)";
                            why =
                              "an enumerated member is not a pol atom, so the \
                               domain cannot be named";
                          }
                          :: !decls;
                        false
                      end
                  | _ -> true)
              | _ -> true)
            t.checks
        in
        { t with columns = !cols; checks = keep })
      db.tables
  in
  {
    db with
    tables;
    enums = db.enums @ List.rev !extra_enums;
    declines = db.declines @ List.rev !decls;
  }

(* A column whose SQL type names an enum declared in the same file. *)
let resolve_enum_columns (db : db) : db =
  let tables =
    List.map
      (fun t ->
        {
          t with
          columns =
            List.map
              (fun c ->
                match c.domain with
                | Sql_names.Opaque n when enum_named db n <> None ->
                    { c with domain = Sql_names.Enum n }
                | _ -> c)
              t.columns;
        })
      db.tables
  in
  { db with tables }

(* A check that compares an OPAQUE column against a literal cannot be carried:
   the domain has one member, so the comparison is either trivially true or
   names a member that does not exist. Null-ness is different — that is exactly
   what an opaque column still says. *)
let vet_checks (db : db) : db =
  let decls = ref [] in
  let tables =
    List.map
      (fun t ->
        let bad_col c =
          match column_named t c with
          | None -> Some ("no column `" ^ c ^ "`")
          | Some col -> (
              match col.domain with
              | Sql_names.Opaque _ ->
                  Some
                    ("`" ^ c
                   ^ "` lands in an opaque domain, whose single member no \
                      literal names")
              | _ -> None)
        in
        let rec vet = function
          | C_and cs | C_or cs -> List.filter_map vet cs |> first
          | C_not c -> vet c
          | C_null c | C_notnull c -> (
              match column_named t c with
              | None -> Some ("no column `" ^ c ^ "`")
              | Some _ -> None)
          | C_is (c, _) | C_in (c, _) -> bad_col c
        and first = function [] -> None | x :: _ -> Some x in
        let keep =
          List.filter
            (fun (n, c) ->
              match vet c with
              | None -> true
              | Some why ->
                  decls :=
                    {
                      dline = t.tline;
                      what = "CHECK " ^ n;
                      why = "not carried: " ^ why;
                    }
                    :: !decls;
                  false)
            t.checks
        in
        { t with checks = keep })
      db.tables
  in
  { db with tables; declines = db.declines @ List.rev !decls }

(* A composite primary key is a uniqueness constraint over a tuple, which is
   the same unsayable thing UNIQUE is. The junction TABLE still crosses — as an
   ordinary type with one arrow per foreign key — so what is declined is the
   constraint, not the table. *)
let vet_keys (db : db) : db =
  let decls = ref [] in
  List.iter
    (fun t ->
      if List.length t.pk > 1 then
        decls :=
          {
            dline = t.tline;
            what = "PRIMARY KEY (" ^ String.concat ", " t.pk ^ ") on " ^ t.tname;
            why =
              "composite key — uniqueness over a tuple of rows has no pol \
               spelling; the table itself crosses";
          }
          :: !decls)
    db.tables;
  { db with declines = db.declines @ List.rev !decls }

(* Positional INSERTs get their column names, and a row is named by its single
   -column primary key — an entity IS its identity, so a table without one has
   no way to name the things it holds. *)
let resolve_rows (db : db) : db =
  let decls = ref [] in
  let rows =
    List.filter_map
      (fun r ->
        match table_named db r.rtable with
        | None -> None
        | Some t ->
            let rvals =
              if List.exists (fun (c, _) -> c = "") r.rvals then
                let rec zip cs vs =
                  match (cs, vs) with
                  | c :: cs', (_, v) :: vs' -> (c.cname, v) :: zip cs' vs'
                  | _ -> []
                in
                zip t.columns r.rvals
              else r.rvals
            in
            if List.length t.pk <> 1 then begin
              decls :=
                {
                  dline = r.rline;
                  what = "INSERT INTO " ^ t.tname;
                  why =
                    "no single-column primary key, so the row has no name to \
                     be an entity under";
                }
                :: !decls;
              None
            end
            else Some { r with rvals })
      db.rows
  in
  { db with rows; declines = db.declines @ List.rev !decls }

(* ---- the entry point ---------------------------------------------------- *)

let parse ?(with_data = false) (src : string) : db =
  let { stmts; pragmas } = lex src in
  let db =
    List.fold_left
      (fun db (st : stmt) ->
        match st.toks with
        | { tk = Word "create"; _ } :: { tk = Word "table"; _ } :: rest ->
            parse_create_table ~pragmas st rest db
        | { tk = Word "create"; _ } :: { tk = Word "type"; _ } :: rest ->
            parse_create_type st rest db
        | { tk = Word "alter"; _ } :: { tk = Word "table"; _ } :: rest ->
            parse_alter_table ~pragmas st rest db
        | { tk = Word "comment"; _ } :: { tk = Word "on"; _ } :: rest ->
            parse_comment st rest db
        | { tk = Word "insert"; _ } :: rest ->
            if with_data then parse_insert st rest db
            else
              {
                db with
                declines =
                  {
                    dline = st.sline;
                    what = head_words 3 st.toks;
                    why = "INSERT — pass --with-data to read seed rows";
                  }
                  :: db.declines;
              }
        | [] -> db
        (* an index is storage, except a UNIQUE one, which is a constraint —
           and the same unsayable constraint UNIQUE always is *)
        | { tk = Word "create"; _ } :: { tk = Word "unique"; _ } :: _ ->
            {
              db with
              declines =
                {
                  dline = st.sline;
                  what = head_words 4 st.toks;
                  why =
                    "UNIQUE — a pol law ranges over one entity, so \"no two \
                     rows agree\" has no spelling";
                }
                :: db.declines;
            }
        | toks ->
            {
              db with
              declines =
                {
                  dline = st.sline;
                  what = head_words 3 toks;
                  why = "statement carries no schema meaning pol can hold";
                }
                :: db.declines;
            })
      empty stmts
  in
  let db = { db with tables = List.rev db.tables; enums = List.rev db.enums } in
  let db = db |> resolve_enum_columns |> promote_enums |> vet_checks in
  let db = vet_keys db in
  let db = if with_data then resolve_rows db else db in
  {
    db with
    declines = List.sort (fun a b -> compare a.dline b.dline) db.declines;
  }
