(* The five built-in relations of extension §2, each cross-checked against what
   [Space.t] independently says — not against this engine's own output, which
   would only prove it agrees with itself. Split from test_derive.ml by SUBJECT,
   matching the module split it exercises: [Facts] is the adapter that exposes
   the derived state category as relations, [Derive] is the fixpoint over them.
   The two failed for different reasons and are worth reading apart. *)

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

let space m =
  match Space.build m with Ok sp -> sp | Error e -> failwith ("space: " ^ e)

(* [Rules_check.check] is the only constructor of a [Rules.program], so it is
   the only way in here too — the engine cannot be handed anything unchecked. *)
let program_of m src =
  match Rules_parser.parse m.Model.schema (read src) with
  | Error e -> failwith ("rules: " ^ Errors.to_string e)
  | Ok t -> (
      match Rules_check.check m t with
      | Ok p -> p
      | Error e -> failwith ("rules: " ^ Errors.to_string e))

let program m name = program_of m (fixture name)

let arity d rel =
  match Derive_answers.sorts_of d rel with
  | Some ss -> List.length ss
  | None -> failwith ("no relation `" ^ rel ^ "`")

let rows d rel args =
  match Derive_answers.query d rel args with
  | Some (Ok rs) -> List.sort compare (List.map (Derive_answers.row d rel) rs)
  | Some (Error _) -> failwith (rel ^ ": an argument cannot inhabit its column")
  | None -> failwith ("no relation `" ^ rel ^ "`")

let all d rel = rows d rel (List.init (arity d rel) (fun _ -> None))
let base = model_file "rules_base.pol"
let base_sp = space base

(* ── The five built-ins, against what Space.t says ───────────────────────── *)

let index sp s = State.M.find s sp.Space.index

(* Recomputed from [Space.t] rather than called through [Facts]: a cross-check
   that calls the thing it checks proves only that it is deterministic. *)
let space_edges sp =
  List.filter_map
    (fun (e : Space.edge) ->
      match e.Space.dst with
      | `To s' ->
          Some
            [
              e.Space.via;
              string_of_int (index sp e.Space.src);
              string_of_int (index sp s');
            ]
      | `Gap _ -> None)
    sp.Space.edges

let space_gaps sp =
  List.filter_map
    (fun (e : Space.edge) ->
      match e.Space.dst with
      | `Gap _ -> Some [ e.Space.via; string_of_int (index sp e.Space.src) ]
      | `To _ -> None)
    sp.Space.edges

let reach = Derive.run base_sp (program base "space.rules")

let () =
  let sits =
    List.init (Array.length base_sp.Space.states) (fun i -> [ string_of_int i ])
  in
  check "(situation S) is exactly Space.states, by index — four of them"
    (all reach "situation" = List.sort compare sits && List.length sits = 4);
  check "(init S) is exactly Space.initial's index"
    (all reach "init"
    = [ [ string_of_int (index base_sp base_sp.Space.initial) ] ]);
  check "(edge E S1 S2) is exactly the `To edges of Space.edges"
    (all reach "edge" = List.sort compare (space_edges base_sp));
  check "the four edges are the ones the two transitions can fire"
    (all reach "edge"
    = [
        [ "mid-speaks"; "0"; "2" ];
        [ "mid-speaks"; "1"; "3" ];
        [ "nabu-speaks"; "0"; "1" ];
        [ "nabu-speaks"; "2"; "3" ];
      ]);
  check "(gap-edge E S) is empty where the model declares no gap"
    (all reach "gap-edge" = [] && space_gaps base_sp = [])

