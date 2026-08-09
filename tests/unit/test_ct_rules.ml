(* ct.rules (TCT): the standard rules library, driven against the two fixtures
   whose derived categories are small enough to count by hand.

   The file under test is the SHIPPED one — core/stdlib/ct.rules, not a copy —
   because a library that drifts from its tests is the failure this is for. Its
   two fixtures are chosen to be opposites: rules_base.pol's four situations
   form a DAG, where every edge is one-way and there is one final phase;
   cycle.pol's two situations are a single cycle, where none is and both are.
   A relation that quietly answered "everything" or "nothing" would pass one of
   them and fail the other.

   Every expected number below is enumerated by hand from the fixture, never
   copied from what the engine printed — test_derive.ml's rule, and for its
   reason: a test that records the output cannot fail when the output is wrong.

   rules_base.pol: two latches (quiet → vocal, each once), so the situations are
   (q,q) → {(v,q), (q,v)} → (v,v), four of them and four edges, no way back.
   cycle.pol: one flag, up and down, so two situations and two edges. *)

open Pol_data
open Pol_syntax
open Pol_runtime

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let repo_root () =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.pol") then dir
    else if n = 0 then dir
    else up (Filename.dirname dir) (n - 1)
  in
  up (Sys.getcwd ()) 8

let slurp path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let fixture name =
  slurp (Filename.concat (repo_root ()) ("tests/unit/fixtures/" ^ name))

let library name =
  slurp (Filename.concat (repo_root ()) ("core/stdlib/" ^ name))

let read src =
  match Reader.read_string src with
  | Ok ds -> ds
  | Error e -> failwith ("read: " ^ Errors.to_string e)

let model_file name =
  match Parser.parse_model (read (fixture name)) with
  | Ok m -> m
  | Error e -> failwith (name ^ ": " ^ Errors.to_string e)

let space m =
  match Space.build m with Ok sp -> sp | Error e -> failwith ("space: " ^ e)

(* [Rules_check.check] is the only constructor of a [Rules.program], so a
   library that failed stratification, range restriction or sort inference never
   reaches [Derive.run] — which makes "it derives at all" one of the assertions
   here rather than a precondition of them. *)
let program m src =
  match Rules_parser.parse m.Model.schema (read src) with
  | Error e -> failwith ("ct.rules: " ^ Errors.to_string e)
  | Ok t -> (
      match Rules_check.check m t with
      | Ok p -> p
      | Error e -> failwith ("ct.rules: " ^ Errors.to_string e))

let count d rel =
  match Derive_answers.sorts_of d rel with
  | None -> failwith ("no relation `" ^ rel ^ "` in ct.rules")
  | Some ss -> (
      let args = List.map (fun _ -> None) ss in
      match Derive_answers.query d rel args with
      | Some (Ok rs) -> List.length rs
      | Some (Error _) -> failwith (rel ^ ": a column cannot be inhabited")
      | None -> failwith ("no relation `" ^ rel ^ "`"))

let ct = library "ct.rules"

let dag =
  Derive.run
    (space (model_file "rules_base.pol"))
    (program (model_file "rules_base.pol") ct)

let loop =
  let m = model_file "cycle.pol" in
  Derive.run (space m) (program m ct)

(* The DAG. `reach` is four identities plus the five forward pairs — (q,q) to
   each of the other three, and each of the two middles to (v,v). Nothing runs
   backwards, so `mutual` is the identities alone and `before` is the five. *)
let () =
  check "reach is the identities plus every forward pair" (count dag "reach" = 9);
  check "mutual over a DAG is the identities alone" (count dag "mutual" = 4);
  check "before is reach minus the identities, here" (count dag "before" = 5)

(* Every edge of a DAG is a door with no way back, and there is exactly one
   terminal class: (v,v), which is also the only situation with no move. The
   three that can still leave are what `escapes` collects. *)
let () =
  check "every edge of a DAG is one-way" (count dag "one-way" = 4);
  check "three of the four situations can still leave their class"
    (count dag "escapes" = 3);
  check "a DAG with one sink has one final phase" (count dag "final-phase" = 1);
  check "three situations have a move" (count dag "moves" = 3);
  check "the sink is the one dead end" (count dag "dead-end" = 1)

(* The cycle, where every answer is the opposite. Both situations reach each
   other, so the poset has collapsed to a single class: nothing is `before`
   anything, no edge is one-way, nobody escapes, and both situations are final
   WITHOUT either being a dead end — which is the distinction §6 exists to make
   sayable, and the one a "stuck" test that only looked for dead ends misses. *)
let () =
  check "reach over a two-cycle is every pair" (count loop "reach" = 4);
  check "a cycle is one isomorphism class" (count loop "mutual" = 4);
  check "nothing is strictly before anything" (count loop "before" = 0);
  check "no edge of a cycle is one-way" (count loop "one-way" = 0);
  check "nobody escapes a single class" (count loop "escapes" = 0);
  check "both situations are in the final phase" (count loop "final-phase" = 2);
  check "a final phase need not be a dead end" (count loop "dead-end" = 0)

let () =
  print_string ("ct.rules tests: " ^ string_of_int !passed ^ " checks passed\n")
