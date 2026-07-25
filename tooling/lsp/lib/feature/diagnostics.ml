(* Text in, squiggles out — by running the engine's own front end, never a
   second copy of it. Every diagnostic here is the compiler's verdict from a
   [Loader.] entry; a rule enforced in a second implementation would drift from
   the first silently.

   The buffer parses through an INJECTED [resolve]: the server hands one that
   returns the in-memory text for the active file (so an unsaved buffer is
   checked as typed) and reads every [(load …)] target off disk. There is no
   implicit prelude — a name used without loading its library surfaces here as
   the front end's own unknown-name error.

   FILE ROLE decides which entry runs (kernel §6.1, §16). A .pol buffer with a
   [(use …)] is a MODEL ([read_model]); without one it is a LIBRARY
   ([load_library], which does not demand a model's use/initial). A .claims
   buffer is checked as CLAIMS against its sibling model; when that model is
   absent or does not build, a structural read+expand of the buffer still
   catches malformed datums and load cycles — but never emits a "needs (use)".

   HONEST LIMITATION: this yields ZERO or ONE diagnostic, never more. The front
   end is written with [Result.bind] and stops at the first problem by
   construction, so a second typo stays hidden until the first is fixed. The wire
   shape already carries an array, so widening this later changes nothing a
   client sees. *)

open Pol_data
open Pol_syntax

let ( let* ) = Result.bind

(* LSP DiagnosticSeverity: 1 = Error. The front end reports only hard
   parse/shape errors, so every diagnostic is an error. *)
let severity_error = 1

let mark ~range msg =
  Json.Assoc
    [
      ("range", Text.json_of_range range);
      ("severity", Json.Int severity_error);
      ("source", Json.String "pol");
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
   so atom-positioned errors are unchanged. *)
let of_error (t : Text.t) (e : Errors.t) =
  let range =
    match e.Errors.pos with
    | Some p -> Text.form_range t (Text.lsp_of_pos t p)
    | None -> Text.line_range t 0
  in
  mark ~range e.Errors.msg

(* The buffer's top-level datums, or none when it does not even read (an
   unbalanced paren); the role then falls back to a library/model whose loader
   surfaces that same reader error. *)
let datums_of (t : Text.t) : Reader.t list =
  match Reader.read_string t.Text.src with Ok ds -> ds | Error _ -> []

(* Read + inline + expand the buffer WITHOUT a schema — the structural check for
   a .claims buffer whose sibling model is absent or does not build. It still
   catches malformed datums, load cycles, and library violations, yet never
   demands a model's (use)/(initial), which a claims file legitimately lacks. *)
let structural (resolve : Loader.resolve) (path : string) :
    (unit, Errors.t) result =
  let* datums = Loader.read_datums resolve (Filename.basename path) in
  let* inlined = Loader.inline resolve datums in
  let* _ = Expander.expand inlined in
  Ok ()

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

let of_text (t : Text.t) ~(resolve : Loader.resolve) ~(path : string) :
    Json.t list =
  match check t ~resolve ~path with Ok () -> [] | Error e -> [ of_error t e ]
