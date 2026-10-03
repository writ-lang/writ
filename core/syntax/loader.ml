(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* The front end: inline [(load …)], expand forms, parse. IO goes through the
   injected [resolve]. No implicit prelude (kernel §0.7). *)

type resolve = string -> (string, Errors.t) result

let ( let* ) = Result.bind

(* [name] is what [resolve] looks up (design D3); [?file], the path the
   caller typed, labels positions if given. *)
let read_datums (resolve : resolve) ?file (name : string) :
    (Reader.t list, Errors.t) result =
  let* src = resolve name in
  Reader.read_string ~file:(Option.value file ~default:name) src

let load_name = function
  | Reader.List ([ Reader.Atom ("load", _); Reader.Atom (f, _) ], p) ->
      Some (f, p)
  | _ -> None

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

(* [resolve] errors carry no position; blame the load datum instead of letting
   the editor fall back to line 1. Errors from inside the file keep theirs. *)
let at_load (p : Errors.pos) = function
  | Error ({ Errors.pos = None; _ } as e) ->
      Error { e with Errors.pos = Some p }
  | r -> r

(* Inline every [(load …)] in place, recursively. *)
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

(* `; writ:origin TEXT` on the line above a datum (docs/bridges.md),
   inherited by everything a form invocation expands into. *)
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

(* A .rules file (extension §1) reads like the other two. The schema is passed
   so a typed column may name a schema type. *)
let read_rules (resolve : resolve) (m : Model.t) (path : string) :
    (Rules_parser.t, Errors.t) result =
  let* datums = read_datums resolve ~file:path (Filename.basename path) in
  let* inlined = inline resolve datums in
  let* expanded = Expander.expand ~open_heads:true inlined in
  Rules_parser.parse m.Model.schema expanded
