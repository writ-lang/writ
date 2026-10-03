(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* A failure, made actionable: a stable code, where, what was found and what
   could have been meant, one imperative hint, and a corrected line when the
   mistake is a misspelt name.

   The engine's diagnostics are prose with a position. Codes are assigned
   here, by message, rather than at the ~160 places that raise them: the
   table below is the one place to look, and test_mcp runs every code's
   wrong example to prove the message still maps to it. *)

open Writ_data
open Writ_syntax

(* ── the codes ───────────────────────────────────────────────────────────── *)

(* What an example is written against: a whole model, claims or rules for
   [base], or a tool call. *)
type example =
  | Model of string
  | Claims of string
  | Rules of string
  | Call of string

type entry = {
  code : string;
  cause : string;
  hint : string;
  wrong : example;
  right : example;
}

(* Every example below is checked by test_mcp: [wrong] must produce [code],
   [right] must validate. *)
let base =
  "(load \"stdlib.writ\")\n\
   (schema shop\n\
  \  (type stage-t (queued running done))\n\
  \  (type job (arrow stage (to stage-t))))\n\
   (instance start shop (job a) (stage (a queued)))\n\
   (use shop)\n\
   (initial start)\n\
   (transition begin (when (is a.stage queued)) (do (set a.stage running)))\n\
   (transition finish (when (is a.stage running)) (do (set a.stage done)))\n"

(* [src] with each [from] replaced by its [into], once. *)
let replace (src : string) (edits : (string * string) list) =
  List.fold_left
    (fun src (from, into) ->
      let n = String.length from and l = String.length src in
      let rec at i =
        if i + n > l then invalid_arg ("Diagnose.replace: " ^ from)
        else if String.sub src i n = from then i
        else at (i + 1)
      in
      let i = at 0 in
      String.sub src 0 i ^ into ^ String.sub src (i + n) (l - i - n))
    src edits

let edit ~from ~into = replace base [ (from, into) ]

(* [base] with a second enumerated type, for a mismatch to have two sides. *)
let flagged =
  replace base
    [
      ( "(type job (arrow stage (to stage-t))))",
        "(type flag (no yes))\n\
        \  (type job (arrow stage (to stage-t)) (arrow urgent (to flag))))" );
      ("(stage (a queued))", "(stage (a queued)) (urgent (a no))");
    ]

let begin_ =
  "(transition begin (when (is a.stage queued)) (do (set a.stage running)))"

