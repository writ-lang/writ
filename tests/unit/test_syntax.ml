(* Front-end (core/syntax) unit tests. Stdlib only, no framework: each [check]
   counts a pass or aborts with a located message.

   Coverage: [Reader.split_dots]; form collection rejecting self/forward
   references and accepting an earlier-only template; the expander rewriting a
   toggle-like form to two transitions and expanding nullary + [&rest] forms; a
   read→expand→parse round-trip producing the expected [Model.t]; a mistyped
   path surfacing through the parser with a [line:col]; and the loader detecting
   a load cycle and rejecting a library that contains [use]. *)

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

let read_one src =
  match read_all src with [ d ] -> d | _ -> failwith "expected one datum"

(* --- Reader.split_dots ------------------------------------------------------ *)

let () =
  check "split_dots: a bare atom is a single segment"
    (Reader.split_dots "docket" = [ "docket" ]);
  check "split_dots: a dotted atom splits on '.'"
    (Reader.split_dots "docket.investigator.independence"
    = [ "docket"; "investigator"; "independence" ])

(* --- Forms.collect: hygiene -------------------------------------------------- *)

let () =
  (match
     Forms.collect (read_one "(form spiral => (and spiral))") ~earlier:[]
   with
  | Ok _ -> check "collect: a self-referencing template must be rejected" false
  | Error e ->
      check "collect: self-reference is positioned" (e.Errors.pos <> None);
      check "collect: self-reference says `recurs`"
        (contains_sub ~sub:"recurs" e.Errors.msg));
  match Forms.collect (read_one "(form a => (b))") ~earlier:[] with
  | Ok _ -> check "collect: a forward reference must be rejected" false
  | Error e ->
      check "collect: forward reference is positioned" (e.Errors.pos <> None);
      check "collect: forward reference says `not yet`"
        (contains_sub ~sub:"not yet" e.Errors.msg)

let () =
  let base =
    match
      Forms.collect
        (read_one "(form base => (is docket.stage open))")
        ~earlier:[]
    with
    | Ok fd -> fd
    | Error e -> failwith ("base form rejected: " ^ Errors.to_string e)
  in
  (match
     Forms.collect
       (read_one "(form (wrap G) => (or (base) G))")
       ~earlier:[ base ]
   with
  | Ok fd ->
      check "collect: an earlier-form template is accepted"
        (fd.Forms.name = "wrap")
  | Error e ->
      check
        ("collect: earlier form wrongly rejected: " ^ Errors.to_string e)
        false);
  match
    Forms.collect (read_one "(form (wrap G) => (or (base) G))") ~earlier:[]
  with
  | Ok _ -> check "collect: a not-yet-declared head must be rejected" false
  | Error e ->
      check "collect: unknown head says `not yet`"
        (contains_sub ~sub:"not yet" e.Errors.msg)

(* --- Expander: substitution, statement splice, nullary, &rest --------------- *)

let () =
  let src =
    "(form (toggle P A B)\n\
    \   => (transition (when (is P A)) (do (set P B)))\n\
    \      (transition (when (is P B)) (do (set P A))))\n\
     (toggle light.state on off)"
  in
  match Expander.expand (read_all src) with
  | Error e -> check ("expand toggle failed: " ^ Errors.to_string e) false
  | Ok out ->
      check "expand: a form invocation splices two datums" (List.length out = 2);
      check "expand: both are transitions"
        (List.for_all
           (function
             | Reader.List (Reader.Atom ("transition", _) :: _, _) -> true
             | _ -> false)
           out);
      check "expand: slots are substituted (P := light.state, B := off)"
        (Reader.to_string (List.nth out 0)
        = "(transition (when (is light.state on)) (do (set light.state off)))")

let () =
  match
    Expander.expand
      (read_all "(form ready => (is docket.stage open)) (and ready)")
  with
  | Ok [ d ] ->
      check "expand: a nullary form expands in expression position"
        (Reader.to_string d = "(and (is docket.stage open))")
  | Ok _ -> check "expand: nullary produced the wrong datum count" false
  | Error e -> check ("expand nullary failed: " ^ Errors.to_string e) false

let () =
  match
    Expander.expand
      (read_all
         "(form (does &rest ES) => (do @ES)) (does (set p.a x) (vacate q.b))")
  with
  | Ok [ d ] ->
      check "expand: @SLOT splices the &rest binding"
        (Reader.to_string d = "(do (set p.a x) (vacate q.b))")
  | Ok _ -> check "expand: &rest produced the wrong datum count" false
  | Error e -> check ("expand &rest failed: " ^ Errors.to_string e) false

(* --- A §7 claim-form: a SLOTTED form whose template names the form itself as a
   data atom (the [property] symbol). Invoking it must expand to the [(property
   …)] datum, NOT re-expand that bare name as a nullary invocation and fail with
   "too few arguments" (regression). And a genuine nullary self-reference is
   still rejected at collection — the recursion guard must not be weakened. *)

let () =
  let src =
    "(form (accountability C)\n\
    \   => (property accountability \"reachable\" (live (is C.stage \
     concluded))))\n\
     (accountability docket)"
  in
  match Expander.expand (read_all src) with
  | Ok [ d ] ->
      check "expand: a claim-form's self-named property atom stays as data"
        (Reader.to_string d
       = "(property accountability reachable (live (is docket.stage \
          concluded)))")
  | Ok _ -> check "expand: claim-form produced the wrong datum count" false
  | Error e ->
      check
        ("expand claim-form failed (the §7 expander bug): " ^ e.Errors.msg)
        false

