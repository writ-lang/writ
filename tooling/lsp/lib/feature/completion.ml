(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Completion. A buffer being completed usually does not parse, so the context
   comes from a lexical scan and the names from the buffer plus the libraries
   it loads. Kernel words are listed by hand (the parser matches them as
   literals); library form heads are derived. Never raises. *)

open Writ_syntax

(* LSP CompletionItemKind: Keyword=14, Enum=13, EnumMember=20. *)
let item ?detail label kind =
  Json.Assoc
    (("label", Json.String label)
    :: ("kind", Json.Int kind)
    ::
    (match detail with
    | Some d -> [ ("detail", Json.String d) ]
    | None -> []))

(* The reserved words of the language (kernel §9). *)
let reserved =
  [
    "use";
    "load";
    "schema";
    "type";
    "arrow";
    "to";
    "fixed";
    "vacatable";
    "equation";
    "=";
    "instance";
    "initial";
    "vacant";
    "transition";
    "when";
    "do";
    "set";
    "vacate";
    "gap";
    "form";
    "&rest";
    "and";
    "or";
    "not";
    "is";
    "defined";
    "some";
  ]

(* The interrogator's file-format words (kernel §9). The modalities come from
   [Claims_parser] so they cannot drift from what it accepts. *)
let interrogator =
  ("property" :: List.map fst Writ_syntax.Claims_parser.modalities)
  @ [
      "fair";
      "show";
      "query";
      "where";
      "accept";
      "check";
      "via";
      "functor";
      "from";
      "over";
      "map";
    ]

let dedup xs =
  List.fold_left (fun a x -> if List.mem x a then a else x :: a) [] xs
  |> List.rev

let is_atom = function Reader.Atom _ -> true | _ -> false
let atom_str = function Reader.Atom (s, _) -> [ s ] | _ -> []

let form_head = function
  | Reader.List (Reader.Atom ("form", _) :: rest, _) -> (
      match rest with
      | Reader.Atom (n, _) :: _ -> Some n
      | Reader.List (Reader.Atom (n, _) :: _, _) :: _ -> Some n
      | _ -> None)
  | _ -> None

(* The form heads and offerable values in a datum tree: an enumerated type's
   values and an instance's roster entities. *)
let collect (ds : Reader.t list) : string list * string list =
  let forms = ref [] and vals = ref [] in
  let visit d =
    (match form_head d with Some n -> forms := n :: !forms | None -> ());
    match d with
    | Reader.List (Reader.Atom ("type", _) :: _name :: rest, _) ->
        List.iter
          (function
            | Reader.List (items, _)
              when items <> [] && List.for_all is_atom items ->
                vals := List.concat_map atom_str items @ !vals
            | _ -> ())
          rest
    | Reader.List (Reader.Atom ("instance", _) :: clauses, _) ->
        List.iter
          (function
            | Reader.List (Reader.Atom _ :: (_ :: _ as args), _)
              when List.for_all is_atom args ->
                vals := List.concat_map atom_str args @ !vals
            | _ -> ())
          clauses
    | _ -> ()
  in
  let rec go d =
    visit d;
    match d with Reader.List (xs, _) -> List.iter go xs | Reader.Atom _ -> ()
  in
  List.iter go ds;
  (dedup !forms, dedup !vals)

let read (resolve : Loader.resolve) (name : string) : Reader.t list =
  match resolve name with
  | Ok s -> ( match Reader.read_string s with Ok ds -> ds | Error _ -> [])
  | Error _ -> []

let load_names ds =
  List.filter_map
    (function
      | Reader.List ([ Reader.Atom ("load", _); Reader.Atom (f, _) ], _) ->
          Some f
      | _ -> None)
    ds

(* The [(load "NAME")] targets found lexically, so they survive a buffer that
   does not parse. *)
let lexical_loads (src : string) : string list =
  let n = String.length src in
  let out = ref [] in
  for i = 0 to n - 1 do
    if src.[i] = '(' then (
      let j = ref (i + 1) in
      while !j < n && Scan.is_space src.[!j] do
        incr j
      done;
      let he = Scan.atom_stop src n !j in
      if he > !j && String.sub src !j (he - !j) = "load" then (
        let k = ref he in
        while !k < n && Scan.is_space src.[!k] do
          incr k
        done;
        if !k < n && src.[!k] = '"' then
          match Scan.string_close src n !k with
          | Some stop -> out := String.sub src (!k + 1) (stop - !k - 2) :: !out
          | None -> ()))
  done;
  List.rev !out

(* The buffer's datums plus every library it loads, one level deep (the
   shipped libraries load nothing further). *)
let universe (resolve : Loader.resolve) (src : string) : Reader.t list =
  let bufds = match Reader.read_string src with Ok ds -> ds | Error _ -> [] in
  let loads = dedup (load_names bufds @ lexical_loads src) in
  bufds @ List.concat_map (read resolve) loads

(* Exposed for [Lookup]: the form heads in scope for the buffer. *)
let form_heads_of resolve src = fst (collect (universe resolve src))

(* -------------------------------------------------------------- request *)

let head_items forms =
  List.map (fun k -> item ~detail:"keyword" k 14) (reserved @ interrogator)
  @ List.map (fun n -> item ~detail:"library form" n 13) forms

let value_items vals =
  List.map (fun v -> item ~detail:"value" v 20) (dedup (vals @ [ "vacant" ]))

let at (t : Text.t) ~(resolve : Loader.resolve) pos : Json.t list =
  match Scan.open_form t.Text.src (Text.offset_of_lsp t pos) with
  | None -> []
  | Some f -> (
      let forms, vals = collect (universe resolve t.Text.src) in
      if f.Scan.in_head then head_items forms
      else
        match (f.Scan.head, f.Scan.args) with
        (* (is PATH ▮ / (set PATH ▮ → the value or entity the path takes. *)
        | ("is" | "set"), [ _path ] -> value_items vals
        | _, _ -> [])