let codes : entry list =
  [
    {
      code = "E_PAREN";
      cause = "A list is never closed, or a `)` closes nothing.";
      hint = "Balance the parentheses of the form at the position given.";
      wrong =
        Model
          (edit ~from:begin_
             ~into:(String.sub begin_ 0 (String.length begin_ - 1)));
      right = Model base;
    };
    {
      code = "E_LOAD";
      cause =
        "A `(load \"FILE\")` form names a file that cannot be found, loads \
         itself, or loads a file that is not a library (it holds use, initial \
         or transition). A path argument that is missing is E_FILE_NOT_FOUND \
         instead.";
      hint =
        "Check the name in (load …): it is looked up beside the including \
         file, then on the library path, where stdlib.writ always is. A loaded \
         file may hold declarations only.";
      wrong = Model (edit ~from:"stdlib.writ" ~into:"stdlb.writ");
      right = Model base;
    };
    {
      code = "E_UNKNOWN_FORM";
      cause =
        "A guard's head is neither a kernel word (and or not is defined some) \
         nor a declared form. There is no implicit prelude: `all`, `differ` \
         and the rest come from `(load \"stdlib.writ\")`.";
      hint = "Use a kernel guard word, or load or declare the form first.";
      wrong =
        Model
          (edit ~from:"(when (is a.stage queued))"
             ~into:"(when (equals a.stage queued))");
      right = Model base;
    };
    {
      code = "E_UNKNOWN_ARROW";
      cause =
        "A chain follows an arrow the type at that point does not declare.";
      hint = "Use an arrow declared on the type the chain has reached.";
      wrong =
        Model
          (edit ~from:"(when (is a.stage queued))"
             ~into:"(when (is a.stauts queued))");
      right = Model base;
    };
    {
      code = "E_UNKNOWN_ENTITY";
      cause =
        "A chain starts at a name that is not an entity of the instance or a \
         variable bound by `some`/`all`/`where`.";
      hint = "Start the chain at an entity the instance declares.";
      wrong =
        Model
          (edit ~from:"(when (is a.stage queued))"
             ~into:"(when (is b.stage queued))");
      right = Model base;
    };
    {
      code = "E_UNKNOWN_VALUE";
      cause =
        "A value is not in the type the arrow points to (a misspelt enum \
         value, or an entity of the wrong type).";
      hint = "Use a value of the arrow's codomain type.";
      wrong =
        Model (edit ~from:"(set a.stage running)" ~into:"(set a.stage runing)");
      right = Model base;
    };
    {
      code = "E_UNKNOWN_TYPE";
      cause =
        "A type name is used that the schema does not declare: an arrow's `(to \
         TYPE)`, an instance clause, or a binder.";
      hint = "Use a type the schema declares, or declare it.";
      wrong = Model (edit ~from:"(to stage-t)" ~into:"(to stage)");
      right = Model base;
    };
    {
      code = "E_UNKNOWN_DECL";
      cause =
        "A top-level datum or a clause inside one is not a word of its file \
         type. A model has load schema instance form use initial transition; a \
         claims file property query accept load form; a rules file relation \
         rule load form.";
      hint = "Spell the declaration as the grammar for this file type has it.";
      wrong = Model (edit ~from:"(transition finish" ~into:"(transtion finish");
      right = Model base;
    };
    {
      code = "E_UNKNOWN_MODALITY";
      cause =
        "A property's formula is not headed by possible, never, live or \
         inevitable. There is no `always`: always P is `(never (not P))`.";
      hint = "Head the formula with possible, never, live or inevitable.";
      wrong =
        Claims "(property ok \"never stuck\" (always (is a.stage done)))\n";
      right =
        Claims "(property ok \"always done\" (never (not (is a.stage done))))\n";
    };
    {
      code = "E_UNKNOWN_NAME";
      cause =
        "`(use …)` or `(initial …)` names a schema or instance that is not \
         declared.";
      hint =
        "Name the schema in (use …) and the instance in (initial …) exactly.";
      wrong = Model (edit ~from:"(use shop)" ~into:"(use shp)");
      right = Model base;
    };
    {
      code = "E_UNKNOWN_QUERY";
      cause =
        "A `(show …)` clause or a writ_query call names a query the claims \
         file lacks.";
      hint = "Name a query declared in the same claims file.";
      wrong =
        Claims
          "(query where (where (j job)) (is j.stage done))\n\
           (property ok \"it can finish\" (possible (is a.stage done)) (show \
           wher))\n";
      right =
        Claims
          "(query where (where (j job)) (is j.stage done))\n\
           (property ok \"it can finish\" (possible (is a.stage done)) (show \
           where))\n";
    };
    {
      code = "E_UNKNOWN_RELATION";
      cause =
        "A rule uses a relation that is neither declared with (relation …) nor \
         built in.";
      hint = "Declare the relation with (relation NAME ARITY) before using it.";
      wrong =
        Rules
          "(relation done 1)\n\
           (rule (done S) (situation S) (holds S (is a.stage done)) (finished \
           S))\n";
      right =
        Rules
          "(relation done 1)\n\
           (rule (done S) (situation S) (holds S (is a.stage done)))\n";
    };
    {
      code = "E_UNKNOWN_MOVE";
      cause =
        "A `(fair …)` names a move the model does not have. Fairness names \
         transitions, so every move it names needs a name in the model.";
      hint = "Name a transition the model declares (writ_validate lists them).";
      wrong =
        Claims
          "(property done \"it finishes\" (inevitable (is a.stage done) (fair \
           finsh)))\n";
      right =
        Claims
          "(property done \"it finishes\" (inevitable (is a.stage done) (fair \
           finish)))\n";
    };
    {
      code = "E_DUPLICATE";
      cause =
        "A name is declared twice where it must be fresh: a transition, a \
         type, a value, a form.";
      hint = "Rename one of the two declarations.";
      wrong = Model (edit ~from:"(transition finish" ~into:"(transition begin");
      right = Model base;
    };
    {
      code = "E_MISSING";
      cause =
        "A required part is absent: a model needs exactly one (use SCHEMA) and \
         one (initial INSTANCE); a transition needs one (when GUARD).";
      hint = "Add the missing declaration.";
      wrong = Model (edit ~from:"(initial start)\n" ~into:"");
      right = Model base;
    };
    {
      code = "E_FIXED";
      cause =
        "A move writes an arrow declared `fixed` (wiring, which no move may \
         change).";
      hint = "Drop `fixed` from the arrow, or stop writing it.";
      wrong =
        Model
          (edit ~from:"(arrow stage (to stage-t))"
             ~into:"(arrow stage (to stage-t) fixed)");
      right = Model base;
    };
    {
      code = "E_NOT_VACATABLE";
      cause =
        "A move vacates an arrow not declared `vacatable`; only those may be \
         empty.";
      hint = "Declare the arrow `vacatable`, or set it to a value instead.";
      wrong =
        Model
          (edit ~from:"(do (set a.stage done))" ~into:"(do (vacate a.stage))");
      right =
        Model
          (replace base
             [
               ( "(arrow stage (to stage-t))",
                 "(arrow stage (to stage-t) vacatable)" );
               ("(do (set a.stage done))", "(do (vacate a.stage))");
             ]);
    };
    {
      code = "E_UNSET_CELL";
      cause =
        "The instance leaves a cell without a value: a fixed arrow, or a \
         mutable arrow that is not vacatable.";
      hint =
        "Give every entity a value for every non-vacatable arrow in the \
         instance.";
      wrong = Model (edit ~from:"(job a) (stage (a queued))" ~into:"(job a)");
      right = Model base;
    };
    {
      code = "E_TYPE_MISMATCH";
      cause =
        "The two sides of a comparison or assignment land in different types.";
      hint = "Compare or assign a value of the type the chain lands in.";
      wrong =
        Model
          (replace flagged
             [ ("(set a.stage running)", "(set a.stage a.urgent)") ]);
      right = Model flagged;
    };
    {
      code = "E_FORM";
      cause =
        "A form is invoked with the wrong number of arguments, recurses, or \
         its template mentions a name that is not a blank (a form cannot \
         introduce a bound variable).";
      hint =
        "Match the form's pattern exactly, and pass binders in as parameters.";
      wrong =
        Model
          (replace base
             [
               ("(use shop)", "(form (at J S) (is J.stage S))\n(use shop)");
               ("(when (is a.stage queued))", "(when (at a))");
             ]);
      right = Model base;
    };
    {
      code = "E_RULES";
      cause =
        "A rules program cannot be evaluated: recursion through negation, a \
         negated built-in, or a variable not bound by a positive literal.";
      hint =
        "Negate only declared relations, and never on a cycle back to the head.";
      wrong = Rules "(relation p 1)\n(rule (p S) (situation S) (not (p S)))\n";
      right =
        Rules
          "(relation p 1)\n\
           (rule (p S) (situation S) (holds S (is a.stage done)))\n";
    };
    {
      code = "E_MALFORMED";
      cause =
        "A declaration has the wrong shape. A property needs a description \
         string: (property NAME \"TEXT\" FORMULA); a query has none: (query \
         NAME (where (x TYPE)…) GUARD).";
      hint =
        "Rewrite the datum in the shape syntax.model / syntax.claims gives.";
      wrong = Claims "(property ok (possible (is a.stage done)))\n";
      right =
        Claims "(property ok \"it can finish\" (possible (is a.stage done)))\n";
    };
    {
      code = "E_STATE_LIMIT";
      cause =
        "The space grew past max_situations (or timeout_ms) before the search \
         finished. Nothing is decided on a partial space.";
      hint =
        "Shrink the model: fewer entities, smaller enums, a short ladder for \
         any counter, and no cell the questions do not read.";
      wrong = Call "writ_check({model_source: …, max_situations: 2})";
      right = Call "writ_check({model_source: …})";
    };
    {
      code = "E_FILE_NOT_FOUND";
      cause =
        "A `model`, `claims` or `rules` path argument names no readable file. \
         The message gives the path it resolved to: paths are read on the \
         server, relative to its working directory.";
      hint =
        "Check the path, or pass the text as model_source (claims_source, \
         rules_source).";
      wrong = Call "writ_check({model: \"probe-does-not-exist.writ\"})";
      right = Call "writ_check({model_source: \"(schema …) …\"})";
    };
    {
      code = "E_NOT_CHECKED";
      cause =
        "Claims and rules are typed against the model, so while the model has \
         errors they are not read at all. This is not a verdict on them.";
      hint =
        "Fix the model's errors, then validate again: the claims are checked \
         then.";
      wrong =
        Call "writ_validate({model_source: <with errors>, claims_source: …})";
      right = Call "writ_validate({model_source: <valid>, claims_source: …})";
    };
    {
      code = "E_NO_SITUATION";
      cause =
        "An index is out of range. Indices are positions in this model's space \
         only.";
      hint = "Use an index the last writ_check of this exact source printed.";
      wrong = Call "writ_show({model_source: …, at: [99]})";
      right = Call "writ_show({model_source: …, at: [1]})";
    };
    {
      code = "E_ARG_CONFLICT";
      cause =
        "An argument was given both as a path and as inline source, or as \
         neither.";
      hint =
        "Pass exactly one of `model` or `model_source` (likewise claims, \
         rules).";
      wrong = Call "writ_check({model: \"m.writ\", model_source: \"…\"})";
      right = Call "writ_check({model_source: \"…\"})";
    };
    {
      code = "E_ARG_INVALID";
      cause =
        "A required argument is missing, has the wrong type, or is out of \
         range.";
      hint =
        "Pass the arguments the tool's input schema lists, with their types.";
      wrong = Call "writ_query({model_source: \"…\"})";
      right =
        Call
          "writ_query({model_source: \"…\", claims_source: \"…\", name: \
           \"where\"})";
    };
    {
      code = "E_SOURCE_TOO_LARGE";
      cause = "An inline source is over 256 KB.";
      hint =
        "Shrink the source or pass a path; a model that large will not check \
         in time anyway.";
      wrong = Call "writ_check({model_source: <300 KB>})";
      right = Call "writ_check({model: \"big.writ\"})";
    };
    {
      code = "E_CLAIMS_PINNED";
      cause =
        "The server pins claims (--claims-dir), so inline claims are refused: \
         the questions are the human's, not the agent's.";
      hint = "Pass `claims` as a path; its basename picks the pinned file.";
      wrong = Call "writ_check({model_source: \"…\", claims_source: \"…\"})";
      right = Call "writ_check({model_source: \"…\", claims: \"shop.claims\"})";
    };
    {
      code = "E_OTHER";
      cause =
        "A failure no other code describes; the message is the engine's own.";
      hint = "Read the message; it names the construct and the rule it breaks.";
      wrong = Call "—";
      right = Call "—";
    };
  ]

