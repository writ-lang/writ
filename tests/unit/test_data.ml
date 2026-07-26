(* Data tests (TC): the .pol standard library, the political domain library, and
   the worked model load + parse through the real front end.

   IO is fine here (this is tests/unit, not the engine libraries): [resolve] mimics the CLI search
   path — a filename is looked up in core/stdlib/ first, then in the model's directory.
   The repo root is found by ascending from the cwd until core/stdlib/stdlib.pol is seen,
   so the test runs the same under `dune exec` (cwd = root) and `dune runtest`
   (cwd = the build dir). *)

open Pol_data
open Pol_syntax
open Pol_runtime

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(* Ascend from the cwd to the repo root — the nearest ancestor holding
   core/stdlib/stdlib.pol. *)
let repo_root () =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.pol") then dir
    else if n = 0 then dir
    else up (Filename.dirname dir) (n - 1)
  in
  up (Sys.getcwd ()) 8

let resolve : Loader.resolve =
 fun name ->
  let root = repo_root () in
  let candidates =
    [
      Filename.concat root ("core/stdlib/" ^ name);
      Filename.concat root ("tests/models/" ^ name);
      Filename.concat root ("tests/unit/fixtures/" ^ name);
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some p -> Ok (read_file p)
  | None -> Errors.err ("no such file: " ^ name)

(* The stdlib and the domain library both parse as libraries. *)
let () =
  (match Loader.load_library resolve "stdlib.pol" with
  | Ok _ -> check "load_library: stdlib.pol parses" true
  | Error e -> check ("load_library stdlib.pol: " ^ Errors.to_string e) false);
  match Loader.load_library resolve "politics.lib.pol" with
  | Ok _ -> check "load_library: politics.lib.pol parses" true
  | Error e ->
      check ("load_library politics.lib.pol: " ^ Errors.to_string e) false

(* The worked model loads (stdlib + politics.lib), expands, and parses. *)
let () =
  match Loader.read_model resolve "tests/models/any_model.pol" with
  | Error e -> check ("read_model any_model.pol: " ^ Errors.to_string e) false
  | Ok m -> (
      (* The transcription yields 18 transitions: bill-cycle 4, case-pipeline 2,
         swing 2, captured-by ×2, restored-by ×2, declare/lift/gap emergency 3,
         support erode ×2 + recover 1. *)
      check "read_model: 18 transitions" (List.length m.Model.transitions = 18);
      let sets_bill =
        List.exists
          (fun (t : Model.transition) ->
            List.exists
              (function
                | Model.Set ({ Value.root = "gov"; steps = [ "bill" ] }, _) ->
                    true
                | _ -> false)
              t.Model.effects)
          m.Model.transitions
      in
      check "read_model: a bill-cycle move writes gov.bill" sets_bill;
      let captures =
        List.exists
          (fun (t : Model.transition) ->
            match (t.Model.when_, t.Model.effects) with
            | ( Model.Is
                  ( { Value.root = "watchdog"; steps = [ "independence" ] },
                    Model.Lit "independent" ),
                [ Model.Set (_, "captured") ] ) ->
                true
            | _ -> false)
          m.Model.transitions
      in
      check "read_model: a captured-by move is present (watchdog)" captures;
      match State.build_ctx m.Model.schema m.Model.initial with
      | Ok (_, st) ->
          check "build_ctx: day-one is well-formed (8 mutable cells)"
            (Array.length st = 8)
      | Error e -> check ("build_ctx: " ^ e) false)

(* An END-TO-END n/a (kernel §8): a property whose path names an arrow the schema
   lacks is n/a through the REAL loader/parser — not a parse error. Before the
   fix, parse-time path type-checking of property formulas rejected the unknown
   arrow outright (exit 2); now only the SHAPE is decoded and arrow resolution is
   deferred to [Checker.check], which returns [Not_applicable] (exit 0). *)
let () =
  match Loader.read_model resolve "na.pol" with
  | Error e -> check ("read_model na.pol: " ^ Errors.to_string e) false
  | Ok m -> (
      match Space.build m with
      | Error e -> check ("space na.pol: " ^ e) false
      | Ok sp -> (
          match Loader.read_claims resolve m "na.claims" with
          | Error e ->
              check
                ("read_claims na.claims (must not parse-error): "
               ^ Errors.to_string e)
                false
          | Ok cl -> (
              match cl.Claims.props with
              | [ p ] ->
                  let oc = Checker.check sp p in
                  (match oc with
                  | Checker.Not_applicable _ ->
                      check "na: an unknown-arrow property is n/a" true
                  | _ -> check "na: unknown-arrow property must be n/a" false);
                  let r = Report.outcome sp p oc in
                  check "na: the report prints the n/a token"
                    (String.length r >= 3 && String.sub r 0 3 = "n/a")
              | _ -> check "na: expected exactly one property" false)))

(* The many-to-many form is `span`, and `relation` belongs to the .rules file
   type. Both halves are checked against the REAL stdlib, expanded by the real
   expander, because the collision they guard against was invisible to a test
   that transcribed the form instead of loading it: one expander serves every
   file type, so a stdlib form named `relation` rewrites a rules declaration. *)

let rec sexp (d : Reader.t) =
  match d with
  | Reader.Atom (a, _) -> a
  | Reader.List (xs, _) -> "(" ^ String.concat " " (List.map sexp xs) ^ ")"

let () =
  match Loader.load_library resolve "stdlib.pol" with
  | Error e -> check ("stdlib for span: " ^ Errors.to_string e) false
  | Ok lib ->
      let expand src =
        match Reader.read_string src with
        | Error e -> failwith ("read: " ^ Errors.to_string e)
        | Ok ds -> (
            match Expander.expand (lib @ ds) with
            | Error e -> failwith ("expand: " ^ Errors.to_string e)
            | Ok out -> List.map sexp out)
      in
      check "span: expands to a junction type with two fixed arrows"
        (List.mem
           "(type link (arrow left (to a) fixed) (arrow right (to b) fixed))"
           (expand "(span link a b)"));
      check "relation: a rules declaration survives the stdlib untouched"
        (List.mem "(relation subordinate 2)"
           (expand "(relation subordinate 2)"))

(* …and no library may take either word back by declaring a form of that name. *)
let () =
  List.iter
    (fun w ->
      let src = "(form (" ^ w ^ " X) => (type X))" in
      match Reader.read_string src with
      | Ok [ d ] -> (
          match Forms.collect d ~earlier:[] with
          | Ok _ -> check ("a form may not be named `" ^ w ^ "`") false
          | Error e ->
              check
                ("a form named `" ^ w ^ "` is refused as reserved: "
               ^ e.Errors.msg)
                (String.length e.Errors.msg > 0
                && e.Errors.pos <> None
                && List.exists
                     (fun s -> s = "reserved")
                     (String.split_on_char ' ' e.Errors.msg)))
      | _ -> check ("unreadable test source for `" ^ w ^ "`") false)
    [ "relation"; "rule" ]

let contains_sub ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

(* Cross-FILE is the case that bites in practice: neither file holds a duplicate
   on its own, so the check has to run over the loaded universe (§6.2), after
   inlining — which is why it lives in [Parser.collect_decls] and not in [Decl].
   Uses the real loader and the real stdlib rather than a hand-built pair. *)
let () =
  let src =
    "(load \"stdlib.pol\")\n\
     (schema m (type hom (a b)))\n\
     (instance i (of m))\n\
     (use m)\n\
     (initial i)"
  in
  let files = [ ("dup.pol", src) ] in
  let resolve name =
    match List.assoc_opt name files with Some s -> Ok s | None -> resolve name
  in
  match Loader.read_model resolve "dup.pol" with
  | Ok _ ->
      check "a model may not redeclare a type the loaded stdlib declares" false
  | Error e ->
      check "a model may not redeclare a type the loaded stdlib declares"
        (contains_sub ~sub:"`hom` is already declared" e.Errors.msg
        && e.Errors.pos <> None)

let () =
  print_string ("data tests: " ^ string_of_int !passed ^ " checks passed\n")
