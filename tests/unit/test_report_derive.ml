(* [Report_derive], extension §7 and §9 — the strings `pol derive` prints.

   Every expectation below is written out in full rather than compared against
   what the printer produced: spacing IS the contract here (two spaces of row
   indent, two spaces per tree level), and a test that echoes the output cannot
   fail when the output is wrong. The fixture is rules_base.pol, whose wiring —
   nabu → mid → cabinet, cabinet vacant — is small enough to enumerate by
   hand. *)

open Pol_data
open Pol_syntax
open Pol_runtime

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let fixture name =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.pol") then dir
    else if n = 0 then dir
    else up (Filename.dirname dir) (n - 1)
  in
  let p =
    Filename.concat (up (Sys.getcwd ()) 8) ("tests/unit/fixtures/" ^ name)
  in
  let ic = open_in_bin p in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let read src =
  match Reader.read_string src with
  | Ok ds -> ds
  | Error e -> failwith ("read: " ^ Errors.to_string e)

let model_file name =
  match Parser.parse_model (read (fixture name)) with
  | Ok m -> m
  | Error e -> failwith (name ^ ": " ^ Errors.to_string e)

(* [Rules_check.check] is the only constructor of a [Rules.program], so the
   printer is only ever shown tables the checker admitted. *)
let derive m src =
  let sp =
    match Space.build m with Ok sp -> sp | Error e -> failwith ("space: " ^ e)
  in
  match Rules_parser.parse m.Model.schema (read src) with
  | Error e -> failwith ("rules: " ^ Errors.to_string e)
  | Ok t -> (
      match Rules_check.check m t with
      | Error e -> failwith ("rules: " ^ Errors.to_string e)
      | Ok p -> Derive.run sp p)

let arity_of t rel =
  match Derive_answers.sorts_of t rel with
  | Some ss -> List.length ss
  | None -> failwith ("no relation `" ^ rel ^ "`")

let bound t rel args =
  match Derive_answers.query t rel args with
  | Some (Ok rs) -> rs
  | Some (Error _) -> failwith (rel ^ ": an argument cannot inhabit its column")
  | None -> failwith ("no relation `" ^ rel ^ "`")

let all t rel = bound t rel (List.init (arity_of t rel) (fun _ -> None))
let lines s = String.split_on_char '\n' s
let joined ls = String.concat "\n" ls
let base = model_file "rules_base.pol"
let closure = derive base (fixture "closure.rules")
let space_rules = derive base (fixture "space.rules")

(* ── Rows (§9) ───────────────────────────────────────────────────────────── *)

(* A header line, then every row indented two spaces. The count on the header
   is what makes an empty answer legible as an answer rather than as a report
   that stopped early. *)
let () =
  let out =
    Report_derive.rows closure "subordinate" (all closure "subordinate")
  in
  check "rows print a header and two-space-indented rows"
    (List.hd (lines out) = "subordinate  (3 rows)"
    && List.length (lines out) = 4
    && List.for_all
         (fun l ->
           String.length l > 2 && String.sub l 0 2 = "  " && l.[2] <> ' ')
         (List.tl (lines out)));
  check "each row is the whole tuple, two spaces between columns"
    (List.sort compare (List.tl (lines out))
    = [ "  mid  cabinet"; "  nabu  cabinet"; "  nabu  mid" ])

let () =
  let empty = derive base "(relation nobody (person))" in
  check "an empty answer set still prints a header"
    (Report_derive.rows empty "nobody" (all empty "nobody") = "nobody  (0 rows)");
  check "one row says row, not rows"
    (Report_derive.rows closure "subordinate"
       (bound closure "subordinate" [ Some "nabu"; Some "mid" ])
    = joined [ "subordinate  (1 row)"; "  nabu  mid" ])

(* A situation is its bare [Space.index], never [s0]: an entity legitimately
   named [s3] exists, so an [s] prefix would be ambiguous in exactly the column
   it was meant to clarify. *)
let () =
  let out = Report_derive.rows space_rules "reach" (all space_rules "reach") in
  check "a Situation column prints as a bare integer"
    (List.hd (lines out) = "reach  (9 rows)"
    && List.mem "  0  3" (lines out)
    && List.for_all
         (fun l ->
           List.for_all
             (fun ch -> ch = ' ' || (ch >= '0' && ch <= '9'))
             (List.of_seq (String.to_seq l)))
         (List.tl (lines out)))

(* ── Derivation trees (§7) ───────────────────────────────────────────────── *)

(* nabu's subordination to the cabinet is two rule applications deep: the
   recursive rule over `mid`, whose own derivation is the base rule. So the
   tree has a four-space line, and that depth is what --why exists for. *)
let () =
  check "a two-deep derivation indents two spaces per level"
    (Report_derive.why closure "subordinate" [ "nabu"; "cabinet" ]
    = joined
        [
          "subordinate nabu cabinet";
          "  is nabu.reports-to mid";
          "  subordinate mid cabinet";
          "    is mid.reports-to cabinet";
        ])

(* §7's three kinds of leaf, in one tree, each written differently: a fact read
   off the space, a guard checked against the model, and an absence completed
   by a lower stratum. *)
let three_leaves =
  derive base
    (joined
       [
         "(relation step (Situation Situation))";
         "(rule (step S1 S2) (edge E S1 S2))";
         "(relation quiet-step (Situation Situation))";
         "(rule (quiet-step S1 S2)";
         "  (step S1 S2)";
         "  (holds S1 (is nabu.stands quiet))";
         "  (not (step S2 S1)))";
       ])

let () =
  check "the three kinds of leaf each read as their own kind"
    (Report_derive.why three_leaves "quiet-step" [ "0"; "1" ]
    = joined
        [
          "quiet-step 0 1";
          "  step 0 1";
          "    edge nabu-speaks 0 1";
          "  is nabu.stands quiet";
          "  not step 1 0";
        ]);
  check "an extensional fact is a leaf: a fact line with nothing under it"
    (Report_derive.why three_leaves "step" [ "0"; "1" ]
    = joined [ "step 0 1"; "  edge nabu-speaks 0 1" ])

(* A fact that does not hold is an answer, not a failure: it is named and
   reported underived, because an empty tree would be indistinguishable from a
   fact with no premises. *)
let () =
  check "a fact that is not derived prints a `not derived` line"
    (Report_derive.why closure "subordinate" [ "nabu"; "nabu" ]
    = joined [ "subordinate nabu nabu"; "  not derived" ]);
  check "…and so does one naming an atom the model never mentions"
    (Report_derive.why closure "subordinate" [ "nobody-at-all"; "mid" ]
    = joined [ "subordinate nobody-at-all mid"; "  not derived" ])

let () =
  print_string
    ("test_report_derive: " ^ string_of_int !passed ^ " checks passed\n")