let entry code = List.find_opt (fun e -> e.code = code) codes

(* ── classification ──────────────────────────────────────────────────────── *)

let contains ~sub s =
  let ls = String.length s and n = String.length sub in
  let rec go i = i + n <= ls && (String.sub s i n = sub || go (i + 1)) in
  go 0

(* First match wins, so the specific patterns come before the general. *)
let table =
  [
    ("E_LOAD", [ "cannot resolve load"; "load cycle"; "declarations only" ]);
    ( "E_PAREN",
      [ "parenthes"; "unterminated"; "unexpected `)`"; "unexpected )" ] );
    ("E_UNKNOWN_MODALITY", [ "unknown modality" ]);
    ( "E_UNKNOWN_FORM",
      [ "unknown guard"; "a form not yet declared"; "nullary form" ] );
    ("E_UNKNOWN_ARROW", [ "has no arrow" ]);
    ("E_UNKNOWN_ENTITY", [ "unknown entity or variable"; "names no entity" ]);
    ( "E_UNKNOWN_VALUE",
      [ "not in codomain"; "value out of domain"; "is not a value" ] );
    ( "E_UNKNOWN_NAME",
      [
        "names unknown schema";
        "names unknown instance";
        "refers to unknown schema";
      ] );
    ("E_UNKNOWN_QUERY", [ "names no query"; "no query named" ]);
    ("E_UNKNOWN_MOVE", [ "no move named" ]);
    ( "E_UNKNOWN_RELATION",
      [
        "is not a declared relation";
        "no relation named";
        "not a declared relation";
      ] );
    ( "E_UNKNOWN_TYPE",
      [
        "undeclared type";
        "is not a declared type";
        "not a type the schema declares";
        "not a type or arrow of the schema";
      ] );
    ( "E_UNKNOWN_DECL",
      [
        "unknown top-level declaration";
        "unknown schema clause";
        "unknown claims declaration";
        "unknown rules declaration";
        "unknown arrow clause";
        "unknown transition clause";
      ] );
    ( "E_DUPLICATE",
      [
        "already declared";
        "declared twice";
        "is already a value";
        "collides with";
      ] );
    ("E_FIXED", [ "is fixed, so" ]);
    ("E_NOT_VACATABLE", [ "is not vacatable, so" ]);
    ("E_UNSET_CELL", [ "has no value"; " unset" ]);
    ( "E_TYPE_MISMATCH",
      [
        "lands in `";
        "comparing two chains";
        "but is used with";
        "ranges over two types";
        "is not an equality test";
      ] );
    ( "E_FORM",
      [
        "form invocation";
        "recurses";
        "expansion exceeded";
        "&rest";
        "form pattern";
        "template of";
        "expands to several";
        "does not match the invocation";
        "structural form";
      ] );
    ( "E_RULES",
      [
        "stratified";
        "negation cycle";
        "cannot be negated";
        "built-in relation";
        "built in and a rule";
        "is not bound";
        "unsafe";
      ] );
    ("E_MISSING", [ "needs one"; "needs a ("; "needs at least" ]);
    ("E_NO_SITUATION", [ "no situation " ]);
    ("E_MALFORMED", [ "malformed"; "expected "; "exactly one"; "empty " ]);
  ]

