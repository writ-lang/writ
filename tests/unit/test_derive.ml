(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Derivation tests: [Facts] and [Derive] (extension §1, §2). Expected rows are
   counted by hand: rules_base.writ wires nabu → mid → cabinet, four
   situations, four edges. *)

open Writ_data
open Writ_syntax
open Writ_runtime

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let fixture name =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.writ") then dir
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
  match Derive_answers.sorts_of d rel with
  | Some ss -> List.length ss
  | None -> failwith ("no relation `" ^ rel ^ "`")

let rows d rel args =
  match Derive_answers.query d rel args with
  | Some (Ok rs) -> List.sort compare (List.map (Derive_answers.row d rel) rs)
  | Some (Error (i, _)) ->
      failwith
        (rel ^ ": argument " ^ string_of_int i ^ " cannot inhabit its column")
  | None -> failwith ("no relation `" ^ rel ^ "`")

let all d rel = rows d rel (List.init (arity d rel) (fun _ -> None))
let base = model_file "rules_base.writ"
let base_sp = space base
let closure = Derive.run base_sp (program base "closure.rules")
let reach = Derive.run base_sp (program base "space.rules")

(* ── The specification's own transitive closure ──────────────────────────── *)

(* cabinet's vacant cell derives nothing: three rows. *)
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
  (* A pair not in the relation is an answer; an atom no roster holds is a
     mis-asked question. *)
  check "a row that does not hold is an empty answer"
    (rows closure "subordinate" [ Some "cabinet"; Some "nabu" ] = []);
  check "an atom no roster holds is reported, not answered empty"
    (match Derive_answers.query closure "subordinate" [ Some "nope"; None ] with
    | Some (Error (0, Rules.Entity "person")) -> true
    | _ -> false)

(* ── An empty relation is an answer ──────────────────────────────────────── *)

let () =
  let d = Derive.run base_sp (program base "rules_empty.rules") in
  check "a declared relation with no rules derives the empty set"
    (Derive_answers.query d "nobody" [ None ] = Some (Ok []));
  check "…which is not the same as an undeclared one"
    (Derive_answers.query d "no-such-relation" [ None ] = None)

(* ── Recursion over the derived category ─────────────────────────────────── *)

(* Four reflexive rows, four steps, and 0 → 3. *)
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

(* A looping graph strains the acyclicity check at the end. *)
let cycle_m = model_file "cycle.writ"
let cycle_sp = space cycle_m
let cycle = Derive.run cycle_sp (program cycle_m "space.rules")

let () =
  check "the toggle's two situations reach each other both ways"
    (all cycle "edge" = [ [ "down"; "1"; "0" ]; [ "up"; "0"; "1" ] ]);
  check "so reach over a cyclic space is the full square"
    (all cycle "reach" = pairs [ (0, 0); (0, 1); (1, 0); (1, 1) ])

(* ── Negation sees a COMPLETED stratum ───────────────────────────────────── *)

(* The only two-step chain is a `subordinate` fact once recursion has closed,
   so an empty `skipped` shows negation saw the finished stratum. *)
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

(* Answer sets would not notice a cyclic derivation, but `--why` would loop. *)
let fact_ids d =
  List.concat_map
    (fun rel -> List.filter_map (Derive_answers.fact_id d rel) (all d rel))
    (Derive_answers.relations d)

let rec above d seen id =
  match Derive_answers.derivation d id with
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

(* ── Demand: one question, one cone ──────────────────────────────────────── *)

(* [~only] changes cost, never the answer: pruning to `want` keeps `dep` and
   the negative premise `neg`, and drops `spare`. *)
let demand_src =
  "(relation dep 1)\n\
   (rule (dep S) (situation S))\n\
   (relation neg 1)\n\
   (rule (neg S) (init S))\n\
   (relation want 1)\n\
   (rule (want S) (dep S) (not (neg S)))\n\
   (relation spare 2)\n\
   (rule (spare S T) (edge E S T))\n"

let () =
  let prog () = program_of base demand_src in
  let full = Derive.run base_sp (prog ()) in
  let only = Derive.run ~only:"want" base_sp (prog ()) in
  check "pruned and unpruned agree on the relation that was asked for"
    (all only "want" = all full "want");
  check "…and the answer is the three situations that are not the initial one"
    (all only "want" = [ [ "1" ]; [ "2" ]; [ "3" ] ]);
  check "a relation reached only through `not` is still computed"
    (Derive_answers.sorts_of only "neg" <> None && all only "neg" = [ [ "0" ] ]);
  check "a positive dependency is still computed"
    (Derive_answers.sorts_of only "dep" <> None);
  check "a relation nothing asked for is not computed at all"
    (Derive_answers.sorts_of only "spare" = None
    && Derive_answers.sorts_of full "spare" <> None);
  (* Built-ins are seeded before any stratum. *)
  let b = Derive.run ~only:"edge" base_sp (prog ()) in
  check "a built-in can be the question, with no user relation computed"
    (all b "edge" = all full "edge" && Derive_answers.sorts_of b "want" = None)

(* (is P Q) with a path on each side: the kernel's chain-against-chain test,
   which [holds] answers per situation. b.x and b.y are each no or yes, so
   they agree in two of the four situations. *)
let () =
  let m = model_file "is_path.writ" in
  let d = Derive.run (space m) (program m "is_path.rules") in
  check "is path path: the rows are the situations where the paths agree"
    (List.length (all d "same") = 2);
  check "is path path: two paths that can never agree are refused"
    (match
       Rules_parser.parse m.Model.schema
         (read
            "(relation odd (Situation))\n\
             (rule (odd S) (situation S) (holds S (is b.x b.z)))")
     with
    | Error _ -> true
    | Ok t -> Result.is_error (Rules_check.check m t))

let () =
  print_string ("derive tests: " ^ string_of_int !passed ^ " checks passed\n")
