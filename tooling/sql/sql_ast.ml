(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* What `writ sql` understands of a relational schema: as much as an olog can
   mean. Anything else in the DDL is declined, recorded with its line and
   reason, never dropped silently. *)

(* A comparison of a column against an integer constant. [cut_regions] turns
   it into membership of the column's regions ([Sql_regions]); a comparison
   between two columns is declined. *)
type cmp = Lt | Le | Gt | Ge | Eq | Ne

type check =
  | C_cmp of string * cmp * int  (** col OP constant, before the cut *)
  | C_and of check list
  | C_or of check list
  | C_not of check
  | C_null of string  (** col IS NULL *)
  | C_notnull of string  (** col IS NOT NULL *)
  | C_is of string * string  (** col = 'member' *)
  | C_in of string * string list  (** col IN ('a','b') *)

type column = {
  cname : string;  (** writ spelling *)
  sql_name : string;
  domain : Sql_names.domain;
  nullable : bool;
  fixed : bool;
      (** wiring rather than state: [true] by default for a foreign key, [false]
          otherwise; a `-- writ:` pragma overrides. *)
  refs : string option;  (** the referenced table, writ spelling *)
  comment : string option;
  cline : int;
}

type table = {
  tname : string;
  sql_tname : string;
  columns : column list;
  pk : string list;
  checks : (string * check) list;
  check_lines : (string * int) list;
      (** each CHECK's DDL line, echoed as the law's origin *)
  comment : string option;
  tline : int;
}

type enum_def = { ename : string; emembers : string list }

(* One INSERTed row (--with-data only): seed data for one starting
   configuration. *)
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
  regions : (string * int list) list;
      (** a region domain's name -> the sorted constants that cut it *)
}

let empty = { tables = []; enums = []; rows = []; declines = []; regions = [] }

let column_named (t : table) (c : string) : column option =
  List.find_opt (fun col -> col.cname = c) t.columns

let table_named (d : db) (n : string) : table option =
  List.find_opt (fun t -> t.tname = n) d.tables

let enum_named (d : db) (n : string) : enum_def option =
  List.find_opt (fun e -> e.ename = n) d.enums
