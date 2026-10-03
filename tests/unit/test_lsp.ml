(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* LSP tests: [Server.handle] is pure, so the protocol is driven with no I/O. *)

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

(* A self-contained model, sibling of both claims files. *)
let model_src =
  "(schema tiny\n\
  \  (type flag (lo hi))\n\
  \  (type box (arrow f (to flag))))\n\
   (instance i tiny  (box b (f lo))  )\n\
   (use tiny)\n\
   (initial i)\n\
   (transition raise (when (is b.f lo)) (do (set b.f hi)))\n"

let claims_ok =
  "(property phantom \"shape only\" (possible (is b.f hi)))\n\
   (query captured (where (x box)) (is x.f hi))\n\
   (accept raise same-agency)\n"

(* Query guards are checked, unlike property formulas (kernel §8). *)
let claims_bad = "(query oops (where (x box)) (is x.ghost hi))\n"

(* A library: declarations only, no (use)/(initial)/transition. *)
let library_src =
  "(form (all (X T) G) (not (some (X T) (not G))))\n\
   (schema quiver (type node))\n"

(* A library whose fault sits at a column the loading buffer does not have. *)
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

(* 0. initialize reports the server's version: the editor client compares it
   with its own, as they are installed separately. *)
let () =
  let init =
    Json.Assoc
      [
        ("jsonrpc", Json.String "2.0");
        ("id", Json.Int 1);
        ("method", Json.String "initialize");
        ("params", Json.Assoc []);
      ]
  in
  let st = Server.create ~resolve in
  let r = result_of (Server.handle st init) in
  check "initialize: still declares its capabilities"
    (match Json.member "capabilities" r with
    | Some c -> Json.member "documentSymbolProvider" c <> None
    | None -> false);
  check "initialize: names itself and the writ it was built from"
    (match Json.member "serverInfo" r with
    | Some si ->
        Json.member "name" si = Some (Json.String "writ-lsp")
        && Json.member "version" si = Some (Json.String Writ_lsp.Version.v)
    | None -> false);
  check "initialize: the version it reports is not empty"
    (String.length Writ_lsp.Version.v > 0)

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

(* 4. an unresolvable [(load …)]: the squiggle sits on the load form and has
   width. *)
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

(* 5. a fault inside a loaded library falls back to line 1; the message
   carries the true location. *)
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

(* 5. a .rules buffer is checked as rules against its sibling model. *)
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

(* Completion and hover agree, compared without naming a word so the test is
   not another copy of the list. *)
let () =
  let offered = List.sort compare Completion.interrogator in
  let described = List.sort compare (List.map fst Lookup.interrogator_desc) in
  check "every word the editor offers, it can also explain" (offered = described);
  let mods = List.map fst Writ_syntax.Claims_parser.modalities in
  check "…including every modality the parser accepts"
    (mods <> []
    && List.for_all (fun m -> List.mem m offered && List.mem m described) mods);
  (* `fair` heads a clause, not a modality. *)
  check "a clause head is offered without being a modality"
    (List.mem "fair" offered && List.mem "fair" described
    && Writ_syntax.Claims_parser.modality_of "fair" = None)

let () =
  print_string ("lsp tests: " ^ string_of_int !passed ^ " checks passed\n")
