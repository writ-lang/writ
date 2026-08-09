(* Sort inference tests (TRS): [Rules_sorts.infer], extension §3.

   These drive the checker directly. `pol derive` does not exist yet, so a unit
   test is the ONLY way to prove any of this now — and the run's fitness gates
   will exercise the same fixtures through the CLI once it does.

   Every rejection is asserted to land on an exact [line:col]. That is the whole
   reason the check lives in core/syntax: §1 asks for "an error at the
   variable", and only the parser's positioned IR can say where the variable
   was. *)

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

(* The org chart of tests/unit/fixtures/rules_base.pol: [reports-to] is fixed
   wiring, [stands] is mutable. *)
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

(* Kernel §7 scopes arrow names to their dom, and river.pol really does give
   [at] to two types — the case that makes an annotation unavoidable. *)
let amb =
  model_of
    "(schema amb (type bank (left right)) (type traveler (arrow at (to bank))) \
     (type cargo (arrow at (to bank))))\n\
     (instance i amb (traveler t1 (at left)) (cargo c1 (at left)) )\n\
     (use amb) (initial i)\n\
     (transition move (when (is t1.at left)) (do (set t1.at right)))"

let sorts_of m src =
  match Rules_parser.parse m.Model.schema (read_all src) with
  | Error e -> failwith ("parse error: " ^ Errors.to_string e)
  | Ok t -> Rules_sorts.infer m t

let rejected name m src ~line ~col ~sub =
  match sorts_of m src with
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

(* --- the fixpoint case: §1's own transitive closure -------------------------
   [Y] in the recursive rule occurs only in the head and in a sort-transparent
   relation literal, so no per-rule left-to-right pass can type it. It is typed
   by [subordinate]'s second column, which the OTHER rule teaches. This is the
   example the fixpoint exists for. *)

let () =
  let src =
    "(relation subordinate 2)\n\
     (rule (subordinate X Y) (is X.reports-to Y))\n\
     (rule (subordinate X Y) (is X.reports-to Z) (subordinate Z Y))"
  in
  match sorts_of org src with
  | Error e -> check ("closure sorts: " ^ Errors.to_string e) false
  | Ok s ->
      let col i = List.assoc_opt ("subordinate", i) s.Rules_sorts.columns in
      check "closure: both columns are person"
        (col 0 = Some (Rules.Entity "person")
        && col 1 = Some (Rules.Entity "person"));
      check "closure: the recursive rule's Y is typed across rules"
        (Rules_sorts.var_sort s 1 "Y" = Some (Rules.Entity "person"));
      check "closure: and its Z from the path's dom"
        (Rules_sorts.var_sort s 1 "Z" = Some (Rules.Entity "person"))

(* --- chain resolution, inside the fixpoint ----------------------------------
   An arrow name owned by two types seeds nothing, so the variable waits — and
   waits for ever if no other occurrence sorts it. §3's workaround is a typed
   head column, and it must actually work. *)

let () =
  rejected "ambiguous arrow: the root is not seeded" amb
    "(relation at-bank 2)\n(rule (at-bank X B) (holds S (is X.at B)))" ~line:2
    ~col:16 ~sub:"cannot be inferred";
  match
    sorts_of amb
      "(relation at-bank (cargo bank))\n\
       (rule (at-bank X B) (holds S (is X.at B)))"
  with
  | Error e -> check ("typed column rescues it: " ^ Errors.to_string e) false
  | Ok s ->
      check "ambiguous arrow: a typed head column sorts the root"
        (Rules_sorts.var_sort s 0 "X" = Some (Rules.Entity "cargo"));
      check "ambiguous arrow: and the chain then sorts the value"
        (Rules_sorts.var_sort s 0 "B" = Some (Rules.Entity "bank"));
      check "holds: S is a situation"
        (Rules_sorts.var_sort s 0 "S" = Some Rules.Situation)

(* --- a variable no seed reaches ------------------------------------------- *)

let () =
  rejected "untypeable variable" org
    "(relation p 1)\n(relation q 1)\n(rule (p X) (q X))" ~line:3 ~col:10
    ~sub:"cannot be inferred"

(* --- a conflict names BOTH occurrences ------------------------------------
   Blamed at the second, because that is the one the author is free to move;
   the first is the evidence for why they must. *)

let () =
  match
    sorts_of org
      "(relation r (person))\n(relation q (Situation))\n(rule (r X) (q X))"
  with
  | Ok _ -> check "sort conflict: expected a rejection" false
  | Error e ->
      check "sort conflict is at the second occurrence, 3:16"
        (e.Errors.pos = Some { Errors.file = None; line = 3; col = 16 });
      check "sort conflict names the first occurrence's position"
        (contains_sub ~sub:"3:10" e.Errors.msg);
      check "sort conflict names the column that forced each"
        (contains_sub ~sub:"column 1 of `q`" e.Errors.msg
        && contains_sub ~sub:"column 1 of `r`" e.Errors.msg)

(* --- a column the fixpoint never reaches ---------------------------------- *)

let () =
  rejected "unsorted column, blamed at the declaration" org
    "(relation nobody 1)" ~line:1 ~col:1 ~sub:"cannot be inferred";
  rejected "a typed column naming no schema type" org "(relation p (nosuch))"
    ~line:1 ~col:1 ~sub:"the schema does not declare"

let () =
  print_string
    ("rules sort tests: " ^ string_of_int !passed ^ " checks passed\n")