(* A gap edge exists only where a model declares one, so [gap-edge] is
   cross-checked against the fixture that does: gap.pol's `hi` can only exit. *)
let () =
  let gm = model_file "gap.pol" in
  let gsp = space gm in
  let d =
    Derive.run gsp
      (program_of gm "(relation exits 2)\n(rule (exits E S) (gap-edge E S))")
  in
  check "(gap-edge E S) is exactly the `Gap edges of Space.edges"
    (all d "gap-edge" = List.sort compare (space_gaps gsp));
  check "…which is the one row a rule over it derives"
    (all d "gap-edge" = [ [ "boom"; "1" ] ]
    && all d "exits" = [ [ "boom"; "1" ] ])

(* [(holds S G)] is the kernel evaluator's graph: every situation, every
   person. *)
let () =
  let d =
    Derive.run base_sp
      (program_of base
         "(relation vocal (Situation person))\n\
          (rule (vocal S X) (situation S) (holds S (is X.stands vocal)))")
  in
  let want =
    List.concat_map
      (fun i ->
        List.filter_map
          (fun p ->
            let g =
              Model.Is
                ({ Value.root = p; steps = [ "stands" ] }, Model.Lit "vocal")
            in
            if Eval.guard_holds base_sp.Space.ctx base_sp.Space.states.(i) [] g
            then Some [ string_of_int i; p ]
            else None)
          [ "nabu"; "mid"; "cabinet" ])
      (List.init (Array.length base_sp.Space.states) Fun.id)
  in
  check "(holds S G) agrees with the kernel evaluator, state by state"
    (all d "vocal" = List.sort compare want);
  check "…and is not vacuously empty" (want <> [])

(* ── The phase built-ins, against the closure they quotient ──────────────── *)

(* Tarjan's partition is checked against the DEFINITION of the thing it computes
   — two situations share a phase exactly when each reaches the other — and
   `reach` is derived by the Datalog fixpoint from `edge` alone, knowing nothing
   about components. Two implementations of one question, which is the only
   cross-check worth having; comparing the partition with itself would prove
   only that it is deterministic. *)
let reach_src =
  "(relation reach 2)\n\
   (rule (reach S S) (situation S))\n\
   (rule (reach S T) (edge E S M) (reach M T))"

let phase_agrees label m sp =
  let d = Derive.run sp (program_of m reach_src) in
  let n = Array.length sp.Space.states in
  let ix = string_of_int in
  let r = all d "reach" in
  let reaches a b = List.mem [ ix a; ix b ] r in
  let ph = all d "phase" in
  let phase_of i =
    match List.filter (fun row -> List.nth row 0 = ix i) ph with
    | [ [ _; p ] ] -> p
    | _ -> failwith (label ^ ": phase is not a function on situations")
  in
  check (label ^ ": every situation has exactly one phase") (List.length ph = n);
  let agree = ref true in
  for a = 0 to n - 1 do
    for b = 0 to n - 1 do
      if phase_of a = phase_of b <> (reaches a b && reaches b a) then
        agree := false
    done
  done;
  check
    (label ^ ": two situations share a phase iff each reaches the other")
    !agree;
  (* The representative is a member of its own phase, and is the least-indexed
     one — the naming this rests on, and what makes a phase addressable as a
     situation rather than as an opaque handle. *)
  let named = ref true in
  for i = 0 to n - 1 do
    let p = phase_of i in
    if phase_of (int_of_string p) <> p || int_of_string p > i then
      named := false
  done;
  check (label ^ ": a phase is named by its least-indexed member") !named;
  (* The quotient's edges: exactly the edges that cross a phase boundary, and
     never one that stays inside — which is what makes the quotient acyclic. *)
  let want =
    List.sort_uniq compare
      (List.filter_map
         (fun row ->
           match row with
           | [ _; a; b ]
             when phase_of (int_of_string a) <> phase_of (int_of_string b) ->
               Some [ phase_of (int_of_string a); phase_of (int_of_string b) ]
           | _ -> None)
         (all d "edge"))
  in
  check
    (label ^ ": phase-step is exactly the edges that cross a phase boundary")
    (all d "phase-step" = want);
  d

(* rules_base.pol is a DAG — two latches, each thrown once — so no situation
   reaches itself the long way and every one is a phase of its own. Counted by
   hand from the fixture: 0 → {1, 2} → 3. *)
let () =
  let d = phase_agrees "rules_base (a DAG)" base base_sp in
  check "a DAG: every situation is its own phase"
    (all d "phase" = [ [ "0"; "0" ]; [ "1"; "1" ]; [ "2"; "2" ]; [ "3"; "3" ] ]);
  check "a DAG: the quotient is the edge set itself, four crossings"
    (all d "phase-step"
    = [ [ "0"; "1" ]; [ "0"; "2" ]; [ "1"; "3" ]; [ "2"; "3" ] ])

(* cycle.pol is the opposite: one flag up and down, so the two situations are
   one phase and nothing crosses out of it. A partition that quietly answered
   "everything is its own class" passes the fixture above and fails this one. *)
let () =
  let cm = model_file "cycle.pol" in
  let csp = space cm in
  let d = phase_agrees "cycle (one loop)" cm csp in
  check "a loop: both situations are one phase, named by the initial one"
    (all d "phase" = [ [ "0"; "0" ]; [ "1"; "0" ] ]);
  check "a loop: nothing crosses out, so the quotient has no edges"
    (all d "phase-step" = [])

let () =
  print_string ("facts tests: " ^ string_of_int !passed ^ " checks passed\n")
