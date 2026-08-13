(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* LSP tests (rule 6): [Server.handle] is pure — a JSON message in, a list of
   JSON messages out — so the whole protocol surface is driven here with no I/O.
   The injected [resolve] serves fixture text from a small in-memory map keyed by
   file name, exactly as the binary's disk reader would, so a .claims buffer's
   sibling model and a library resolve without touching the filesystem.

   Three behaviours are pinned, one per finished fix:
     1. a VALID .claims buffer publishes NO diagnostic, and its outline shows the
        property / query / accept symbols with range ⊇ selectionRange;
     2. a LIBRARY .writ buffer (no [use]) publishes NO "needs (use)" diagnostic;
     3. a .claims buffer with a genuine (query path) error publishes exactly ONE
        diagnostic carrying a line:col range.
   Plus two about WHERE a squiggle may be drawn: on the [(load …)] that failed to
   resolve, and — for a fault inside the library that load pulled in — nowhere in
   particular, because a coordinate into another file cannot honestly be drawn on
   this one. *)

open Writ_data
open Writ_lsp

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

(* --- fixtures, served in memory ------------------------------------------- *)

(* A self-contained model: a one-arrow box over a two-value flag. No loads, so
   the map needs nothing else. Sibling of both mini.claims and bad.claims. *)
let model_src =
  "(schema tiny\n\
  \  (type flag (lo hi))\n\
  \  (type box (arrow f (to flag))))\n\
   (instance i tiny  (box b (f lo))  )\n\
   (use tiny)\n\
   (initial i)\n\
   (transition raise (when (is b.f lo)) (do (set b.f hi)))\n"

(* A valid claims file for the model: a property (shape only, kernel §8), a
   well-typed query, and an acknowledgement. *)
let claims_ok =
  "(property phantom \"shape only\" (possible (is b.f hi)))\n\
   (query captured (where (x box)) (is x.f hi))\n\
   (accept raise same-agency)\n"

(* A claims file whose query names an arrow the box type lacks — a genuine
   author error the query path-checker blames at a position (kernel §8: query
   guards ARE checked, unlike property formulas). *)
let claims_bad = "(query oops (where (x box)) (is x.ghost hi))\n"

(* A library: declarations only, NO (use)/(initial)/transition. *)
let library_src =
  "(form (all (X T) G) (not (some (X T) (not G))))\n\
   (schema quiver (type node))\n"

(* A library with a fault of its own, on one long line: the [(equation …)] sits
   inside a [(type …)] body, at column 55 of 84. Loaded by a buffer whose lines
   are all far shorter, so the position it carries indexes nothing here. *)
let flawed_library_src =
  "(schema lib (type v (a b)) (type box (arrow f (to v)) (equation e (= box.f \
   box.f))))\n"

let files =
  [
    ("mini.writ", model_src);
    ("bad.writ", model_src);
    ("kit.writ", library_src);
    ("flaw.writ", flawed_library_src);
  ]

let resolve _uri name : (string, Errors.t) result =
  match List.assoc_opt name files with
  | Some s -> Ok s
  | None -> Error { Errors.pos = None; msg = "no such file: " ^ name }

(* --- message + response helpers ------------------------------------------- *)

let did_open uri text =
  Json.Assoc
    [
      ("jsonrpc", Json.String "2.0");
      ("method", Json.String "textDocument/didOpen");
      ( "params",
        Json.Assoc
          [
            ( "textDocument",
              Json.Assoc
                [ ("uri", Json.String uri); ("text", Json.String text) ] );
          ] );
    ]

let doc_symbol ~id uri =
  Json.Assoc
    [
      ("jsonrpc", Json.String "2.0");
      ("id", Json.Int id);
      ("method", Json.String "textDocument/documentSymbol");
      ( "params",
        Json.Assoc [ ("textDocument", Json.Assoc [ ("uri", Json.String uri) ]) ]
      );
    ]

(* The diagnostics array from the publishDiagnostics notification a didOpen
   answers with. *)
