(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Rules checking tests (TRC): [Rules_check], extension §2, §4 and §5 — the
   read-time rejections that are not sort inference (those are TRS).

   [Rules_check.check] is the only constructor of a [Rules.program], so this is
   the gate everything downstream trusts. Every program here is a string
   literal, so a case is read where it is asserted; the .rules FILES under
   tests/unit/fixtures/ — the same ones the run's fitness gates drive through
   the CLI — are exercised next door, in test_rules_fixtures.ml. *)

open Pol_data
open Pol_syntax

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

let model_of src =
  match Parser.parse_model (read_all src) with
  | Ok m -> m
  | Error e -> failwith ("model error: " ^ Errors.to_string e)

let org =
  model_of
    "(schema org (type stance (quiet vocal)) (type person (arrow reports-to \
     (to person) fixed) (arrow stands (to stance))))\n\
     (instance chart org (person nabu (reports-to mid) (stands quiet)) (person \
     mid (reports-to cabinet) (stands quiet)) (person cabinet (reports-to \
     vacant) (stands quiet)) )\n\
     (use org) (initial chart)\n\
     (transition speak (when (is nabu.stands quiet)) (do (set nabu.stands \
     vocal)))"

(* The shape of pol-problems' access: a mutable [role] under a [some] binder,
   which is the formula §8's oracle needs to be able to write. *)
let acc =
  model_of
    "(schema acc (type role-t (admin user)) (type account (arrow role (to \
     role-t))))\n\
     (instance camp acc (account a1 (role user)) (account a2 (role user)) )\n\
     (use acc) (initial camp)\n\
     (transition promote (when (is a1.role user)) (do (set a1.role admin)))"

let run m src =
  match Rules_parser.parse m.Model.schema (read_all src) with
  | Error e -> Error e
  | Ok t -> Rules_check.check m t

let accepted name m src =
  match run m src with
  | Ok _ -> check name true
  | Error e -> check (name ^ ": " ^ Errors.to_string e) false

let rejected name m src ~line ~col ~sub =
  match run m src with
  | Ok _ ->
      check (name ^ ": expected a rejection") false;
      exit 1
  | Error e ->
      check
        (name ^ " is at " ^ string_of_int line ^ ":" ^ string_of_int col
       ^ ", not " ^ Errors.to_string e)
        (e.Errors.pos = Some { Errors.file = None; line; col });
      check
        (name ^ " says `" ^ sub ^ "`, not " ^ e.Errors.msg)
        (contains_sub ~sub e.Errors.msg)

(* --- declaredness and arity ------------------------------------------------ *)

let () =
  rejected "an undeclared relation" org
    "(relation p (person))\n(rule (p X) (q X))" ~line:2 ~col:13
    ~sub:"is not a declared relation";
  rejected "an arity mismatch" org
    "(relation p (person))\n(relation q (person))\n(rule (p X) (q X X))" ~line:3
    ~col:13 ~sub:"declared with 1 column but is used with 2 columns";
  rejected "a relation declared twice" org
    "(relation p (person))\n(relation p (person))" ~line:2 ~col:1
    ~sub:"declared twice"

(* --- stratification (§5) --------------------------------------------------- *)

(* The blame lands on ONE [(not …)] and names the WHOLE cycle: several negative
   links may lie on it, and removing any one of them fixes it, so the message
   must not present the site it points at as the only repair. *)
let () =
  match
    run org
      "(relation p (person))\n\
       (relation q (person))\n\
       (rule (p X) (is X.reports-to Y) (not (q X)))\n\
       (rule (q X) (p X))"
  with
  | Ok _ -> check "negation cycle: expected a rejection" false
  | Error e ->
      check "negation cycle is blamed at the (not …), 3:33"
        (e.Errors.pos = Some { Errors.file = None; line = 3; col = 33 });
      check "negation cycle names the whole cycle"
        (contains_sub ~sub:"negation cycle: `p` → `q` → `p`" e.Errors.msg);
      check "negation cycle does not claim one site is the fix"
        (contains_sub ~sub:"removing any one of them" e.Errors.msg)

(* Recursion WITHOUT negation is the point of the engine, and must survive. *)
let () =
  accepted "transitive closure is stratified" org
    "(relation subordinate 2)\n\
     (rule (subordinate X Y) (is X.reports-to Y))\n\
     (rule (subordinate X Y) (is X.reports-to Z) (subordinate Z Y))"

(* --- range restriction (§4) ------------------------------------------------ *)

let () =
  rejected "a negated literal is not a generator" org
    "(relation r (person))\n(relation q (person))\n(rule (r X) (not (q X)))"
    ~line:3 ~col:21 ~sub:"not bound by any earlier literal";
  rejected "an unbound head variable" org
    "(relation r (person person))\n(relation q (person))\n(rule (r X Y) (q X))"
    ~line:3 ~col:12 ~sub:"is in the head but is not bound by the body";
  (* Written order governs CONJUNCTS too: only the second conjunct would bind
     [X], and the first already needs it. *)
  rejected "a conjunct that needs what a later conjunct would bind" org
    "(relation p (person person))\n\
     (rule (p X Y) (and (not (is X.reports-to mid)) (is X.reports-to Y)))"
    ~line:2 ~col:29 ~sub:"not bound by any earlier literal";
  (* Reordered, the same two conjuncts are fine — which is what makes the
     rejection actionable rather than a wall. *)
  accepted "the same conjuncts, reordered" org
    "(relation p (person person))\n\
     (rule (p X Y) (and (is X.reports-to Y) (not (is X.reports-to mid))))";
  (* [holds] never generates situations. *)
  rejected "holds with an unbound situation" org
    "(relation p (Situation))\n(rule (p S) (holds S (is nabu.reports-to mid)))"
    ~line:2 ~col:20 ~sub:"not bound by any earlier literal"

(* [(holds S (is X.a Y))] with X bound IS a binding literal for Y — the thing
   that makes §2's reversal usable rather than notional. [Y] is put in the HEAD
   so that only the [holds] literal can possibly bind it, and the same rule with
   that literal removed is the control. *)
let () =
  accepted "holds binds through its guard" org
    "(relation p (Situation person stance))\n\
     (rule (p S X Y) (situation S) (is X.reports-to mid) (holds S (is X.stands \
     Y)))";
  rejected "…and nothing else in that rule could have" org
    "(relation p (Situation person stance))\n\
     (rule (p S X Y) (situation S) (is X.reports-to mid))"
    ~line:2 ~col:14 ~sub:"is in the head but is not bound by the body"

(* --- paths (§2): fixed arrows, and the exemption inside holds -------------- *)

let () =
  match run org "(relation p (person))\n(rule (p X) (is X.stands quiet))" with
  | Ok _ -> check "bare guard over a mutable arrow: expected a rejection" false
  | Error e ->
      check "a bare mutable arrow is blamed at the path, 2:17"
        (e.Errors.pos = Some { Errors.file = None; line = 2; col = 17 });
      (* The fix has to be named, or the message is a dead end. *)
      check "and the message names the fix that exists"
        (contains_sub ~sub:"holds" e.Errors.msg)

let () =
  accepted "the same guard inside (holds S …)" org
    "(relation p (Situation))\n\
     (rule (p S) (situation S) (holds S (is nabu.stands quiet)))";
  accepted "a bare guard over a fixed arrow" org
    "(relation p (person person))\n(rule (p X Y) (is X.reports-to Y))";
  rejected "a path step the schema has no arrow for" org
    "(relation p (person))\n(rule (p X) (is X.reports-to Y) (is X.nope Y))"
    ~line:2 ~col:37 ~sub:"has no arrow `nope`";
  rejected "a value outside the codomain" org
    "(relation p (Situation))\n\
     (rule (p S) (situation S) (holds S (is nabu.stands loud)))"
    ~line:2 ~col:52 ~sub:"not in codomain `stance`"

(* A constant does not seed a sort, but once its column has one it is checked
   against it: a constant that cannot inhabit its column names a row that can
   never exist, and the silence would otherwise read as an answer. *)
let () =
  rejected "a constant outside its entity column" org
    "(relation p (person))\n(rule (p bogus) (situation S))" ~line:2 ~col:10
    ~sub:"is not an entity of `person`";
  rejected "a non-index constant in a situation column" org
    "(relation p (Situation))\n(rule (p nabu) (situation S))" ~line:2 ~col:10
    ~sub:"is not a situation";
  accepted "a situation index is a bare non-negative integer" org
    "(relation p (Situation))\n(rule (p 0) (init S))"

(* A BUILT-IN's columns are sorted by §3 itself, per position, with no fixpoint
   to wait for — so they are the sharpest-sorted positions in the language and
   the easiest place to hide a typo. One case per built-in, because the sorts
   are a table and a table is exactly the thing that acquires a hole: the whole
   family went unchecked while the user-relation cases above passed. *)
let () =
  rejected "a non-index constant in situation's column" org
    "(relation p (Situation))\n(rule (p S) (situation S) (situation nabu))"
    ~line:2 ~col:38
    ~sub:
      "is not a situation, which is what column 1 of built-in `situation` takes";
  rejected "a non-index constant in init's column" org
    "(relation p (Situation))\n(rule (p S) (situation S) (init nabu))" ~line:2
    ~col:33 ~sub:"is not a situation, which is what column 1 of built-in `init`";
  rejected "a non-transition constant in edge's edge column" org
    "(relation p (Situation))\n(rule (p S) (edge no-such-move S T))" ~line:2
    ~col:19 ~sub:"is not an edge, which is what column 1 of built-in `edge`";
  rejected "a non-index constant in edge's target column" org
    "(relation p (Situation))\n(rule (p S) (edge speak S nabu))" ~line:2 ~col:27
    ~sub:"is not a situation, which is what column 3 of built-in `edge`";
  rejected "a non-transition constant in gap-edge's edge column" org
    "(relation p (Situation))\n(rule (p S) (gap-edge no-such-move S))" ~line:2
    ~col:23 ~sub:"is not an edge, which is what column 1 of built-in `gap-edge`";
  rejected "a non-index constant in holds's situation column" org
    "(relation p (Situation))\n\
     (rule (p S) (situation S) (holds nabu (is nabu.stands quiet)))"
    ~line:2 ~col:34
    ~sub:"is not a situation, which is what column 1 of built-in `holds`";
  (* The control: the same built-ins with constants that DO inhabit their
     columns. G is not one of them — it is a non-term position (§3), so the
     entity name inside it is checked as a guard path, not as a column. *)
  accepted "constants that inhabit their built-in columns" org
    "(relation p (Situation))\n\
     (rule (p S) (edge speak 0 S) (holds 0 (is nabu.stands quiet)))"

(* A kernel [some] binder is not a rule variable: it is bound by the
   quantifier and scoped to its own guard body, so §4's "must already be bound"
   does not reach it. Without that reading this formula — the one at
   pol-problems access/access.claims:13 — would be rejected. *)
let () =
  accepted "a some binder under a negation inside holds" acc
    "(relation quiet-day (Situation))\n\
     (rule (quiet-day S) (situation S) (holds S (not (some (a account) (is \
     a.role admin)))))"

let () =
  print_string
    ("rules check tests: " ^ string_of_int !passed ^ " checks passed\n")
