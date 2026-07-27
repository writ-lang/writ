(* §10.3 widened: [(set CHAIN RHS)] takes a chain on the right, as [(is CHAIN
   RHS)] already did. The parser half is small; the two SEMANTIC decisions are
   what this file exists to pin, because both were genuinely open and either
   could have gone the other way without any test noticing.

   Q1 — WHEN IS THE RIGHT-HAND SIDE READ? In the situation the move STARTED
   from, which makes a [do] block a simultaneous assignment. The witness is a
   swap: read sequentially, [(do (set a.x b.x) (set b.x a.x))] leaves both
   cells holding b's old value, and nothing else in the suite can tell the two
   readings apart.

   Q2 — WHAT IF THE CHAIN HAS NO ANSWER? The move is NOT ENABLED. Not a no-op,
   which would still be an edge — a self-loop — and [Space.dead_ends] marks a
   state as having an out-edge on [e.src] alone, so a no-op would silently stop
   a stuck situation being reported as stuck. Not a vacated target either, which
   would write [vacant] through [set] and §8.3 forbids that outright. *)

open Pol_data
open Pol_syntax
open Pol_runtime

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

(* No I/O: the only [(load …)] any fixture here needs is none. *)
let resolve _ = Error { Errors.pos = None; msg = "no loads in these fixtures" }

let model_of src =
  Loader.read_model resolve "t.pol" |> ignore;
  Reader.read_string ~file:"t.pol" src |> Result.map_error Errors.to_string
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

(* Two boxes, a holding p and b holding q, swapped in one move. Read from the
   STARTING situation this ends {a=q, b=p}; read sequentially it ends
   {a=q, b=q}, because the second [set] would see what the first wrote. *)
let swap_src =
  "(schema s (type v (p q)) (type box (arrow x (to v))))\n\
   (instance i (of s) (box a b) (v z) (x (a p) (b q)))\n\
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

(* --- Q2: an unanswerable chain disables the move -------------------------- *)

(* A four-rung ladder walked by ONE transition — the whole point of the change:
   before it, this needed one move per destination. The guard is deliberately
   trivial ([w.at] is always itself), so the ONLY thing that can stop the walk
   at the top is the undefined [next], and the only thing that can report the
   top as stuck is that no edge was drawn. *)
let ladder_src =
  "(schema s (type rung (arrow next (to rung) fixed vacatable))\n\
  \          (type walker (arrow at (to rung))))\n\
   (instance i (of s) (rung r1 r2 r3 r4) (walker w)\n\
  \  (next (r1 r2) (r2 r3) (r3 r4) (r4 vacant)) (at (w r1)))\n\
   (use s)\n\
   (initial i)\n\
   (transition step (when (is w.at w.at)) (do (set w.at w.at.next)))\n"

let () =
  let sp = space_of ladder_src in
  check "one transition walks the whole ladder: four situations"
    (Array.length sp.Space.states = 4);
  check "three moves, not four — the top rung draws no edge"
    (List.length sp.Space.edges = 3);
  (* The decision that matters: had `Blocked been a no-op, the top would carry
     a self-loop and would never be reported here. *)
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
     (instance i (of s) (box a) (v z) (w u) (x (a p)) (y (a m)))\n\
     (use s)\n\
     (initial i)\n\
     (transition t (when (is a.x p)) (do (set a.x a.y)))\n"
  in
  match model_of src with
  | Ok _ -> check "a chain landing in the wrong type must be rejected" false
  | Error e ->
      check "the rejection names both types"
        (contains_sub ~sub:"lands in `w`" e && contains_sub ~sub:"takes `v`" e)

(* A literal right-hand side is untouched by any of this — the widening added a
   case, it did not replace one. *)
let () =
  let src =
    "(schema s (type v (p q)) (type box (arrow x (to v))))\n\
     (instance i (of s) (box a) (v z) (x (a p)))\n\
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