let diagnostics_of outputs =
  let is_pub j =
    Json.member "method" j
    = Some (Json.String "textDocument/publishDiagnostics")
  in
  match List.find_opt is_pub outputs with
  | Some j -> (
      match
        Option.bind (Json.member "params" j) (Json.member "diagnostics")
      with
      | Some (Json.List ds) -> ds
      | _ -> [])
  | None -> []

let result_of outputs =
  match outputs with
  | [ j ] -> (
      match Json.member "result" j with Some r -> r | None -> Json.Null)
  | _ -> Json.Null

(* --- range containment ---------------------------------------------------- *)

let pos j =
  match (Json.member "line" j, Json.member "character" j) with
  | Some (Json.Int l), Some (Json.Int c) -> (l, c)
  | _ -> failwith "malformed position"

let range_of j =
  match (Json.member "start" j, Json.member "end" j) with
  | Some s, Some e -> (pos s, pos e)
  | _ -> failwith "malformed range"

let leq (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2)

let encloses outer inner =
  let os, oe = outer and is_, ie = inner in
  leq os is_ && leq ie oe

let sym_name j =
  match Json.member "name" j with Some (Json.String s) -> s | _ -> ""

let sym_encloses j =
  match (Json.member "range" j, Json.member "selectionRange" j) with
  | Some r, Some s -> encloses (range_of r) (range_of s)
  | _ -> false

(* --- the drives ----------------------------------------------------------- *)

(* 1. a valid claims buffer: no diagnostic, and a property/query/accept outline *)
let () =
  let st = Server.create ~resolve in
  let uri = "file:///w/mini.claims" in
  let out = Server.handle st (did_open uri claims_ok) in
  check "valid .claims: no spurious diagnostic" (diagnostics_of out = []);
  let syms =
    match result_of (Server.handle st (doc_symbol ~id:1 uri)) with
    | Json.List xs -> xs
    | _ -> []
  in
  let names = List.map sym_name syms in
  check "outline: property symbol present" (List.mem "phantom" names);
  check "outline: query symbol present" (List.mem "captured" names);
  check "outline: accept symbol present" (List.mem "raise" names);
  check "outline: every range ⊇ selectionRange"
    (syms <> [] && List.for_all sym_encloses syms)

(* 2. a library buffer (no use): no "needs (use)" diagnostic *)
let () =
  let st = Server.create ~resolve in
  let out = Server.handle st (did_open "file:///w/kit.writ" library_src) in
  check "library .writ: no diagnostic demanding (use)" (diagnostics_of out = [])

(* 3. a claims buffer with a genuine error: exactly one diagnostic, positioned *)
let () =
  let st = Server.create ~resolve in
  let out = Server.handle st (did_open "file:///w/bad.claims" claims_bad) in
  match diagnostics_of out with
  | [ d ] -> (
      check "bad .claims: exactly one diagnostic" true;
      match Json.member "range" d with
      | Some r ->
          let (l, _), _ = range_of r in
          check "bad .claims: diagnostic carries a line:col range" (l >= 0)
      | None -> check "bad .claims: diagnostic carries a range" false)
  | ds ->
      check
        ("bad .claims: expected one diagnostic, got "
        ^ string_of_int (List.length ds))
        false

