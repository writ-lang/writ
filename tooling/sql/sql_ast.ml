(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* What `pol sql` understands of a relational schema — which is deliberately
   less than SQL, and exactly as much as an olog can mean.

   Everything a DDL says that is not here is DECLINED: recorded with its line
   and its reason, never dropped in silence. A skipped construct that nobody is
   told about turns "pol proved this schema safe" into a claim about a schema
   nobody has. *)

type check =
  | C_and of check list
  | C_or of check list
  | C_not of check
  | C_null of string  (** col IS NULL *)
  | C_notnull of string  (** col IS NOT NULL *)
  | C_is of string * string  (** col = 'member' *)
  | C_in of string * string list  (** col IN ('a','b') *)

type column = {
  cname : string;  (** pol spelling *)
  sql_name : string;
  domain : Sql_names.domain;
  nullable : bool;
  fixed : bool;
      (** wiring rather than state. A foreign key defaults to [true] — a
          reference is the shape of the world, and a `fixed` arrow costs the
          state space nothing — and anything else to [false]. A `-- pol:` pragma
          overrides, which is how the export records an arrow whose mutability
          the DDL alone could not have said. *)
  refs : string option;  (** the referenced table, pol spelling *)
  comment : string option;
  cline : int;
}

type table = {
  tname : string;
  sql_tname : string;
  columns : column list;
  pk : string list;
  checks : (string * check) list;
  comment : string option;
  tline : int;
}

type enum_def = { ename : string; emembers : string list }

(* One INSERTed row. Read only under --with-data, and for a reason worth
   stating: a pol instance is ONE starting configuration and the state space is
   a product over it, so importing a table's ten thousand rows builds a model
   that cannot be enumerated and was never a question anyone asked. Seed data
   for a scenario is a different thing, and small. *)
type row = {
  rtable : string;
  rvals : (string * string option) list;  (** column -> literal, None = NULL *)
  rline : int;
}

type decline = { dline : int; what : string; why : string }

type db = {
  tables : table list;
  enums : enum_def list;
  rows : row list;
  declines : decline list;
}

let empty = { tables = []; enums = []; rows = []; declines = [] }

let column_named (t : table) (c : string) : column option =
  List.find_opt (fun col -> col.cname = c) t.columns

let table_named (d : db) (n : string) : table option =
  List.find_opt (fun t -> t.tname = n) d.tables

let enum_named (d : db) (n : string) : enum_def option =
  List.find_opt (fun e -> e.ename = n) d.enums
