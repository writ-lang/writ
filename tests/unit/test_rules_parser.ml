(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* .rules front-end tests (TRP): [Rules_parser] and [Loader.read_rules].

   The parser decodes and rejects shapes; it infers nothing. So these tests read
   datums and look at the values that come back, and — for the rejections —
   check that the diagnostic carries a [line:col], because "an error at the
   variable" is the whole reason the positioned guard mirror exists.

   The fixtures are read from disk rather than inlined: extension §1's example
   is a file the run's gates also use, and a private copy would not rot with
   it. *)

open Writ_data
open Writ_syntax

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

let read_all src =
  match Reader.read_string src with
  | Ok ds -> ds
  | Error e -> failwith ("read error: " ^ Errors.to_string e)

let read_one src =
  match read_all src with [ d ] -> d | _ -> failwith "expected one datum"

let schema_of src =
  match Decl.decode_schema (read_one src) with
  | Ok s -> s
  | Error e -> failwith ("schema error: " ^ Errors.to_string e)

(* The org chart of tests/unit/fixtures/rules_base.writ. *)
let org =
  schema_of
    "(schema org (type stance (quiet vocal)) (type person (arrow reports-to \
     (to person) fixed) (arrow stands (to stance))))"

let ok name src =
  match Rules_parser.parse org (read_all src) with
  | Ok t -> t
  | Error e ->
      check (name ^ ": " ^ Errors.to_string e) false;
      exit 1

(* Every rejection must be locatable: a message with no position has nowhere to
   put a squiggle, and lands on line 1 — usually a comment. *)
let rejected name ~sub ?schema src =
  let s = match schema with Some s -> s | None -> org in
  match Rules_parser.parse s (read_all src) with
  | Ok _ ->
      check (name ^ ": expected a rejection") false;
      exit 1
  | Error e ->
      check (name ^ " is positioned") (e.Errors.pos <> None);
      check (name ^ " says `" ^ sub ^ "`") (contains_sub ~sub e.Errors.msg)

(* --- the fixtures, through the loader --------------------------------------- *)
let repo_root () =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.writ") then dir
    else if n = 0 then dir
    else up (Filename.dirname dir) (n - 1)
  in
  up (Sys.getcwd ()) 8

let resolve : Loader.resolve =
 fun name ->
  let p = Filename.concat (repo_root ()) ("tests/unit/fixtures/" ^ name) in
  match open_in_bin p with
  | exception Sys_error _ ->
      Error { Errors.pos = None; msg = "cannot resolve " ^ name }
  | ic ->
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      Ok s

(* Extension §1's own example, verbatim in the fixture, read the way the CLI
   will read it: loads inlined, forms expanded, then parsed. *)
let () =
  let m =
    match Loader.read_model resolve "rules_base.writ" with
    | Ok m -> m
    | Error e -> failwith ("read_model: " ^ Errors.to_string e)
  in
  match Loader.read_rules resolve m "closure.rules" with
  | Error e -> check ("read_rules closure.rules: " ^ Errors.to_string e) false
  | Ok { Rules_parser.relations; rules } -> (
      (match relations with
      | [ { Rules.rel_name = "subordinate"; cols = Rules.Arity 2; _ } ] ->
          check "read_rules: (relation subordinate 2)" true
      | _ -> check "read_rules: (relation subordinate 2)" false);
      match rules with
      | [ base; step ] -> (
          check "read_rules: two rules, numbered in order"
            (base.Rules.id = 0 && step.Rules.id = 1);
          check "read_rules: heads are the declared relation"
            (base.Rules.head = "subordinate" && step.Rules.head = "subordinate");
          (match base.Rules.head_args with
          | [ Rules.Var ("X", _); Rules.Var ("Y", _) ] ->
              check "read_rules: ALL-CAPS head args are variables" true
          | _ -> check "read_rules: ALL-CAPS head args are variables" false);
          (match base.Rules.body with
          | [ Rules.Guard (Rules.Is (p, Rules.Var ("Y", _)), _) ] ->
              check "read_rules: the base case is a bare guard literal"
                (p.Rules.steps |> List.map fst = [ "reports-to" ])
          | _ -> check "read_rules: the base case is a bare guard literal" false);
          match step.Rules.body with
          | [
           Rules.Guard (Rules.Is (_, Rules.Var ("Z", _)), _);
           Rules.Pos_rel
             ("subordinate", [ Rules.Var ("Z", _); Rules.Var ("Y", _) ], _);
          ] ->
              check "read_rules: the recursive body keeps its written order"
                true
          | _ ->
              check "read_rules: the recursive body keeps its written order"
                false)
      | _ -> check "read_rules: closure.rules holds two rules" false)

