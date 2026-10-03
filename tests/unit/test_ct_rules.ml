(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The shipped core/stdlib/ct.rules against two hand-countable fixtures:
   rules_base.writ, a DAG (q,q) → {(v,q), (q,v)} → (v,v), and cycle.writ, one
   two-situation cycle. A relation answering "everything" or "nothing" fails
   one of them. *)

open Writ_data
open Writ_syntax
open Writ_runtime

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let repo_root () =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.writ") then dir
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

let program m src =
  (* As [Loader.read_rules] does: §7's forms have relation heads the expander
     cannot know. *)
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
    (space (model_file "rules_base.writ"))
    (program (model_file "rules_base.writ") ct)

let loop =
  let m = model_file "cycle.writ" in
  Derive.run (space m) (program m ct)

(* The DAG: `reach` is four identities plus five forward pairs; nothing runs
   backwards, so `mutual` is the identities and `before` the five. *)
let () =
  check "reach is the identities plus every forward pair" (count dag "reach" = 9);
  check "mutual over a DAG is the identities alone" (count dag "mutual" = 4);
  check "before is reach minus the identities, here" (count dag "before" = 5)

(* Every DAG edge is one-way; (v,v) is the one terminal class. *)
let () =
  check "every edge of a DAG is one-way" (count dag "one-way" = 4);
  check "three of the four situations can still leave their class"
    (count dag "escapes" = 3);
  check "a DAG with one sink has one final phase" (count dag "final-phase" = 1);
  check "three situations have a move" (count dag "moves" = 3);
  check "the sink is the one dead end" (count dag "dead-end" = 1)

(* The phase order equals `before` here; the two are computed differently. *)
let () =
  check "a DAG has no situation on a cycle" (count dag "recurrent" = 0);
  check "the phase order closes the four crossings into five pairs"
    (count dag "phase-before" = 5);
  check "…which is exactly `before`, every phase being a single situation here"
    (count dag "phase-before" = count dag "before")

(* The cycle is one class: nothing is before anything or escapes, and both
   situations are final without being dead ends (§6). *)
let () =
  check "reach over a two-cycle is every pair" (count loop "reach" = 4);
  check "a cycle is one isomorphism class" (count loop "mutual" = 4);
  check "nothing is strictly before anything" (count loop "before" = 0);
  check "no edge of a cycle is one-way" (count loop "one-way" = 0);
  check "nobody escapes a single class" (count loop "escapes" = 0);
  check "both situations are in the final phase" (count loop "final-phase" = 2);
  check "a final phase need not be a dead end" (count loop "dead-end" = 0);
  (* `recurrent` tells going round forever from arriving. *)
  check "both situations of a cycle are on it" (count loop "recurrent" = 2);
  check "one class, so no phase precedes another" (count loop "phase-before" = 0)

(* §7's goal forms, with the DAG's sink as goal: `satisfies` is one situation,
   `can-reach` all four, `trapped` none. *)
let goals =
  "\n\
   (satisfies both-vocal (and (is nabu.stands vocal) (is mid.stands vocal)))\n\
   (can-reach can-finish both-vocal)\n\
   (trapped stuck can-finish)\n"

let dag_goals =
  let m = model_file "rules_base.writ" in
  Derive.run (space m) (program m (ct ^ goals))

let () =
  check "satisfies is the situations where the guard holds"
    (count dag_goals "both-vocal" = 1);
  check "can-reach is every situation that still reaches one"
    (count dag_goals "can-finish" = 4);
  check "trapped is empty where the goal is always still reachable"
    (count dag_goals "stuck" = 0)

(* A goal that can be lost: after `latch`, (b,a) cannot reach q at b. One
   trapped situation. *)
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
  check "can-reach and trapped partition the space"
    (count trap_goals "can-finish" + count trap_goals "lost"
    = count trap_goals "moves" + count trap_goals "dead-end")

(* §8 — the engine's `inevitable` against the library's: different algorithms,
   compared as sets, since two can agree something escapes but not on what. *)

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
  let verdict =
    Checker.check sp
      {
        Claims.name = "i";
        text = "";
        modality = Claims.Inevitable [];
        formula = g;
        show = [];
      }
  in
  check
    (label ^ ": inevitable holds exactly when nothing escapes")
    ((match verdict with Checker.Holds _ -> true | _ -> false)
    = (by_library = []));
  List.length by_library

(* Four shapes covering every branch of §8: a DAG, a loop through the goal, a
   loop that misses it, a one-way door into a dead end. *)

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
    (cross "dag" (fixture "rules_base.writ") "(is nabu.stands vocal)" = 0);
  check "a loop with the goal on it: nothing escapes either"
    (cross "loop" (fixture "cycle.writ") "(is b.f hi)" = 0);
  check "a loop that misses the goal: both its situations escape"
    (cross "detour" detour_src "(is x.p c)" = 2);
  check "a one-way door into a dead end: the dead end escapes"
    (cross "trap" trap_src "(is x.q b)" = 1)

let () =
  print_string ("ct.rules tests: " ^ string_of_int !passed ^ " checks passed\n")
