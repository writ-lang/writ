(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Cmd_sql] — the [pol sql] verb, beside its sibling verbs.

   ONE verb, both directions, dispatched on the extension, because there is one
   mapping and reading it backwards is not a second feature. A `.sql` argument
   is read into a model; a `.pol` argument is read out as DDL.

   What the DDL says and the model cannot hold goes to STDERR, aggregated by
   reason, always — a schema imported in silence would let "pol proved this
   safe" be a claim about a schema nobody has. Aggregation is not tidying: a
   real dump has a DEFAULT on half its columns, and forty identical lines would
   bury the one decline that mattered. The count is kept, so nothing is hidden;
   only repeated.

   Exit status follows the standard interface: 0 answered, 2 unreadable. A
   decline is NOT a finding by default — every real schema has some — so it
   costs 1 only under --strict, which is the shape a CI check wants: fail when
   the DDL grows a construct the model would have carried silently. *)

open Pol_data
open Pol_sql
open Cli_io

(* Declines with one reason are one line, with a count and the first line
   number so there is something to go and look at. *)
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
  let text, clashes = Emit_pol.file ~name ~source:(Filename.basename file) db in
  let ds = db.declines @ clashes in
  (* refuse BEFORE writing: a redirected run that emitted a model and then
     exited 2 would leave a file behind that reads like an answer *)
  if db.tables = [] then begin
    report_declines ds;
    die 2 (file ^ ": no CREATE TABLE that pol could read")
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
  | ".pol" -> export file ~strict
  | _ ->
      die 2
        "pol sql: the direction is the extension — give it a .sql file to read \
         a model, or a .pol file to write DDL"
