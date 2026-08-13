(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

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
  (* [~open_heads:true] is what [Loader.read_rules] passes, and this harness has
     to pass it too: §7's forms have rule bodies whose heads are relations, which
     the expander cannot know. Expanding here rather than parsing the raw datums
     is also the point — a `(form …)` reaching [Rules_parser] unexpanded is not a
     rules declaration at all. *)
  match Expander.expand ~open_heads:true (read src) with
  | Error e -> failwith ("ct.rules: " ^ Errors.to_string e)
  | Ok ds -> (
      match Rules_parser.parse m.Model.schema ds with
      | Error e -> failwith ("ct.rules: " ^ Errors.to_string e)
      | Ok t -> (
          match Rules_check.check m t with
          | Ok p -> p
          | Error e -> failwith ("ct.rules: " ^ Errors.to_string e)))

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

(* The two phase-derived relations, on the same fixture. A DAG has no recurrence
   at all, and its quotient is itself — so the phase order has the same five
   pairs `before` does, which is the agreement worth asserting: the two are
   computed by different routes (a closure over the quotient, then read down
   onto situations) and must not part company. *)
let () =
  check "a DAG has no situation on a cycle" (count dag "recurrent" = 0);
  check "the phase order closes the four crossings into five pairs"
    (count dag "phase-before" = 5);
  check "…which is exactly `before`, every phase being a single situation here"
    (count dag "phase-before" = count dag "before")

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
  check "a final phase need not be a dead end" (count loop "dead-end" = 0);
  (* The pair the DAG cannot distinguish. `final-phase` holds of both situations
     here AND of the DAG's sink, so on its own it does not say whether a model
     has arrived or is going round forever; `recurrent` is what tells the two
     apart, and it is the relation that had no spelling before `phase` — "S and
     T are one class and are not the same situation" needs an inequality on
     situations, and the language has none. *)
  check "both situations of a cycle are on it" (count loop "recurrent" = 2);
  check "one class, so no phase precedes another" (count loop "phase-before" = 0)

(* §7 — the three goal forms, which are the only part of the library a model
   INVOKES rather than merely loads, so the invocation is appended here. The
   guard is the DAG's sink, reached from everywhere and left from nowhere:
   `satisfies` is that one situation, `can-reach` is all four, and `trapped` —
   the counterexample set a `live` claim would report — is empty, which is the
   polarity §7's comment warns is the easy one to invert. *)
let goals =
  "\n\
   (satisfies both-vocal (and (is nabu.stands vocal) (is mid.stands vocal)))\n\
   (can-reach can-finish both-vocal)\n\
   (trapped stuck can-finish)\n"

let dag_goals =
  let m = model_file "rules_base.pol" in
  Derive.run (space m) (program m (ct ^ goals))

let () =
  check "satisfies is the situations where the guard holds"
    (count dag_goals "both-vocal" = 1);
  check "can-reach is every situation that still reaches one"
    (count dag_goals "can-finish" = 4);
  check "trapped is empty where the goal is always still reachable"
    (count dag_goals "stuck" = 0)

(* A model where the goal CAN be lost, so `trapped` is non-empty and the forms
   are shown to tell the two cases apart. Written here rather than taken from a
   fixture because the fixtures that trap — captured_trap.pol — reach their trap
   through `(load …)`, and this harness parses without the loader.

   `latch` is irreversible and `goal` needs p still at a. From (a,a): latch to
   (b,a), goal to (a,b), and from (a,b) latch to (b,b) — four situations. The
   goal is q at b, so it holds in (a,b) and (b,b); every situation reaches one
   EXCEPT (b,a), where the latch has been thrown before the goal was taken and
   no move remains. One trapped situation, and it is the point of the model. *)
let trap_src =
  "(schema s\n\
  \   (type f (a b))\n\
  \   (type box (arrow p (to f)) (arrow q (to f))))\n\
   (instance i s (box x (p a) (q a)))\n\
   (use s)\n\
   (initial i)\n\
   (transition latch (when (is x.p a)) (do (set x.p b)))\n\
   (transition goal (when (and (is x.p a) (is x.q a))) (do (set x.q b)))\n"

let trap_goals =
  let m =
    match Parser.parse_model (read trap_src) with
    | Ok m -> m
    | Error e -> failwith ("trap model: " ^ Errors.to_string e)
  in
  Derive.run (space m)
    (program m
       (ct
      ^ "\n\
         (satisfies done (is x.q b))\n\
         (can-reach can-finish done)\n\
         (trapped lost can-finish)\n"))

let () =
  check "the goal holds in two of the four situations"
    (count trap_goals "done" = 2);
  check "three situations can still reach it" (count trap_goals "can-finish" = 3);
  check "throwing the latch first loses the goal for good"
    (count trap_goals "lost" = 1);
  (* Every situation either has a move or has not, so the two partition the
     space — which is what makes this a partition check and not two numbers. *)
  check "can-reach and trapped partition the space"
    (count trap_goals "can-finish" + count trap_goals "lost"
    = count trap_goals "moves" + count trap_goals "dead-end")

(* §8 — the two implementations of `inevitable`, against each other.

   This is the one test in the file whose oracle its author did not choose. The
   engine partitions the subgraph the goal fails in and looks for components;
   the library confines a transitive closure to the same subgraph and looks for
   a situation that returns to itself. Nothing is shared but the space they read
   — different algorithms, different complexity, different module. Comparing the
   SETS rather than the verdicts is the point: two implementations can agree on
   "something escapes" while disagreeing about what, and the disagreement is
   where the bug would be. *)

let escape_calls goal =
  "\n(satisfies goal " ^ goal
  ^ ")\n\
     (off-set off goal)\n\
     (stays confined off)\n\
     (escaping escape off confined)\n"

let cross label src goal =
  let m =
    match Parser.parse_model (read src) with
    | Ok m -> m
    | Error e -> failwith (label ^ ": " ^ Errors.to_string e)
  in
  let sp = space m in
  let d = Derive.run sp (program m (ct ^ escape_calls goal)) in
  let by_library =
    match Derive_answers.query d "escape" [ None ] with
    | Some (Ok rs) ->
        List.sort compare
          (List.map (fun r -> List.hd (Derive_answers.row d "escape" r)) rs)
    | _ -> failwith (label ^ ": no `escape` relation")
  in
  let g =
    match Grammar.guard (List.hd (read goal)) with
    | Ok g -> g
    | Error e -> failwith (label ^ ": " ^ Errors.to_string e)
  in
  let esc =
    Space.escapes_f sp (fun s -> Eval.guard_holds sp.Space.ctx s [] g)
  in
  let by_engine =
    List.filter_map
      (fun i -> if esc.(i) then Some (string_of_int i) else None)
      (List.init (Array.length esc) Fun.id)
  in
  check
    (label ^ ": the library and the engine name the same escaping situations")
    (by_library = List.sort compare by_engine);
  (* And the modality's verdict is that set's emptiness — the polarity §8 warns
     about, asserted rather than trusted. *)
  let verdict =
    Checker.check sp
      {
        Claims.name = "i";
        text = "";
        modality = Claims.Inevitable [];
        formula = g;
      }
  in
  check
    (label ^ ": inevitable holds exactly when nothing escapes")
    ((match verdict with Checker.Holds _ -> true | _ -> false)
    = (by_library = []));
  List.length by_library

(* Four shapes, chosen so that between them every branch of §8 fires: a DAG
   where nothing escapes, a loop where nothing does either (the goal is ON the
   loop, which is the case an implementation that feared cycles would get
   wrong), a loop that misses the goal, and a one-way door into a dead end. *)

let detour_src =
  "(schema s\n\
  \   (type f (a b c))\n\
  \   (type box (arrow p (to f))))\n\
   (instance i s (box x (p a)))\n\
   (use s)\n\
   (initial i)\n\
   (transition wander (when (is x.p a)) (do (set x.p b)))\n\
   (transition back   (when (is x.p b)) (do (set x.p a)))\n\
   (transition arrive (when (is x.p a)) (do (set x.p c)))\n"

let () =
  check "a DAG whose every run passes the goal: nothing escapes"
    (cross "dag" (fixture "rules_base.pol") "(is nabu.stands vocal)" = 0);
  check "a loop with the goal on it: nothing escapes either"
    (cross "loop" (fixture "cycle.pol") "(is b.f hi)" = 0);
  check "a loop that misses the goal: both its situations escape"
    (cross "detour" detour_src "(is x.p c)" = 2);
  check "a one-way door into a dead end: the dead end escapes"
    (cross "trap" trap_src "(is x.q b)" = 1)

let () =
  print_string ("ct.rules tests: " ^ string_of_int !passed ^ " checks passed\n")