(* --- relation declarations --------------------------------------------------- *)
let () =
  (match
     (ok "arity form" "(relation subordinate 2)").Rules_parser.relations
   with
  | [ { Rules.cols = Rules.Arity 2; _ } ] ->
      check "relation: (relation N 2) is an arity" true
  | _ -> check "relation: (relation N 2) is an arity" false);
  match
    (ok "typed form" "(relation subordinate (person person))")
      .Rules_parser.relations
  with
  | [
   {
     Rules.cols = Rules.Sorts [ Rules.Entity "person"; Rules.Entity "person" ];
     _;
   };
  ] ->
      check "relation: (relation N (person person)) is two entity columns" true
  | _ ->
      check "relation: (relation N (person person)) is two entity columns" false

(* The sort words are capitalised; a lowercase [edge] is the stdlib quiver's
   schema type, and the two must not be confused. *)
let () =
  match
    (ok "sort words" "(relation r (Situation Edge edge))")
      .Rules_parser.relations
  with
  | [
   {
     Rules.cols =
       Rules.Sorts [ Rules.Situation; Rules.Edge; Rules.Entity "edge" ];
     _;
   };
  ] ->
      check "relation: Situation/Edge are sorts, edge is a schema type" true
  | _ -> check "relation: Situation/Edge are sorts, edge is a schema type" false

let () =
  rejected "relation: arity 0" ~sub:"at least one column" "(relation nobody 0)";
  rejected "relation: an empty column list" ~sub:"at least one column"
    "(relation nobody ())";
  rejected "relation: a built-in cannot be redeclared" ~sub:"built-in"
    "(relation edge 3)";
  rejected "relation: a malformed declaration" ~sub:"malformed relation"
    "(relation subordinate)"

(* A schema type spelled exactly like a sort word: the sort word wins, so the
   type would be silently unreachable. Rejected at the declaration. *)
let () =
  let odd = schema_of "(schema odd (type Situation (a b)))" in
  rejected "relation: a schema type named Situation" ~sub:"rename the type"
    ~schema:odd "(relation r (Situation))"

(* --- rules and body literals ------------------------------------------------ *)
let () =
  rejected "rule: a head must be applied" ~sub:"rule head"
    "(rule subordinate (p X))";
  rejected "rule: a body is required" ~sub:"malformed rule"
    "(rule (subordinate X Y))";
  rejected "rule: a built-in cannot be a head" ~sub:"cannot define"
    "(rule (edge E S1 S2) (p E))";
  rejected "rule: a bare atom is not a literal" ~sub:"bare atom"
    "(rule (subordinate X Y) X)";
  rejected "built-in: edge takes three arguments" ~sub:"(edge E S1 S2)"
    "(rule (p S) (edge E S))";
  rejected "built-in: gap-edge takes two" ~sub:"(gap-edge E S)"
    "(rule (p S) (gap-edge E S1 S2))";
  rejected "built-in: situation takes one" ~sub:"(situation S)"
    "(rule (p S) (situation S T))";
  rejected "built-in: phase takes two" ~sub:"(phase S P)"
    "(rule (p S) (phase S))";
  rejected "built-in: phase-step takes two" ~sub:"(phase-step P Q)"
    "(rule (p P) (phase-step P Q R))";
  (* The quotient is the interrogator's to compute, like every other reading of
     the derived category — extension §5 again, at the two newest names. *)
  rejected "relation: phase cannot be redeclared" ~sub:"built-in"
    "(relation phase 2)";
  rejected "rule: phase-step cannot be a head" ~sub:"cannot define"
    "(rule (phase-step P Q) (p P))"