let () =
  match
    Forms.collect (read_one "(form spiral => (and spiral))") ~earlier:[]
  with
  | Ok _ -> check "collect: nullary self-reference must still be rejected" false
  | Error e ->
      check "collect: nullary self-reference still says `recurs`"
        (contains_sub ~sub:"recurs" e.Errors.msg)

(* --- Round-trip: read -> expand -> parse_model ------------------------------ *)

let model_src =
  "(schema oversight\n\
  \   (type indep-status (independent captured))\n\
  \   (type stage-t (open concluded))\n\
  \   (type bureau (arrow independence (to indep-status)))\n\
  \   (type case (arrow stage (to stage-t)) (arrow judge (to bureau) \
   vacatable)))\n\
   (instance day-one (of oversight)\n\
  \   (bureau watchdog)\n\
  \   (case docket)\n\
  \   (independence (watchdog independent))\n\
  \   (stage (docket open))\n\
  \   (judge (docket vacant)))\n\
   (use oversight)\n\
   (initial day-one)\n\
   (transition capture\n\
  \   (when (is watchdog.independence independent))\n\
  \   (do (set watchdog.independence captured)))\n\
   (transition conclude\n\
  \   (when (is docket.stage open))\n\
  \   (do (set docket.stage concluded)))"

let parse_src src =
  match Reader.read_string src with
  | Error e -> Error e
  | Ok datums -> (
      match Expander.expand datums with
      | Error e -> Error e
      | Ok expanded -> Parser.parse_model expanded)

let () =
  match parse_src model_src with
  | Error e -> check ("round-trip parse failed: " ^ Errors.to_string e) false
  | Ok m -> (
      check "parse: schema name resolved"
        (m.Model.schema.Schema.name = "oversight");
      check "parse: initial instance resolved"
        (m.Model.initial.Instance.name = "day-one");
      check "parse: two transitions" (List.length m.Model.transitions = 2);
      match m.Model.transitions with
      | t1 :: _ -> (
          check "parse: first transition is named `capture`"
            (t1.Model.name = Some "capture");
          (match t1.Model.when_ with
          | Model.Is
              ( { Value.root = "watchdog"; steps = [ "independence" ] },
                "independent" ) ->
              check "parse: guard is (is watchdog.independence independent)"
                true
          | _ -> check "parse: guard shape" false);
          match t1.Model.effects with
          | [
           Model.Set
             ( { Value.root = "watchdog"; steps = [ "independence" ] },
               "captured" );
          ] ->
              check "parse: effect is (set watchdog.independence captured)" true
          | _ -> check "parse: effect shape" false)
      | [] -> check "parse: transitions present" false)

(* --- A mistyped path surfaces through the parser with a line:col ------------ *)

let () =
  let bad =
    "(schema s (type v (a b)) (type e (arrow x (to v))))\n\
     (instance i (of s) (e n1) (x (n1 a)))\n\
     (use s) (initial i)\n\
     (transition t (when (is n1.nope a)) (do))"
  in
  match parse_src bad with
  | Ok _ -> check "parse: a mistyped path must be rejected" false
  | Error e ->
      check "parse: mistyped path is positioned (line:col)"
        (e.Errors.pos <> None);
      check "parse: error names the missing arrow"
        (contains_sub ~sub:"nope" e.Errors.msg)

(* --- An out-of-domain (set P V) is rejected with a line:col (kernel §5) ------ *)

let () =
  let bad =
    "(schema s (type flag (lo hi)) (type box (arrow f (to flag))))\n\
     (instance i (of s) (box b) (f (b lo)))\n\
     (use s) (initial i)\n\
     (transition t (when (is b.f lo)) (do (set b.f pending)))"
  in
  match parse_src bad with
  | Ok _ -> check "parse: an out-of-domain (set …) must be rejected" false
  | Error e ->
      check "parse: out-of-domain set is positioned (line:col)"
        (e.Errors.pos <> None);
      check "parse: error names the offending value and codomain"
        (contains_sub ~sub:"pending" e.Errors.msg
        && contains_sub ~sub:"flag" e.Errors.msg)

(* --- Loader: cycles and the library/model split (injected resolve) ---------- *)

let resolve_of files name : (string, Errors.t) result =
  match List.assoc_opt name files with
  | Some s -> Ok s
  | None -> Errors.err ("no such file: " ^ name)

let () =
  let files =
    [ ("a.pol", "(load \"b.pol\")"); ("b.pol", "(load \"a.pol\")") ]
  in
  match Loader.load_library (resolve_of files) "a.pol" with
  | Ok _ -> check "loader: a load cycle must be rejected" false
  | Error e ->
      check "loader: names the cycle" (contains_sub ~sub:"cycle" e.Errors.msg)

let () =
  let files = [ ("lib.pol", "(schema s (type v (a b)))\n(use s)") ] in
  match Loader.load_library (resolve_of files) "lib.pol" with
  | Ok _ -> check "loader: a library containing (use …) must be rejected" false
  | Error e ->
      check "loader: rejects a model masquerading as a library"
        (contains_sub ~sub:"declarations only" e.Errors.msg)

let () =
  print_string ("syntax tests: " ^ string_of_int !passed ^ " checks passed\n")
