(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The document outline, walked off the [Reader] datum tree ([Model] keeps no
   positions), so it survives a document that does not type-check. A symbol's
   range must enclose its selectionRange or the client rejects the response:
   the range is the whole form, the selectionRange its name. *)

open Writ_syntax

(* LSP SymbolKind codes; cosmetic. *)
let k_schema = 3 (* Namespace *)
let k_type = 5 (* Class *)
let k_arrow = 8 (* Field *)
let k_instance = 19 (* Object *)
let k_transition = 24 (* Event *)
let k_equation = 7 (* Property *)
let k_form = 12 (* Function *)
let k_property = 17 (* Boolean — a claim *)
let k_query = 6 (* Method *)
let k_accept = 20 (* Key — an acknowledged equation breakage *)
let sel_range t d = Text.token_range t (Text.lsp_of_pos t (Reader.pos_of d))
let whole_range t d = Text.form_range t (Text.lsp_of_pos t (Reader.pos_of d))

let sym ~kind ~name ~whole ~sel ~children =
  Json.Assoc
    [
      ("name", Json.String name);
      ("kind", Json.Int kind);
      ("range", Text.json_of_range whole);
      ("selectionRange", Text.json_of_range sel);
      ("children", Json.List children);
    ]

let one t d ~kind ~namedatum ~children name =
  [
    sym ~kind ~name ~whole:(whole_range t d) ~sel:(sel_range t namedatum)
      ~children;
  ]

let kind_of = function
  | "schema" -> k_schema
  | "type" -> k_type
  | "arrow" -> k_arrow
  | "instance" -> k_instance
  | "transition" -> k_transition
  | "equation" -> k_equation
  | "property" -> k_property
  | "query" -> k_query
  | "accept" -> k_accept
  | _ -> k_form

(* Forms nested in a schema or type become its children. *)
let is_container = function "schema" | "type" -> true | _ -> false

let rec of_forms t ds = List.concat_map (of_form t) ds

and named t d head rest =
  match rest with
  | (Reader.Atom (n, _) as nd) :: more ->
      let children = if is_container head then of_forms t more else [] in
      one t d ~kind:(kind_of head) ~namedatum:nd ~children n
  (* An unnamed transition — [(transition (when …) …)] — yields no symbol. *)
  | _ -> []

(* A form is named by its pattern: [(form NAME …)] or [(form (NAME …) …)]. *)
and form_sym t d rest =
  match rest with
  | (Reader.Atom (n, _) as nd) :: _ ->
      one t d ~kind:k_form ~namedatum:nd ~children:[] n
  | Reader.List ((Reader.Atom (n, _) as nd) :: _, _) :: _ ->
      one t d ~kind:k_form ~namedatum:nd ~children:[] n
  | _ -> []

and of_form t d =
  match d with
  | Reader.List (Reader.Atom (head, _) :: rest, _) -> (
      match head with
      | "form" -> form_sym t d rest
      | "schema" | "type" | "arrow" | "instance" | "transition" | "equation"
      | "property" | "query" | "accept" ->
          named t d head rest
      | _ -> [])
  | Reader.List (_, _) | Reader.Atom _ -> []

let of_text (t : Text.t) : Json.t list =
  match Reader.read_string t.Text.src with
  | Ok ds -> of_forms t ds
  | Error _ -> []