let () =
  (* G is a datum, never a term: a variable there would otherwise reach the
     fixpoint as a joinable column. *)
  rejected "holds: a variable in the G position" ~sub:"guard datum"
    "(rule (p S) (situation S) (holds S G))";
  (* a stepless path would be an accidental equality primitive *)
  rejected "guard: a stepless path" ~sub:"at least one arrow"
    "(rule (p X) (is X Y))";
  (* an ALL-CAPS binder would shadow the kernel's own, which Writ forbids *)
  rejected "guard: an ALL-CAPS some binder" ~sub:"no shadowing"
    "(rule (p X) (holds S (some (A person) (is A.stands quiet))))"

(* Both built-ins and negation, decoded into the shapes the engine reads. *)
let () =
  let t =
    ok "mixed body"
      "(rule (stuck S) (situation S) (not (moves S)) (holds S (is nabu.stands \
       quiet)))"
  in
  match t.Rules_parser.rules with
  | [ { Rules.body = [ b1; b2; b3 ]; _ } ] -> (
      (match b1 with
      | Rules.Built_in (Rules.Situation_ (Rules.Var ("S", _)), _) ->
          check "body: (situation S) is a built-in" true
      | _ -> check "body: (situation S) is a built-in" false);
      (match b2 with
      | Rules.Neg_rel ("moves", [ Rules.Var ("S", _) ], _) ->
          check "body: (not (R …)) is a negated relation" true
      | _ -> check "body: (not (R …)) is a negated relation" false);
      match b3 with
      | Rules.Built_in
          ( Rules.Holds
              (Rules.Var ("S", _), Rules.Is (_, Rules.Const ("quiet", _))),
            _ ) ->
          check "body: (holds S G) carries a guard datum" true
      | _ -> check "body: (holds S G) carries a guard datum" false)
  | _ -> check "body: three literals" false

(* [(not (is …))] is a negated GUARD; [(not (R …))] a negated relation. The
   inner head is what tells them apart. *)
let () =
  let t = ok "negated guard" "(rule (p X) (not (is X.stands quiet)))" in
  match t.Rules_parser.rules with
  | [ { Rules.body = [ Rules.Guard (Rules.Not (Rules.Is _, _), _) ]; _ } ] ->
      check "body: (not (is …)) is a negated guard" true
  | _ -> check "body: (not (is …)) is a negated guard" false

(* --- positions survive decoding ---------------------------------------------
   The point of the positioned mirror: every part of a guard can be blamed where
   it was written. The source below puts the guard on line 2, the path atom at
   column 7 and the value at column 20. *)

let () =
  let src = "(rule (p X)\n  (is X.reports-to Y))" in
  let t = ok "positions" src in
  match t.Rules_parser.rules with
  | [ { Rules.body = [ Rules.Guard (Rules.Is (p, v), lp) ]; _ } ] -> (
      check "positions: the literal is at 2:3"
        (lp = { Errors.file = None; line = 2; col = 3 });
      check "positions: the path is at 2:7"
        (p.Rules.pos = { Errors.file = None; line = 2; col = 7 });
      (match p.Rules.root with
      | Rules.Var ("X", rp) ->
          check "positions: the path root is at 2:7"
            (rp = { Errors.file = None; line = 2; col = 7 })
      | _ -> check "positions: the path root is a variable" false);
      (match p.Rules.steps with
      | [ ("reports-to", sp) ] ->
          check "positions: the step is blamed at the path"
            (sp = { Errors.file = None; line = 2; col = 7 })
      | _ -> check "positions: one step" false);
      match v with
      | Rules.Var ("Y", vp) ->
          check "positions: the value variable is at 2:20"
            (vp = { Errors.file = None; line = 2; col = 20 })
      | _ -> check "positions: the value is a variable" false)
  | _ -> check "positions: one guard literal" false

let () =
  (* declarations a loaded library brought in are skipped, not rejected *)
  let t =
    ok "library declarations"
      "(schema s (type t (a b)))\n(instance i s)\n(relation p 1)"
  in
  check "parse: schema/instance declarations are skipped"
    (List.length t.Rules_parser.relations = 1 && t.Rules_parser.rules = []);
  rejected "parse: an unknown declaration" ~sub:"unknown rules declaration"
    "(property p \"t\" (live (is b.f lo)))"

let () =
  print_string
    ("rules parser tests: " ^ string_of_int !passed ^ " checks passed\n")
