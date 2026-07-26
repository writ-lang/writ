(* The law-as-guard change, end to end: a chain may appear on the right of
   [is] (§10.2), and an [equation] holds a guard rather than only [(= A B)]
   (§8.6), which is what lets `=` leave the kernel for the standard library.

   Same shape as test_names.ml, from which the helpers are borrowed: a source
   string, the real reader / expander / parser, and the exact line:col of a
   rejection. Its own suite because the 300-line cap leaves no room in
   test_syntax.ml, and because these cases are one change rather than a
   scattering. *)

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

let decodes src =
  match Reader.read_string src with
  | Error e -> Error e
  | Ok ds -> (
      match Expander.expand ds with
      | Error e -> Error e
      | Ok ex -> Parser.parse_model ex)

let rejects name src ~sub =
  match decodes src with
  | Ok _ -> check (name ^ " — accepted, but must be rejected") false
  | Error e -> check name (contains_sub ~sub e.Errors.msg)

let accepts name src =
  match decodes src with
  | Ok _ -> check name true
  | Error e -> check (name ^ " — rejected: " ^ Errors.to_string e) false

(* Two people and one case wired to both, so a comparison between the two
   arrows has something to compare. [approver] is mutable so a move can write
   it; [preparer] is wiring. *)
let office body =
  "(schema office\n\
  \   (type person)\n\
  \   (type stage-t (open closed))\n\
  \   (type case\n\
  \     (arrow preparer (to person) fixed)\n\
  \     (arrow stage (to stage-t))\n\
  \     (arrow approver (to person))))\n\
   (instance i (of office)\n\
  \   (person ann bob)\n\
  \   (case c)\n\
  \   (preparer (c ann))\n\
  \   (stage (c open))\n\
  \   (approver (c bob)))\n\
   (use office)\n\
   (initial i)\n" ^ body

(* --- §10.2: a chain on the right of [is] ---------------------------------- *)

let () =
  accepts "a guard may compare two chains"
    (office
       "(transition t (when (is c.approver c.preparer)) (do (set c.stage \
        closed)))");
  (* The literal reading is what every guard written before this used, and it
     is decided lexically: [ann] has no dot, so it is still a literal. *)
  accepts "a literal right side still reads as a literal"
    (office
       "(transition t (when (is c.approver ann)) (do (set c.stage closed)))");
  (* Comparing cells of different types is not a guard that is merely never
     true — it is an error, or the author gets a move that silently never
     fires. *)
  rejects "two chains must land in one type"
    (office
       "(transition t (when (is c.approver c.stage)) (do (set c.stage closed)))")
    ~sub:"comparing two chains needs a single target type"

(* Strictness, both sides. §10.2 says a chain "has an answer and it equals V";
   with a chain on the right that has to hold of the right too, or `is` would
   quietly acquire `=`'s Kleene reading and the two would stop being distinct.
   With [approver] vacant, the comparison is FALSE, so the move is not enabled
   and the space stays at one situation. *)
let () =
  let src =
    "(schema office\n\
    \   (type person)\n\
    \   (type case\n\
    \     (arrow preparer (to person) fixed)\n\
    \     (arrow approver (to person) vacatable)))\n\
     (instance i (of office)\n\
    \   (person ann)\n\
    \   (case c)\n\
    \   (preparer (c ann))\n\
    \   (approver (c vacant)))\n\
     (use office)\n\
     (initial i)\n\
     (transition t (when (is c.approver c.preparer)) (do (set c.approver ann)))"
  in
  match decodes src with
  | Error e -> check ("vacant-side model rejected: " ^ Errors.to_string e) false
  | Ok m -> (
      match Pol_runtime.Space.build m with
      | Error e -> check ("vacant-side build failed: " ^ e) false
      | Ok sp ->
          check "an undefined side makes the comparison false, not vacuous"
            (Array.length sp.Pol_runtime.Space.states = 1))

(* --- §8.6: an equation holds a guard ------------------------------------- *)

(* The law that motivated the change: separation of duty, unwritable before
   because the language had no way to say two cells differ. It is a LAW, not a
   rule, which is the whole point — §15 analyses it for breakage and §16.3 lets
   the breakage be acknowledged. *)
let () =
  accepts "a law may be any guard, including a difference"
    "(form (differ A B) => (not (is A B)))\n\
     (schema office\n\
    \   (type person)\n\
    \   (type case\n\
    \     (arrow preparer (to person) fixed)\n\
    \     (arrow approver (to person)))\n\
    \   (equation sod (differ case.approver case.preparer)))\n\
     (instance i (of office)\n\
    \   (person ann bob) (case c) (preparer (c ann)) (approver (c bob)))\n\
     (use office) (initial i)";
  (* The stdlib spelling of the kernel word that left: Kleene equality out of
     strict primitives. The spec's own §4 law, unchanged, must still decode. *)
  accepts "`=` as a form still reads the spec's own law"
    "(form (= A B) => (not (and (defined A) (defined B) (not (is A B)))))\n\
     (schema oversight\n\
    \   (type indep-status (independent captured))\n\
    \   (type bureau (arrow independence (to indep-status)))\n\
    \   (type case\n\
    \     (arrow investigator (to bureau) fixed)\n\
    \     (arrow prosecutor (to bureau) fixed))\n\
    \   (equation same-agency\n\
    \     (= case.investigator.independence case.prosecutor.independence)))\n\
     (instance day-one (of oversight)\n\
    \   (bureau watchdog prosecutions) (case docket)\n\
    \   (investigator (docket watchdog)) (prosecutor (docket prosecutions))\n\
    \   (independence (watchdog independent) (prosecutions independent)))\n\
     (use oversight) (initial day-one)"

(* §8.6 gives a law one subject. Two free roots and there is no single type for
   the implicit quantification to range over — the reading that makes
   `case.investigator…` mean "for every case" in the first place. *)
let () =
  rejects "a law may not range over two types"
    "(schema office\n\
    \   (type person (arrow boss (to person) fixed))\n\
    \   (type case (arrow approver (to person)))\n\
    \   (equation confused (is case.approver person.boss)))\n\
     (instance i (of office) (person ann) (case c) (boss (ann ann)) (approver \
     (c ann)))\n\
     (use office) (initial i)"
    ~sub:"ranges over two types";
  rejects "a law's subject must be a declared type"
    "(schema office\n\
    \   (type person)\n\
    \   (type case (arrow approver (to person)))\n\
    \   (equation nosuch (defined nothere.approver)))\n\
     (instance i (of office) (person ann) (case c) (approver (c ann)))\n\
     (use office) (initial i)"
    ~sub:"is not a declared type"

(* `=` is no longer a kernel word, so it must no longer be reserved against
   form names — otherwise the stdlib form that replaces it cannot be declared. *)
let () =
  check "`=` is free for a form to define" (not (Forms.is_reserved "="));
  check "`equation` is still reserved" (Forms.is_reserved "equation")

let () =
  print_string
    ("law-as-guard tests: " ^ string_of_int !passed ^ " checks passed\n")
