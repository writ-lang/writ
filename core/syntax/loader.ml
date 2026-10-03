(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* The front-end entry: inline [(load …)], expand forms, parse. There is NO IO
   here — the [resolve] callback is injected by the caller (the CLI, the LSP
   binary), which keeps the engine libraries (core/, runtime/) IO-free. Loading is idempotent per
   file and acyclic; a loaded file must be a library (declarations only). There
   is NO implicit prelude (kernel §0.7): only an explicit [(load …)] pulls
   anything in, so a name used without loading its library surfaces as an
   unknown-name error from the parser. *)

type resolve = string -> (string, Errors.t) result

let ( let* ) = Result.bind

(* Every file is read under a name, and that name goes onto the positions of its
   datums — which is the whole reason a diagnostic from a loaded library can still
   say so after [inline] has spliced it into the loading file's datum list.
   [?file] exists because the two names differ for the file the caller asked
   about: [name] is what [resolve] searches for (a basename, see design D3),
   while the path the caller typed is what it can act on, so the entry points
   below pass that as the label. A [(load …)] target has no such path — the load
   datum named it, and the load path is how the reader finds it again — so its
   own name is both. *)
let read_datums (resolve : resolve) ?file (name : string) :
    (Reader.t list, Errors.t) result =
  let* src = resolve name in
  Reader.read_string ~file:(Option.value file ~default:name) src

let load_name = function
  | Reader.List ([ Reader.Atom ("load", _); Reader.Atom (f, _) ], p) ->
      Some (f, p)
  | _ -> None

(* A loaded file must be a library: declarations only, never a model's own
   [use]/[initial]/[transition]. *)
let ensure_library (datums : Reader.t list) : (unit, Errors.t) result =
  let bad =
    List.find_map
      (function
        | Reader.List
            (Reader.Atom ((("use" | "initial" | "transition") as h), p) :: _, _)
          ->
            Some (h, p)
        | _ -> None)
      datums
  in
  match bad with
  | Some (h, p) ->
      Errors.err ~pos:p
        ("a loaded library must contain declarations only, not (" ^ h ^ " …)")
  | None -> Ok ()

(* A [resolve] callback is handed a name, not a datum, so the error it returns
   for an unreadable target carries no position. The load datum's position IS
   known here, so fill it in: a positionless error has nowhere to go but line 1
   (see the editor's fallback), and line 1 is typically a comment — a squiggle
   on prose while the real fault is the load. An error that already carries a
   position — anything raised inside the loaded file — keeps its own. *)
let at_load (p : Errors.pos) = function
  | Error ({ Errors.pos = None; _ } as e) ->
      Error { e with Errors.pos = Some p }
  | r -> r

(* Inline every [(load …)] in place: read the file's datums, verify it is a
   library, recurse into its own loads (idempotent per file, cycles rejected). *)
let inline (resolve : resolve) (datums : Reader.t list) :
    (Reader.t list, Errors.t) result =
  let loaded = ref [] in
  let rec walk stack acc = function
    | [] -> Ok (List.rev acc)
    | d :: rest -> (
        match load_name d with
        | None -> walk stack (d :: acc) rest
        | Some (fname, p) ->
            if List.mem fname stack then
              Errors.err ~pos:p
                ("load cycle: `" ^ fname ^ "` is already being loaded")
            else if List.mem fname !loaded then walk stack acc rest
            else
              let* fds = at_load p (read_datums resolve fname) in
              let* () = ensure_library fds in
              let* inlined = walk (fname :: stack) [] fds in
              loaded := fname :: !loaded;
              walk stack (List.rev_append inlined acc) rest)
  in
  walk [] [] datums

(* Provenance (docs/bridges.md). A `; writ:origin TEXT` comment on the line
   above a datum attaches TEXT to the move or law that datum declares — and,
   for a form invocation, to every move it expands into, since the invocation
   is the line the author wrote. Read from the model's own file; a library's
   comments are its own. The language never sees any of it: an origin is a
   note a tool echoes, and deleting every one changes no verdict. *)
let origins_of ~(file : string) (pragmas : (int * string) list) :
    (int * string) list =
  ignore file;
  List.filter_map
    (fun (line, text) ->
      let prefix = "origin " in
      let lp = String.length prefix in
      if String.length text > lp && String.sub text 0 lp = prefix then
        Some (line, String.trim (String.sub text lp (String.length text - lp)))
      else None)
    pragmas

let read_model (resolve : resolve) (path : string) : (Model.t, Errors.t) result
    =
  let name = Filename.basename path in
  let* src = resolve name in
  let* datums, pragmas = Reader.read_string_with_pragmas ~file:path src in
  let origins = origins_of ~file:path pragmas in
  let above (d : Reader.t) : string option =
    let p = Reader.pos_of d in
    if p.Errors.file = Some path then List.assoc_opt (p.Errors.line - 1) origins
    else None
  in
  let* inlined = inline resolve datums in
  let* groups = Expander.expand_grouped inlined in
  let expanded = List.concat_map snd groups in
  (* Everything a top-level datum became inherits the pragma above it. *)
  let inherited =
    List.concat_map
      (fun (src, outs) ->
        match above src with
        | Some o -> List.map (fun d -> (d, o)) outs
        | None -> [])
      groups
  in
  let origin (d : Reader.t) : string option =
    match above d with Some o -> Some o | None -> List.assq_opt d inherited
  in
  Parser.parse_model ~origin expanded

let load_library (resolve : resolve) (name : string) :
    (Reader.t list, Errors.t) result =
  let* datums = read_datums resolve ~file:name (Filename.basename name) in
  let* () = ensure_library datums in
  inline resolve datums

let read_claims (resolve : resolve) (m : Model.t) (path : string) :
    (Claims.t, Errors.t) result =
  let* datums = read_datums resolve ~file:path (Filename.basename path) in
  let* inlined = inline resolve datums in
  let* expanded = Expander.expand inlined in
  Claims_parser.parse m.Model.schema m.Model.initial expanded

(* A .rules file is the third file type (extension §1) and reads like the other
   two: its own [(load …)] libraries inlined, its forms expanded, then parsed.
   The schema is passed for one narrow purpose — a typed column may name a
   schema type, and the sort words must not be shadowed by one. *)
let read_rules (resolve : resolve) (m : Model.t) (path : string) :
    (Rules_parser.t, Errors.t) result =
  let* datums = read_datums resolve ~file:path (Filename.basename path) in
  let* inlined = inline resolve datums in
  let* expanded = Expander.expand ~open_heads:true inlined in
  Rules_parser.parse m.Model.schema expanded
