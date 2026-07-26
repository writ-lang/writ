(* Derivation tests (TDV): [Facts] and [Derive], extension §2 and §6 — the
   built-in relations, and the stratified semi-naive fixpoint over them.

   Every expected row set below is enumerated BY HAND from the fixture, never
   copied from what the engine printed: a test that records the output cannot
   fail when the output is wrong. rules_base.pol wires nabu → mid → cabinet and
   flips two stances once each, so its derived category is four situations and
   four edges — small enough to count. *)

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

(* ── Reading answers back ────────────────────────────────────────────────── *)

let arity d rel =
  match Derive_table.sorts_of d rel with
  | Some ss -> List.length ss
  | None -> failwith ("no relation `" ^ rel ^ "`")

let rows d rel args =
  match Derive_table.query d rel args with
  | Some rs -> List.sort compare (List.map (Derive_table.row d rel) rs)
  | None -> failwith ("no relation `" ^ rel ^ "`")

let all d rel = rows d rel (List.init (arity d rel) (fun _ -> None))
let base = model_file "rules_base.pol"
let base_sp = space base
let closure = Derive.run base_sp (program base "closure.rules")

(* ── The specification's own transitive closure ──────────────────────────── *)

(* The base rule gives (nabu mid) and (mid cabinet) — cabinet's cell is vacant
   and a vacant cell derives NOTHING, which is the partiality the whole language
   is about — and the recursive rule adds (nabu cabinet). Three rows, no
   fourth. *)
let () =
  check "the transitive closure is exactly the three rows the wiring forces"
    (all closure "subordinate"
    = [ [ "mid"; "cabinet" ]; [ "nabu"; "cabinet" ]; [ "nabu"; "mid" ] ])

(* ── A bound query is a filter, in either argument position ──────────────── *)

let () =
  let backward = rows closure "subordinate" [ None; Some "cabinet" ] in
  check "a query bound in the SECOND position is the backward image"
    (backward = [ [ "mid"; "cabinet" ]; [ "nabu"; "cabinet" ] ]);
  check "the backward image is a strict subset of the unbound answer"
    (List.length backward < List.length (all closure "subordinate"));
  check "a query for a row that does not hold, or an unknown atom, is empty"
    (rows closure "subordinate" [ Some "cabinet"; Some "nabu" ] = []
    && rows closure "subordinate" [ Some "nobody-at-all"; None ] = [])

(* ── An empty relation is an answer ──────────────────────────────────────── *)

let () =
  let d = Derive.run base_sp (program base "rules_empty.rules") in
  check "a declared relation with no rules derives the empty set"
    (Derive_table.query d "nobody" [ None ] = Some []);
  check "…which is not the same as an undeclared one"
    (Derive_table.query d "no-such-relation" [ None ] = None)

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
              Model.Is ({ Value.root = p; steps = [ "stands" ] }, "vocal")
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

(* ── Recursion over the derived category ─────────────────────────────────── *)

(* Counted by hand off the four edges above: four reflexive rows, the four
   single steps, and 0 → 3 by either route. Nine, and no tenth — 1 and 2 are
   siblings. *)
let pairs = List.map (fun (a, b) -> [ string_of_int a; string_of_int b ])

let () =
  check "reach is the nine rows the four edges force"
    (all reach "reach"
    = pairs
        [
          (0, 0); (0, 1); (0, 2); (0, 3); (1, 1); (1, 3); (2, 2); (2, 3); (3, 3);
        ]);
  check "the forward image of 0 is a strict subset of it"
    (rows reach "reach" [ Some "0"; None ]
    = pairs [ (0, 0); (0, 1); (0, 2); (0, 3) ]);
  check "and the backward image of 2 runs the dynamics in reverse"
    (rows reach "reach" [ None; Some "2" ] = [ [ "0"; "2" ]; [ "2"; "2" ] ])

(* The same recursion over a state graph that loops. Every pair is reachable,
   so this is where a derivation graph gets the chance to close a cycle — see
   the acyclicity check at the end, which a DAG could not put under strain. *)
let cycle_m = model_file "cycle.pol"
let cycle_sp = space cycle_m
let cycle = Derive.run cycle_sp (program cycle_m "space.rules")

let () =
  check "the toggle's two situations reach each other both ways"
    (all cycle "edge" = [ [ "down"; "1"; "0" ]; [ "up"; "0"; "1" ] ]);
  check "so reach over a cyclic space is the full square"
    (all cycle "reach" = pairs [ (0, 0); (0, 1); (1, 0); (1, 1) ])

(* ── Negation sees a COMPLETED stratum ───────────────────────────────────── *)

(* `skipped` asks for a two-step chain that is not also a one-step fact of
   `subordinate`. The only chain is nabu → mid → cabinet, and (nabu cabinet) IS
   in `subordinate` — but only after the recursion has closed. So an empty
   `skipped` is evidence the negation ran against the finished relation; had it
   run against the base facts alone, or mid-round, it would derive that row. *)
let () =
  let d =
    Derive.run base_sp
      (program_of base
         "(relation subordinate 2)\n\
          (rule (subordinate X Y) (is X.reports-to Y))\n\
          (rule (subordinate X Y) (is X.reports-to Z) (subordinate Z Y))\n\
          (relation skipped 2)\n\
          (rule (skipped X Y) (is X.reports-to Z) (subordinate Z Y) (not \
          (subordinate X Y)))")
  in
  check "the fact that empties the negation is derived at all"
    (List.mem [ "nabu"; "cabinet" ] (all d "subordinate"));
  check "a negated literal is evaluated against a completed stratum"
    (all d "skipped" = [])

(* ── No fact is among its own transitive premises ────────────────────────── *)

(* Asserted directly, over every fact of every relation, because nothing at the
   level of an answer set would notice its loss: the rows would be identical and
   `--why` would walk for ever. *)
let fact_ids d =
  List.concat_map
    (fun rel -> List.filter_map (Derive_table.fact_id d rel) (all d rel))
    (Derive_table.relations d)

let rec above d seen id =
  match Derive_table.derivation d id with
  | None -> seen
  | Some dv ->
      List.fold_left
        (fun seen p ->
          match p with
          | Rules.Premise_fact f ->
              if List.mem f seen then seen else above d (f :: seen) f
          | Rules.Premise_guard _ | Rules.Premise_absent _ -> seen)
        seen dv.Rules.premises

let acyclic name d =
  let ids = fact_ids d in
  check (name ^ ": there are facts to check") (List.length ids > 0);
  List.iter
    (fun id ->
      check
        (name ^ ": fact " ^ string_of_int id ^ " is its own premise")
        (not (List.mem id (above d [] id))))
    ids

let () =
  acyclic "closure" closure;
  acyclic "reach" reach;
  acyclic "reach over a cyclic space" cycle

let () =
  print_string ("derive tests: " ^ string_of_int !passed ^ " checks passed\n")