let classify (f : Fault.t) : string =
  match f.code with
  | Some c -> c
  | None -> (
      let msg = f.err.Errors.msg in
      match
        List.find_opt
          (fun (_, subs) -> List.exists (fun sub -> contains ~sub msg) subs)
          table
      with
      | Some (c, _) -> c
      | None -> "E_OTHER")

(* ── what the sources declare, read lexically ────────────────────────────
   Lexical so it works when the parse failed: the names a did-you-mean can
   offer. A form call inside a type body, (maybe held-by job), is read as
   declaring its second atom as an arrow, which is what stdlib's do. *)

type symbols = {
  mutable types : string list;
  mutable arrows : (string * string) list;  (** type, arrow *)
  mutable values : (string * string) list;  (** enumerated type, value *)
  mutable entities : (string * string) list;  (** open type, entity *)
  mutable forms : string list;
  mutable moves : string list;
  mutable schemas : string list;
  mutable instances : string list;
  mutable queries : string list;
  mutable relations : string list;
}

let harvest ~(read : string -> string option) (files : string list) : symbols =
  let s =
    {
      types = [];
      arrows = [];
      values = [];
      entities = [];
      forms = [];
      moves = [];
      schemas = [];
      instances = [];
      queries = [];
      relations = [];
    }
  in
  let seen = Hashtbl.create 8 in
  let atom = function Reader.Atom (a, _) -> Some a | _ -> None in
  (* A type body: (v1 v2 …) enumerates values, (arrow A …) declares an
     arrow, and a form call (F A …) — stdlib's (maybe A T) — declares A. *)
  let type_body ty items =
    List.iter
      (function
        | Reader.List (Reader.Atom ("arrow", _) :: Reader.Atom (a, _) :: _, _)
          ->
            s.arrows <- (ty, a) :: s.arrows
        | Reader.List (Reader.Atom (f, _) :: Reader.Atom (a, _) :: _, _)
          when List.mem f s.forms ->
            s.arrows <- (ty, a) :: s.arrows
        | Reader.List (vs, _) when List.for_all (fun d -> atom d <> None) vs ->
            List.iter
              (fun v ->
                Option.iter (fun v -> s.values <- (ty, v) :: s.values) (atom v))
              vs
        | _ -> ())
      items
  in
  let rec walk file =
    if not (Hashtbl.mem seen file) then begin
      Hashtbl.add seen file ();
      match Option.map (Reader.read_string ~file) (read file) with
      | Some (Ok ds) -> List.iter top ds
      | _ -> ()
    end
  and top d =
    match d with
    | Reader.List (Reader.Atom ("load", p) :: Reader.Atom (f, _) :: _, _) ->
        (* relative to the including file, as the loader searches *)
        let dir =
          match p.Errors.file with
          | Some inc -> Filename.dirname inc
          | None -> "."
        in
        walk (if dir = "." then f else Filename.concat dir f)
    | Reader.List (Reader.Atom ("schema", _) :: Reader.Atom (n, _) :: items, _)
      ->
        s.schemas <- n :: s.schemas;
        List.iter top items
    | Reader.List (Reader.Atom ("type", _) :: Reader.Atom (n, _) :: items, _) ->
        s.types <- n :: s.types;
        type_body n items
    | Reader.List
        (Reader.Atom ("instance", _) :: Reader.Atom (n, _) :: _ :: clauses, _)
      ->
        s.instances <- n :: s.instances;
        List.iter
          (function
            | Reader.List (Reader.Atom (ty, _) :: items, _) ->
                List.iter
                  (function
                    | Reader.Atom (e, _) -> s.entities <- (ty, e) :: s.entities
                    | _ -> ())
                  items
            | _ -> ())
          clauses
    | Reader.List
        ( Reader.Atom ("form", _)
          :: Reader.List (Reader.Atom (n, _) :: _, _)
          :: _,
          _ )
    | Reader.List (Reader.Atom ("form", _) :: Reader.Atom (n, _) :: _, _) ->
        s.forms <- n :: s.forms
    | Reader.List (Reader.Atom ("transition", _) :: Reader.Atom (n, _) :: _, _)
      ->
        s.moves <- n :: s.moves
    | Reader.List (Reader.Atom ("query", _) :: Reader.Atom (n, _) :: _, _) ->
        s.queries <- n :: s.queries
    | Reader.List (Reader.Atom ("relation", _) :: Reader.Atom (n, _) :: _, _) ->
        s.relations <- n :: s.relations
    | _ -> ()
  in
  List.iter walk files;
  s

(* ── did you mean ────────────────────────────────────────────────────────── *)

let distance a b =
  let la = String.length a and lb = String.length b in
  let d = Array.make_matrix (la + 1) (lb + 1) 0 in
  for i = 0 to la do
    d.(i).(0) <- i
  done;
  for j = 0 to lb do
    d.(0).(j) <- j
  done;
  for i = 1 to la do
    for j = 1 to lb do
      let c = if a.[i - 1] = b.[j - 1] then 0 else 1 in
      d.(i).(j) <-
        min (min (d.(i - 1).(j) + 1) (d.(i).(j - 1) + 1)) (d.(i - 1).(j - 1) + c);
      if i > 1 && j > 1 && a.[i - 1] = b.[j - 2] && a.[i - 2] = b.[j - 1] then
        d.(i).(j) <- min d.(i).(j) (d.(i - 2).(j - 2) + 1)
    done
  done;
  d.(la).(lb)

let uniq xs = List.sort_uniq compare xs

(* Candidates nearest first; [best] only when it is plausibly a typo. *)
let rank found cands =
  let cands = uniq (List.filter (fun c -> c <> found) cands) in
  let scored = List.map (fun c -> (distance found c, c)) cands in
  let sorted = List.stable_sort (fun (a, _) (b, _) -> compare a b) scored in
  let best =
    match sorted with
    | (d, c) :: _ when d <= max 1 (min 3 (String.length found / 3)) -> Some c
    | _ -> None
  in
  (List.map snd sorted, best)

let backticked msg =
  let rec go i acc =
    match String.index_from_opt msg i '`' with
    | None -> List.rev acc
    | Some a -> (
        match String.index_from_opt msg (a + 1) '`' with
        | None -> List.rev acc
        | Some b -> go (b + 1) (String.sub msg (a + 1) (b - a - 1) :: acc))
  in
  go 0 []

let words msg = String.split_on_char ' ' msg |> List.filter (( <> ) "")

let rec after w = function
  | x :: y :: _ when x = w -> Some y
  | _ :: rest -> after w rest
  | [] -> None

(* What a modality from another logic is in Writ's four. *)
let synonyms =
  [
    ( "always",
      "There is no `always`: write `(never (not P))` for \"P always holds\"." );
    ( "globally",
      "There is no `globally`: write `(never (not P))` for \"P always holds\"."
    );
    ("invariant", "There is no `invariant`: write `(never (not P))`.");
    ( "eventually",
      "There is no `eventually`: write `(inevitable P)` for \"every run \
       reaches P\", or `(possible P)` for \"some run can\"." );
    ( "finally",
      "There is no `finally`: write `(inevitable P)` for \"every run reaches \
       P\"." );
    ( "exists",
      "There is no `exists`: write `(possible P)` for \"some reachable \
       situation has P\"." );
    ("reachable", "Write `(possible P)` for \"P is reachable\".");
    ("recoverable", "Write `(live P)` for \"P can always still be reached\".");
  ]

let arithmetic =
  [
    "+";
    "-";
    "*";
    "/";
    "<";
    ">";
    "<=";
    ">=";
    "inc";
    "dec";
    "succ";
    "add";
    "sum";
    "count";
    "int";
    "integer";
    "nat";
    "number";
  ]

let kernel_guards = [ "and"; "or"; "not"; "is"; "defined"; "some" ]
let modalities = [ "possible"; "never"; "live"; "inevitable" ]

let decl_words = function
  | Fault.Model ->
      [
        "load";
        "schema";
        "instance";
        "form";
        "use";
        "initial";
        "transition";
        "when";
        "do";
        "type";
        "arrow";
        "equation";
      ]
  | Fault.Claims -> [ "load"; "form"; "property"; "query"; "accept" ]
  | Fault.Rules -> [ "load"; "form"; "relation"; "rule" ]
  | Fault.Args -> []

(* found, and every name that would have been legal there. *)
let found_and_expected (sym : symbols) (f : Fault.t) code :
    (string * string list) option =
  let msg = f.err.Errors.msg in
  let bt = backticked msg in
  let first = match bt with x :: _ -> Some x | [] -> None in
  let of_type ty =
    List.filter_map (fun (t, v) -> if t = ty then Some v else None)
  in
  let values_of ty = of_type ty sym.values @ of_type ty sym.entities in
  let with_ found cands = Option.map (fun x -> (x, cands)) found in
  match code with
  | "E_UNKNOWN_ARROW" -> (
      match bt with
      | [ ty; a ] ->
          let own =
            List.filter_map
              (fun (t, x) -> if t = ty then Some x else None)
              sym.arrows
          in
          Some (a, if own <> [] then own else List.map snd sym.arrows)
      | _ -> None)
  | "E_UNKNOWN_ENTITY" -> with_ first (List.map snd sym.entities)
  | "E_UNKNOWN_VALUE" -> (
      let ws = words msg in
      match (after "value" ws, after "codomain" ws) with
      | Some v, Some ty -> Some (v, values_of ty)
      | _ -> None)
  | "E_UNKNOWN_TYPE" ->
      let found =
        match bt with
        | [ _; t ] when contains ~sub:"undeclared type" msg -> Some t
        | x :: _ -> Some x
        | [] -> None
      in
      with_ found
        (if contains ~sub:"or arrow" msg then
           sym.types @ List.map snd sym.arrows
         else sym.types)
  | "E_UNKNOWN_FORM" ->
      (* "template of `F` mentions `X`": X is what is unknown *)
      let found =
        match bt with
        | [ _; x ] when contains ~sub:"mentions" msg -> Some x
        | _ -> first
      in
      with_ found (kernel_guards @ sym.forms)
  | "E_UNKNOWN_MOVE" -> with_ first sym.moves
  | "E_UNKNOWN_MODALITY" -> with_ first modalities
  | "E_UNKNOWN_DECL" -> with_ first (decl_words f.source)
  | "E_UNKNOWN_NAME" ->
      with_ first
        (if contains ~sub:"instance" msg then sym.instances else sym.schemas)
  | "E_UNKNOWN_QUERY" ->
      (* "(show wher) names no query in this file": the name is not ticked *)
      let found =
        match first with
        | Some x -> Some x
        | None -> (
            match words msg with
            | "(show" :: n :: _ ->
                Some (String.concat "" (String.split_on_char ')' n))
            | _ -> None)
      in
      with_ found sym.queries
  | "E_UNKNOWN_RELATION" -> with_ first sym.relations
  | _ -> None

(* The source line at [line] with [found] replaced, nearest [col] first. *)
let is_name c =
  match c with
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9'
  | '-' | '_' | '?' | '!' | '*' | '+' | '<' | '>' | '=' | '/' ->
      true
  | _ -> false

let fix_line ~(read : string -> string option) (pos : Errors.pos) found best =
  match Option.bind pos.Errors.file read with
  | None -> None
  | Some src -> (
      match
        List.nth_opt (String.split_on_char '\n' src) (pos.Errors.line - 1)
      with
      | None -> None
      | Some line ->
          let n = String.length found and l = String.length line in
          let whole i =
            (i = 0 || not (is_name line.[i - 1]))
            && (i + n = l || not (is_name line.[i + n]))
            && String.sub line i n = found
          in
          let rec from i =
            if i + n > l then None else if whole i then Some i else from (i + 1)
          in
          let at =
            match from (max 0 (pos.Errors.col - 1)) with
            | Some i -> Some i
            | None -> from 0
          in
          Option.map
            (fun i ->
              String.trim
                (String.sub line 0 i ^ best
                ^ String.sub line (i + n) (l - i - n)))
            at)

(* ── one diagnostic ──────────────────────────────────────────────────────── *)

type t = {
  code : string;
  source : Fault.source;
  file : string option;
  line : int option;
  col : int option;
  message : string;
  found : string option;
  expected : string list;
  hint : string;
  fix : string option;
}

let max_expected = 12

let of_fault ~read ~files (f : Fault.t) : t =
  let code = classify f in
  let generic = match entry code with Some e -> e.hint | None -> "" in
  let fe =
    match f.Fault.meant with
    | Some m -> Some m
    | None ->
        if String.length code > 10 && String.sub code 0 10 = "E_UNKNOWN_" then
          found_and_expected (harvest ~read files) f code
        else None
  in
  let found, expected, best =
    match fe with
    | None -> (None, [], None)
    | Some (x, cands) ->
        let ranked, best = rank x cands in
        (* `+` is one edit from `=`, which is no help: there are no numbers *)
        let best = if List.mem x arithmetic then None else best in
        (Some x, List.filteri (fun i _ -> i < max_expected) ranked, best)
  in
  let pos = f.err.Errors.pos in
  let fix =
    match (pos, found, best) with
    | Some p, Some x, Some b -> fix_line ~read p x b
    | _ -> None
  in
  let hint =
    match (found, best) with
    | Some x, Some b -> "Write `" ^ b ^ "` for `" ^ x ^ "`. " ^ generic
    | Some x, None when code = "E_UNKNOWN_MODALITY" && List.mem_assoc x synonyms
      ->
        List.assoc x synonyms
    | Some x, None when List.mem x arithmetic ->
        "Writ has no numbers or arithmetic: a count is a ladder of entities or \
         a small enum (writ_guide idioms, Counters), and an order is a fixed \
         arrow such as `next`."
    | _ -> generic
  in
  {
    code;
    source = f.source;
    file = Option.bind pos (fun p -> p.Errors.file);
    line = Option.map (fun p -> p.Errors.line) pos;
    col = Option.map (fun p -> p.Errors.col) pos;
    message = f.err.Errors.msg;
    found;
    expected;
    hint;
    fix;
  }

let see code = "writ_guide errors." ^ code

let to_text (d : t) =
  let b = Buffer.create 256 in
  let line k v =
    Buffer.add_string b (Printf.sprintf "  %-9s %s\n" (k ^ ":") v)
  in
  let where =
    match (d.file, d.line, d.col) with
    | Some f, Some l, Some c -> Printf.sprintf "%s:%d:%d" f l c
    | None, Some l, Some c -> Printf.sprintf "%d:%d" l c
    | Some f, _, _ -> f
    | _ -> ""
  in
  Buffer.add_string b
    (* Not checked is not an error in the file; it says why there is none. *)
    (Printf.sprintf "%s %s in %s%s\n"
       (if d.code = "E_NOT_CHECKED" then "note" else "error")
       d.code
       (Fault.source_name d.source)
       (if where = "" then "" else " at " ^ where));
  Buffer.add_string b ("  " ^ d.message ^ "\n");
  Option.iter (line "found") d.found;
  if d.expected <> [] then
    line "expected" ("one of " ^ String.concat ", " d.expected);
  if d.hint <> "" then line "hint" d.hint;
  Option.iter (line "fix") d.fix;
  line "see" (see d.code);
  Buffer.contents b

let to_json (d : t) =
  let opt k = function Some v -> [ (k, Json.String v) ] | None -> [] in
  let opti k = function Some v -> [ (k, Json.Int v) ] | None -> [] in
  Json.Assoc
    ([
       ("code", Json.String d.code);
       ("source", Json.String (Fault.source_name d.source));
     ]
    @ opt "file" d.file @ opti "line" d.line @ opti "col" d.col
    @ [ ("message", Json.String d.message) ]
    @ opt "found" d.found
    @ (if d.expected = [] then []
       else
         [
           ("expected", Json.List (List.map (fun s -> Json.String s) d.expected));
         ])
    @ [ ("hint", Json.String d.hint) ]
    @ opt "fix" d.fix
    @ [ ("see", Json.String (see d.code)) ])

(* ── a search cut short ──────────────────────────────────────────────────── *)

let bound (spread : (string * int * int) list) =
  List.fold_left
    (fun acc (_, _, dom) -> acc *. float_of_int (max 1 dom))
    1.0 spread

let show_bound = Writ_runtime.Space.show_bound

let limit_text (l : Fault.limit) =
  let c = l.Fault.cutoff in
  let b = Buffer.create 512 in
  let add = Buffer.add_string b in
  (match c.Writ_runtime.Space.reason with
  | `Cap n ->
      add
        (Printf.sprintf "limit E_STATE_LIMIT: stopped at max_situations = %d\n"
           n)
  | `Timeout t ->
      add
        (Printf.sprintf "limit E_STATE_LIMIT: stopped at timeout = %.0f ms\n"
           (t *. 1000.)));
  add
    (Printf.sprintf "  explored:  %d situations, %d edges, not finished\n"
       c.explored c.edges_seen);
  add
    (Printf.sprintf
       "  bound:     at most %s situations (the product of every mutable \
        cell's domain)\n"
       (show_bound (bound c.spread)));
  if l.undecided <> [] then
    add
      ("  undecided: "
      ^ String.concat ", " l.undecided
      ^ " (nothing is decided on a partial space)\n");
  add "  growth, by distinct values seen per cell (of its domain):\n";
  List.iteri
    (fun i (cell, seen, dom) ->
      if i < 8 then add (Printf.sprintf "    %-24s %d of %d\n" cell seen dom))
    c.spread;
  (match entry "E_STATE_LIMIT" with
  | Some e -> add ("  hint:      " ^ e.hint ^ "\n")
  | None -> ());
  add "  see:       writ_guide idioms (Abstraction), errors.E_STATE_LIMIT\n";
  Buffer.contents b

let limit_json (l : Fault.limit) =
  let c = l.Fault.cutoff in
  let reason, value =
    match c.Writ_runtime.Space.reason with
    | `Cap n -> ("max_situations", Json.Int n)
    | `Timeout t -> ("timeout_ms", Json.Int (int_of_float (t *. 1000.)))
  in
  Json.Assoc
    [
      ("ok", Json.Bool false);
      ( "limit",
        Json.Assoc
          [
            ("code", Json.String "E_STATE_LIMIT");
            ("reason", Json.String reason);
            ("value", value);
            ("explored", Json.Int c.explored);
            ("edges", Json.Int c.edges_seen);
            ("bound", Json.String (show_bound (bound c.spread)));
            ( "undecided",
              Json.List (List.map (fun s -> Json.String s) l.undecided) );
            ( "growth",
              Json.List
                (List.map
                   (fun (cell, seen, dom) ->
                     Json.Assoc
                       [
                         ("cell", Json.String cell);
                         ("seen", Json.Int seen);
                         ("domain", Json.Int dom);
                       ])
                   c.spread) );
            ("see", Json.String "writ_guide idioms");
          ] );
    ]

(* ── the reply ───────────────────────────────────────────────────────────── *)

let render ~json ~read ~files (f : Fault.failure) =
  match f with
  | Fault.Limit l ->
      if json then Json.to_string (limit_json l) else limit_text l
  | Fault.Bad faults ->
      let ds = List.map (of_fault ~read ~files) faults in
      if json then
        Json.to_string
          (Json.Assoc
             [
               ("ok", Json.Bool false);
               ("errors", Json.List (List.map to_json ds));
             ])
      else String.concat "\n" (List.map to_text ds)