(* 4. an unresolvable [(load …)]: the squiggle sits on the load form, and has
   WIDTH. Two regressions in one buffer, both once real:
     - the resolver's error carried no position, so it fell back to line 1 —
       which in a real model is the comment header, prose blamed for a load;
     - a list datum's position is its '(', and a token range on a delimiter is
       zero-width, so a correctly-placed diagnostic was invisible. *)
let () =
  let src = "; a comment header, not code\n;\n(load \"nope.writ\")\n" in
  let st = Server.create ~resolve in
  let out = Server.handle st (did_open "file:///w/loads.writ" src) in
  match diagnostics_of out with
  | [ d ] -> (
      match Json.member "range" d with
      | Some r ->
          let (l0, c0), (l1, c1) = range_of r in
          check "bad load: blamed on the load line, not the comment header"
            (l0 = 2);
          check
            "bad load: the range has width (a zero-width squiggle is invisible)"
            (l1 > l0 || c1 > c0)
      | None -> check "bad load: diagnostic carries a range" false)
  | ds ->
      check
        ("bad load: expected one diagnostic, got "
        ^ string_of_int (List.length ds))
        false

(* 5. a fault INSIDE a loaded library. The loader inlines that library's datums
   into this buffer's, so the error arrives carrying column 55 of a file the
   editor is not showing — and this buffer's longest line is 28 columns. Drawing
   it here would underline whatever text happens to sit nearby with complete
   confidence, which is the wrong-file coordinate this guards against. So the
   range falls back to line 1 exactly as a positionless error does, and the
   message carries the location that is actually true. *)
let () =
  let src =
    "(load \"flaw.writ\")\n\
     (schema mine (type w (c d)))\n\
     (instance i mine)\n\
     (use mine)\n\
     (initial i)\n"
  in
  let st = Server.create ~resolve in
  let out = Server.handle st (did_open "file:///w/loader.writ" src) in
  match diagnostics_of out with
  | [ d ] ->
      check "cross-file: the diagnostic is not pinned to a line of this buffer"
        (match Json.member "range" d with
        | Some r ->
            range_of r = ((0, 0), (0, String.length "(load \"flaw.writ\")"))
        | None -> false);
      check "cross-file: the message names the library and its own line:col"
        (match Json.member "message" d with
        | Some (Json.String m) -> contains_sub ~sub:"flaw.writ:1:55: " m
        | _ -> false)
  | ds ->
      check
        ("cross-file: expected one diagnostic, got "
        ^ string_of_int (List.length ds))
        false

(* 5. a .rules buffer is checked as RULES against its sibling model, not waved
   through as a library. The failure this pins is silence: before the Rules
   role existed the buffer fell to [Library], which read+expanded it happily,
   so an undeclared relation head produced no diagnostic at all while the CLI
   reported it. *)
let () =
  let st = Server.create ~resolve in
  let src = "(relation declared 1)\n(rule (undeclared X) (situation X))\n" in
  let out = Server.handle st (did_open "file:///w/mini.rules" src) in
  match diagnostics_of out with
  | [ d ] ->
      check "bad .rules: the undeclared head is reported"
        (match Json.member "message" d with
        | Some (Json.String m) -> contains_sub ~sub:"undeclared" m
        | _ -> false)
  | ds ->
      check
        ("bad .rules: expected one diagnostic, got "
        ^ string_of_int (List.length ds))
        false

(* --- the claims vocabulary, in the copies that remain --------------------- *)

(* This vocabulary lived in three places — the parser, the editor's completion
   list and its hover table — and the third time a word was added, two of them
   were updated. The modalities are now READ from the parser rather than listed
   again, so completion cannot offer a word the parser refuses. What is left is
   completion against hover, and it is pinned here WITHOUT naming a word: a test
   that spelled the list out would be a fourth copy, and would go stale in the
   same way and at the same moment. *)
let () =
  let offered = List.sort compare Completion.interrogator in
  let described = List.sort compare (List.map fst Lookup.interrogator_desc) in
  check "every word the editor offers, it can also explain" (offered = described);
  (* And the parser's own list is covered by both, which is what makes the two
     above worth comparing: an empty pair of lists would satisfy the equality. *)
  let mods = List.map fst Writ_syntax.Claims_parser.modalities in
  check "…including every modality the parser accepts"
    (mods <> []
    && List.for_all (fun m -> List.mem m offered && List.mem m described) mods);
  (* `fair` is vocabulary but NOT a modality — it heads the clause an
     `inevitable` may carry — so it must be offered and explained while the
     parser refuses it where a modality belongs. *)
  check "a clause head is offered without being a modality"
    (List.mem "fair" offered && List.mem "fair" described
    && Writ_syntax.Claims_parser.modality_of "fair" = None)

let () =
  print_string ("lsp tests: " ^ string_of_int !passed ^ " checks passed\n")
