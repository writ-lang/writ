(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* §10.3: [(set CHAIN RHS)] takes a chain on the right.
   Q1 — the right side is read in the starting situation: a [do] block is a
   simultaneous assignment.
   Q2 — a chain with no answer disables the move; a no-op self-loop would hide
   a stuck situation from [Space.dead_ends]. *)

open Writ_data
open Writ_syntax
open Writ_runtime

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let contains_sub ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

let resolve _ = Error { Errors.pos = None; msg = "no loads in these fixtures" }

let model_of src =
  Loader.read_model resolve "t.writ" |> ignore;
  Reader.read_string ~file:"t.writ" src |> Result.map_error Errors.to_string
  |> fun r ->
  Result.bind r (fun ds ->
      Expander.expand ds |> Result.map_error Errors.to_string)
  |> fun r ->
  Result.bind r (fun ds ->
      Parser.parse_model ds |> Result.map_error Errors.to_string)

let space_of src =
  match model_of src with
  | Error e -> failwith ("model failed: " ^ e)
  | Ok m -> ( match Space.build m with Ok sp -> sp | Error e -> failwith e)

(* --- Q1: a do block is a simultaneous assignment -------------------------- *)

(* Simultaneous gives {a=q, b=p}; sequential would give {a=q, b=q}. *)
let swap_src =
  "(schema s (type v (p q)) (type box (arrow x (to v))))\n\
   (instance i s (box a (x p)) (box b (x q)) (v z) )\n\
   (use s)\n\
   (initial i)\n\
   (transition swap (when (is a.x p)) (do (set a.x b.x) (set b.x a.x)))\n"

let () =
  let sp = space_of swap_src in
  check "swap: exactly one move is available" (List.length sp.Space.edges = 1);
  let m = match model_of swap_src with Ok m -> m | Error e -> failwith e in
  let ctx = sp.Space.ctx in
  let tr = List.hd m.Model.transitions in
  match Eval.apply ctx sp.Space.states.(0) tr.Model.effects with
  | `Next st ->
      let cell root =
        Eval.eval_path ctx st [] { Value.root; steps = [ "x" ] }
      in
      check "Q1: a.x took b's OLD value" (cell "a" = Some (Value.Filled "q"));
      check "Q1: b.x took a's OLD value — a SWAP, not a copy"
        (cell "b" = Some (Value.Filled "p"))
  | `Gap _ | `Blocked -> check "swap: the move applied" false

(* --- Q1 again, through the left side ---------------------------------------
   Targets are resolved at the start too (§10.1: order cannot matter). *)
let cursor_src order =
  "(schema s (type v (p q))\n\
  \          (type box (arrow x (to v)) (arrow nxt (to box) fixed))\n\
  \          (type cur-t (arrow b (to box))))\n\
   (instance i s (box b1 (x p) (nxt b2)) (box b2 (x p) (nxt b1)) (cur-t c (b \
   b1)) (v z)  )\n\
   (use s)\n\
   (initial i)\n\
   (transition go (when (is c.b.x p)) (do " ^ order ^ "))\n"

let () =
  let a = space_of (cursor_src "(set c.b.x q) (set c.b c.b.nxt)") in
  let b = space_of (cursor_src "(set c.b c.b.nxt) (set c.b.x q)") in
  check "the cursor move reaches the same situations either way"
    (Array.length a.Space.states = Array.length b.Space.states);
  let wrote_b1 sp =
    let ctx = sp.Space.ctx in
    Array.exists
      (fun st ->
        Eval.eval_path ctx st [] { Value.root = "b1"; steps = [ "x" ] }
        = Some (Value.Filled "q"))
      sp.Space.states
  in
  check "effect order is not observable through the TARGET path"
    (wrote_b1 a && wrote_b1 b)

(* --- Q2: an unanswerable chain disables the move -------------------------- *)

(* A ladder walked by one transition: only the undefined [next] stops it. *)
let ladder_src =
  "(schema s (type rung (arrow next (to rung) fixed vacatable))\n\
  \          (type walker (arrow at (to rung))))\n\
   (instance i s (rung r1 (next r2)) (rung r2 (next r3)) (rung r3 (next r4)) \
   (rung r4 (next vacant)) (walker w (at r1))  )\n\
   (use s)\n\
   (initial i)\n\
   (transition step (when (is w.at w.at)) (do (set w.at w.at.next)))\n"

let () =
  let sp = space_of ladder_src in
  check "one transition walks the whole ladder: four situations"
    (Array.length sp.Space.states = 4);
  check "three moves, not four — the top rung draws no edge"
    (List.length sp.Space.edges = 3);
  check "Q2: the top of the ladder IS a dead end"
    (List.length (Space.dead_ends sp) = 1)

let () =
  let sp = space_of ladder_src in
  let m = match model_of ladder_src with Ok m -> m | Error e -> failwith e in
  let ctx = sp.Space.ctx in
  let tr = List.hd m.Model.transitions in
  let top =
    Array.to_list sp.Space.states
    |> List.find (fun st ->
        Eval.eval_path ctx st [] { Value.root = "w"; steps = [ "at" ] }
        = Some (Value.Filled "r4"))
  in
  check "Q2: applying it at the top reports Blocked, not Next"
    (Eval.apply ctx top tr.Model.effects = `Blocked)

(* --- the parser half: a chain must land in the written arrow's codomain ---- *)

let () =
  let src =
    "(schema s (type v (p q)) (type w (m n))\n\
    \          (type box (arrow x (to v)) (arrow y (to w))))\n\
     (instance i s (box a (x p) (y m)) (v z) (w u) )\n\
     (use s)\n\
     (initial i)\n\
     (transition t (when (is a.x p)) (do (set a.x a.y)))\n"
  in
  match model_of src with
  | Ok _ -> check "a chain landing in the wrong type must be rejected" false
  | Error e ->
      check "the rejection names both types"
        (contains_sub ~sub:"lands in `w`" e && contains_sub ~sub:"takes `v`" e)

let () =
  let src =
    "(schema s (type v (p q)) (type box (arrow x (to v))))\n\
     (instance i s (box a (x p)) (v z) )\n\
     (use s)\n\
     (initial i)\n\
     (transition t (when (is a.x p)) (do (set a.x zzz)))\n"
  in
  match model_of src with
  | Ok _ -> check "a literal outside the codomain is still rejected" false
  | Error e ->
      check "and still with the codomain message"
        (contains_sub ~sub:"not in codomain" e)

let () =
  print_string
    ("set-as-chain tests: " ^ string_of_int !passed ^ " checks passed\n")
