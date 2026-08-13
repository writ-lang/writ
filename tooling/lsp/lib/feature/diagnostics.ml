(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Text in, squiggles out — by running the engine's own front end, never a
   second copy of it. Every diagnostic here is the compiler's verdict from a
   [Loader.] entry; a rule enforced in a second implementation would drift from
   the first silently.

   The buffer parses through an INJECTED [resolve]: the server hands one that
   returns the in-memory text for the active file (so an unsaved buffer is
   checked as typed) and reads every [(load …)] target off disk. There is no
   implicit prelude — a name used without loading its library surfaces here as
   the front end's own unknown-name error.

   FILE ROLE decides which entry runs (kernel §6.1, §16). A .writ buffer with a
   [(use …)] is a MODEL ([read_model]); without one it is a LIBRARY
   ([load_library], which does not demand a model's use/initial). A .claims
   buffer is checked as CLAIMS against its sibling model, and a .rules buffer as
   RULES against the same (extension §1); when that model is absent or does not
   build, a structural read+expand of the buffer still catches malformed datums
   and load cycles — but never emits a "needs (use)".

   HONEST LIMITATION: this yields ZERO or ONE diagnostic, never more. The front
   end is written with [Result.bind] and stops at the first problem by
   construction, so a second typo stays hidden until the first is fixed. The wire
   shape already carries an array, so widening this later changes nothing a
   client sees. *)

open Writ_data
open Writ_syntax

let ( let* ) = Result.bind

(* LSP DiagnosticSeverity: 1 = Error. The front end reports only hard
   parse/shape errors, so every diagnostic is an error. *)
let severity_error = 1

let mark ~range msg =
  Json.Assoc
    [
      ("range", Text.json_of_range range);
      ("severity", Json.Int severity_error);
      ("source", Json.String "writ");
      ("message", Json.String msg);
    ]

(* A positioned error covers the token it blames. The engine position is 1-based
   over bytes and an LSP range is 0-based over UTF-16, so the conversion goes
   through [Text] — the one module allowed to do it. An error with nowhere to
   point ([pos = None]) still has to be visible, so it lands on the first line
   rather than being dropped.

   [form_range], not [token_range]: an error blamed on a LIST datum — an
   unresolvable [(load …)], a load cycle — carries the position of its '(', and
   a token range on a delimiter is ZERO-WIDTH, which draws nothing. form_range
   spans '(' to its matching ')' and falls back to token_range everywhere else,
   so atom-positioned errors are unchanged.

   A position from ANOTHER file is treated as no position at all. A diagnostic
   belongs to the document being analysed, but a fault inside a [(load …)]ed
   library carries coordinates into THAT file, which the loader inlined into this
   one's datums; drawing them on this buffer would underline whatever text
   happens to sit at that line and column — a squiggle placed with total
   confidence on a file the author is not even looking at. So the range falls
   back to line 1, which is where an error with nowhere to point already goes,
   and the message carries the [file:line:col] that [Errors.to_string] renders —
   the only place the real location can still be read. *)
let of_error (t : Text.t) ~(file : string) (e : Errors.t) =
  let mine (p : Errors.pos) =
    match p.Errors.file with None -> true | Some f -> f = file
  in
  match e.Errors.pos with
  | Some p when mine p ->
      mark ~range:(Text.form_range t (Text.lsp_of_pos t p)) e.Errors.msg
  | Some _ | None -> mark ~range:(Text.line_range t 0) (Errors.to_string e)

(* The buffer's top-level datums, or none when it does not even read (an
   unbalanced paren); the role then falls back to a library/model whose loader
   surfaces that same reader error. *)
let datums_of (t : Text.t) : Reader.t list =
  match Reader.read_string t.Text.src with Ok ds -> ds | Error _ -> []

(* Read + inline + expand the buffer WITHOUT a schema — the structural check for
   a .claims or .rules buffer whose sibling model is absent or does not build.
   It still catches malformed datums, load cycles, and library violations, yet
   never demands a model's (use)/(initial), which neither file type has.

   [open_heads] must be passed through, and forgetting it was a real bug rather
   than a tidiness point: a .rules file with no sibling model — ct.rules itself,
   which has no ct.writ and never will — took THIS path, where the expander
   refuses a template head it cannot know (`situation`, `holds`, any relation
   the file declares). The editor therefore squiggled the standard library while
   the command line accepted it, which is the one divergence a language server
   must not have. [Loader.read_rules] already opts in; this is the same opt-in
   on the fallback beside it. *)
let structural ?(open_heads = false) (resolve : Loader.resolve) (path : string)
    : (unit, Errors.t) result =
  let* datums =
    Loader.read_datums resolve ~file:path (Filename.basename path)
  in
  let* inlined = Loader.inline resolve datums in
  let* _ = Expander.expand ~open_heads inlined in
  Ok ()

(* A .rules buffer is checked against its sibling model, as a .claims buffer
   is: the sorts, stratification and range restriction the extension demands
   (§1, §4) are only decidable against the schema the relations range over.
   Without this a .rules file fell through to [Library] and was silently
   accepted — no false errors, but no true ones either, which is worse in an
   editor whose whole promise is diagnostics from the real engine. *)
let check_rules (resolve : Loader.resolve) ~(path : string) ~(sibling : string)
    : (unit, Errors.t) result =
  match Loader.read_model resolve sibling with
  | Error _ -> structural ~open_heads:true resolve path
  | Ok model ->
      (* [Loader.read_rules] only PARSES. Sorts, stratification, range
         restriction and the undeclared-head check live in [Rules_check], which
         [Cli_io.read_rules] runs straight after — and its comment says why:
         those are read-time rejections, so they belong to reading the file.
         Stopping at the parse is what made this buffer silent: every shape
         error the extension actually rejects is on the far side of it. *)
      let* prog = Loader.read_rules resolve model path in
      Result.map (fun _ -> ()) (Rules_check.check model prog)

(* A .claims buffer is checked against its sibling model; if that model is
   absent or does not build, fall back to the structural check. *)
let check_claims (resolve : Loader.resolve) ~(path : string) ~(sibling : string)
    : (unit, Errors.t) result =
  match Loader.read_model resolve sibling with
  | Ok model -> Result.map (fun _ -> ()) (Loader.read_claims resolve model path)
  | Error _ -> structural resolve path

let check (t : Text.t) ~(resolve : Loader.resolve) ~(path : string) :
    (unit, Errors.t) result =
  match Role.of_path path (datums_of t) with
  | Role.Model -> Result.map (fun _ -> ()) (Loader.read_model resolve path)
  | Role.Library -> Result.map (fun _ -> ()) (Loader.load_library resolve path)
  | Role.Claims sibling -> check_claims resolve ~path ~sibling
  | Role.Rules sibling -> check_rules resolve ~path ~sibling

let of_text (t : Text.t) ~(resolve : Loader.resolve) ~(path : string) :
    Json.t list =
  match check t ~resolve ~path with
  | Ok () -> []
  | Error e -> [ of_error t ~file:path e ]
