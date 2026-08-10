(* Where a form may splice, and what that costs the standard library.

   [Expander] has two positions and they are not symmetric. At TOP LEVEL
   ([stmt]) a form invocation may expand to several datums — that is how
   [toggle] becomes two transitions. INSIDE a list ([expr]) it must expand to
   exactly one, because there is nowhere to put the others.

   That asymmetry is invisible until someone tries to sugar the inside of a
   declaration. The proposal was [(arrow held-by *(to job))] — some marker
   meaning "vacatable" — and its form-shaped version is
   [(form (opt T) (to T) vacatable)], a two-datum template invoked inside a
   [(type …)]. It is refused, and no form can be written that is not. Sugaring
   the inside would have to be a READER change, so stdlib §8 wraps the WHOLE
   datum instead: [(maybe A T)] is one datum in, one datum out.

   Both halves are pinned here, because the second only makes sense given the
   first. *)

open Pol_data
open Pol_syntax

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

(* 1. A two-datum template refused in expression position. The template itself
   is LEGAL — [Forms.collect] accepts it, since [to] and [vacatable] are both
   reserved words — so the refusal is the expander's, at the invocation, which
   is where a modeller would meet it. *)
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

(* 2. The same template spliced at TOP level is fine — proof that the rule is
   about position, not about two-datum templates as such. *)
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

(* 3. stdlib §8's answer: wrap the whole datum, so one goes in and one comes
   out. Read the real [maybe] out of the shipped library rather than restating
   it here — a copy would keep passing after the library changed. *)
let () =
  (* Ascend to the repo root — the nearest ancestor holding the library — the
     same walk test_data.ml does, and for the same reason: the test runs deep
     inside _build, where dune has copied core/stdlib/*.pol alongside it. *)
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.pol") then dir
    else if n = 0 then failwith "cannot find core/stdlib/stdlib.pol"
    else up (Filename.dirname dir) (n - 1)
  in
  let path = Filename.concat (up (Sys.getcwd ()) 8) "core/stdlib/stdlib.pol" in
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

(* [~open_heads] — the one relaxation, and the test that it stays confined to
   the file type that needs it.

   A template head the expander cannot resolve is a typo or a forward reference
   in a .pol or .claims file, and it stays an error there. In a .rules file it is
   a RELATION, which does not exist until the program is parsed, so the check
   rejects correct programs and catches nothing — [Loader.read_rules] opts out
   of it, and nothing else may. The same template is used both ways below, so
   the two answers differ only by the flag. *)
let () =
  let src = "(form (satisfies R G) (relation R 1) (rule (R S) (holds S G)))" in
  (match Expander.expand (read_all src) with
  | Ok _ ->
      check "a .pol file still refuses a head the expander cannot know" false
  | Error e ->
      check "the refusal names the head"
        (contains_sub ~sub:"mentions `holds`" e.Errors.msg));
  match Expander.expand ~open_heads:true (read_all src) with
  | Ok _ -> check "a .rules file accepts a rule body's relation heads" true
  | Error e ->
      check ("open_heads still refused it: " ^ Errors.to_string e) false

(* Self-recursion is NOT relaxed: it needs no vocabulary to detect, so the
   relaxation must not carry it along. *)
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
