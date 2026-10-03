(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ sql]: a `.sql` file is imported as a model, a `.writ` file is
   exported as DDL.

   Whatever the translation drops is always reported on stderr, grouped by
   reason with a count, so an imported model never silently differs from its
   schema. A decline exits 1 only under [--strict], for CI. *)

open Writ_data
open Writ_sql
open Cli_io

(* One line per reason, with a count and the first line number. *)
let report_declines (ds : Sql_ast.decline list) =
  let rec group acc = function
    | [] -> List.rev acc
    | (d : Sql_ast.decline) :: rest ->
        let same, other =
          List.partition (fun (x : Sql_ast.decline) -> x.why = d.why) rest
        in
        group ((d, 1 + List.length same) :: acc) other
  in
  match ds with
  | [] -> ()
  | _ ->
      prerr_endline "declined:";
      List.iter
        (fun ((d : Sql_ast.decline), n) ->
          prerr_endline
            ("  " ^ string_of_int d.dline ^ ": " ^ d.why
            ^ (if n > 1 then "  (" ^ string_of_int n ^ " occurrences)" else "")
            ^ "\n      first at: " ^ d.what))
        (group [] ds)

let import (file : string) ~(with_data : bool) ~(strict : bool) =
  let src =
    match read_file file with Ok s -> s | Error e -> die 2 (file ^ ": " ^ e)
  in
  let db = Sql_parse.parse ~with_data src in
  let name = Filename.remove_extension (Filename.basename file) in
  let name = Sql_names.ident_to_pol name in
  let text, clashes =
    Emit_writ.file ~name ~source:(Filename.basename file) db
  in
  let ds = db.declines @ clashes in
  (* Refuse before writing, so a redirected failure leaves no model behind. *)
  if db.tables = [] then begin
    report_declines ds;
    die 2 (file ^ ": no CREATE TABLE that writ could read")
  end;
  print_string text;
  flush stdout;
  report_declines ds;
  exit (if strict && ds <> [] then 1 else 0)

let export (file : string) ~(strict : bool) =
  let resolve = make_resolve file in
  let m = load_model resolve file in
  let text, notes = Emit_ddl.ddl m.Model.schema in
  print_string text;
  flush stdout;
  (match notes with
  | [] -> ()
  | _ ->
      prerr_endline "declined:";
      List.iter
        (fun (n : Emit_ddl.note) ->
          prerr_endline ("  " ^ n.what ^ ": " ^ n.why))
        notes);
  exit (if strict && notes <> [] then 1 else 0)

let run (file : string) ~(with_data : bool) ~(strict : bool) =
  match String.lowercase_ascii (Filename.extension file) with
  | ".sql" -> import file ~with_data ~strict
  | ".writ" -> export file ~strict
  | _ ->
      die 2
        "writ sql: the direction is the extension — give it a .sql file to \
         read a model, or a .writ file to write DDL"
