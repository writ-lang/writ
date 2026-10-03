(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* At top level a form invocation may expand to several datums; inside a list
   it must expand to exactly one. So stdlib §8 wraps a whole datum,
   [(maybe A T)], rather than sugaring inside a declaration. *)

open Writ_data
open Writ_syntax

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let read_all src =
  match Reader.read_string ~file:"t" src with
  | Ok ds -> ds
  | Error e -> failwith (Errors.to_string e)

let contains_sub ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

(* 1. A two-datum template is refused at the invocation in expression
   position. *)
let () =
  let src =
    "(form (opt T) (to T) vacatable)\n\
     (schema shop (type job (j1 j2)) (type machine (arrow held-by (opt job))))"
  in
  match Expander.expand (read_all src) with
  | Ok _ -> check "a two-datum template inside a list must be refused" false
  | Error e ->
      let m = Errors.to_string e in
      check "the refusal names the form and says one datum is required"
        (contains_sub ~sub:"opt" m && contains_sub ~sub:"several datums" m);
      check "the refusal carries a position (it is blamed at the invocation)"
        (e.Errors.pos <> None)

(* 2. The same template at top level is fine. *)
let () =
  let src =
    "(form (pair A B) (schema A (type t)) (instance B A))\n(pair s i)"
  in
  match Expander.expand (read_all src) with
  | Ok [ a; b ] ->
      check "the same shape splices at top level"
        (Reader.to_string a = "(schema s (type t))"
        && Reader.to_string b = "(instance i s)")
  | Ok ds ->
      check
        ("top-level splice produced "
        ^ string_of_int (List.length ds)
        ^ " datums, expected 2")
        false
  | Error e -> check ("top-level splice failed: " ^ Errors.to_string e) false

(* 3. stdlib §8's [maybe], read from the shipped library. *)
let () =
  (* Walk up to the repo root: the test runs inside _build. *)
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.writ") then dir
    else if n = 0 then failwith "cannot find core/stdlib/stdlib.writ"
    else up (Filename.dirname dir) (n - 1)
  in
  let path = Filename.concat (up (Sys.getcwd ()) 8) "core/stdlib/stdlib.writ" in
  let src = In_channel.with_open_text path In_channel.input_all in
  let has_maybe =
    List.exists
      (function
        | Reader.List
            ( Reader.Atom ("form", _)
              :: Reader.List (Reader.Atom ("maybe", _) :: _, _)
              :: _,
              _ ) ->
            true
        | _ -> false)
      (read_all src)
  in
  check "stdlib declares (maybe A T)" has_maybe;
  match
    Expander.expand
      (read_all (src ^ "\n(schema s (type t (a b)) (type u (maybe f t)))"))
  with
  | Ok ds -> (
      let last = List.nth ds (List.length ds - 1) in
      match last with
      | Reader.List (Reader.Atom ("schema", _) :: _, _) ->
          check "(maybe f t) expands to a vacatable arrow, in place"
            (Reader.to_string last
           = "(schema s (type t (a b)) (type u (arrow f (to t) vacatable)))")
      | _ -> check "the schema survived expansion as a schema" false)
  | Error e -> check ("expanding maybe failed: " ^ Errors.to_string e) false

(* [~open_heads] is for .rules only, where a template head may be a relation
   not yet parsed; elsewhere it is a typo. *)
let () =
  let src = "(form (satisfies R G) (relation R 1) (rule (R S) (holds S G)))" in
  (match Expander.expand (read_all src) with
  | Ok _ ->
      check "a .writ file still refuses a head the expander cannot know" false
  | Error e ->
      check "the refusal names the head"
        (contains_sub ~sub:"mentions `holds`" e.Errors.msg));
  match Expander.expand ~open_heads:true (read_all src) with
  | Ok _ -> check "a .rules file accepts a rule body's relation heads" true
  | Error e ->
      check ("open_heads still refused it: " ^ Errors.to_string e) false

(* Self-recursion is not relaxed: it needs no vocabulary to detect. *)
let () =
  let src = "(form (loop A) (loop A))" in
  match Expander.expand ~open_heads:true (read_all src) with
  | Ok _ -> check "open_heads must not admit a recursive template" false
  | Error e ->
      check "recursion is still refused under open_heads"
        (contains_sub ~sub:"recurses" e.Errors.msg)

let () =
  print_string
    ("forms-position tests: " ^ string_of_int !passed ^ " checks passed\n")
