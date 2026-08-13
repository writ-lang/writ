(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Cmd_mgtt] — the [writ mgtt] verb, beside its sibling verbs.

   ONE direction, which is where it parts from [Cmd_sql]. A relational schema
   and an olog are two spellings of one object, so `writ sql` reads either way.
   An mgtt model is a description of a system; writing one BACK from a writ
   model would be synthesis rather than a reading, and a different feature. The
   door is left open; the verb is not.

   The input is JSON rather than YAML, and that is the seam's whole design.
   writ is OCaml-stdlib-only, so a YAML parser would be a serious thing to
   hand-write and keep correct; mgtt already parses its own model and can hand
   over the RESOLVED one — provider types merged, overrides applied — which is
   both easier to read and the only form that does not require this side to
   understand mgtt's provider registry, install layout or credentials.

   What the export says and the model cannot hold goes to STDERR, always, and
   mgtt's own declines are forwarded rather than dropped: a model imported in
   silence would let "writ found nothing" be a claim about an architecture
   nobody has.

   Exit status follows the standard interface: 0 answered, 2 unreadable. A
   decline is NOT a finding by default — a large model usually has some — so it
   costs 1 only under --strict, the shape a CI check wants. *)

open Writ_mgtt
open Cli_io

(* Declines sharing a reason are one line, with a count and the first subject,
   so that forty components resolving to the generic fallback do not bury the
   one decline that mattered. The count is kept: nothing is hidden, only
   repeated. *)
let report_declines (ds : Mgtt_ast.decline list) =
  let rec group acc = function
    | [] -> List.rev acc
    | (d : Mgtt_ast.decline) :: rest ->
        let same, other =
          List.partition (fun (x : Mgtt_ast.decline) -> x.why = d.why) rest
        in
        group ((d, 1 + List.length same) :: acc) other
  in
  match ds with
  | [] -> ()
  | _ ->
      prerr_endline "declined:";
      List.iter
        (fun ((d : Mgtt_ast.decline), n) ->
          prerr_endline
            ("  " ^ d.why
            ^ (if n > 1 then "  (" ^ string_of_int n ^ " occurrences)" else "")
            ^ "\n      first at: " ^ d.what))
        (group [] ds)

let run (file : string) ~(strict : bool) =
  let src =
    match read_file file with Ok s -> s | Error e -> die 2 (file ^ ": " ^ e)
  in
  let j =
    match Json_parse.parse src with
    | Ok j -> j
    | Error e -> die 2 (file ^ ": " ^ e)
  in
  let doc =
    match Mgtt_read.of_json j with
    | Ok d -> d
    | Error e -> die 2 (file ^ ": " ^ e)
  in
  let name = Filename.remove_extension (Filename.basename file) in
  let text, ds = Emit_mgtt.file ~name doc in
  print_string text;
  flush stdout;
  report_declines ds;
  exit (if strict && ds <> [] then 1 else 0)
