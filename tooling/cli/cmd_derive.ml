(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ derive] (extension §4): run a .rules file over a model's state space
   and print what it derives. A bare RELATION lists every row, a
   [(RELATION ARG…)] datum binds the non-ALL-CAPS arguments, and [--why]
   explains one ground fact.

   Exit is 0 for any well-formed query, including an empty answer, and 2 for
   unreadable input such as an undeclared relation; never 1 (§9, kernel §18). *)

open Writ_data
open Writ_syntax
open Writ_runtime
open Cli_io

(* The query is read by the language's own reader, so [(reach 0 X)] parses as
   in a file. An ALL-CAPS term ([Rules.is_var]) is an unbound column; anything
   else is a constant, read against its column's sort by [Derive_table]. *)
let parse_ask (spec : string) : string * string option list option =
  let arg (d : Reader.t) : string option =
    match d with
    | Reader.Atom (a, _) -> if Rules.is_var a then None else Some a
    | Reader.List _ ->
        die 2 ("a query argument is an atom, not a list: " ^ Reader.to_string d)
  in
  match Reader.read_string spec with
  | Ok [ Reader.Atom (r, _) ] -> (r, None)
  | Ok [ Reader.List (Reader.Atom (r, _) :: ts, _) ] ->
      (r, Some (List.map arg ts))
  | _ -> die 2 ("a query is a relation name or a (RELATION ARG…) datum: " ^ spec)

(* [--why] explains one fact, so every column must be given. *)
let ground (spec : string) (args : string option list) : string list =
  List.map
    (function
      | Some a -> a
      | None ->
          die 2
            ("--why needs a fact with every argument given, not a variable: "
           ^ spec))
    args

let run ?(json = false) (model : string) (rules_path : string) ~(why : bool)
    (spec : string) =
  let m = load_model (make_resolve model) model in
  let sp = build_space model m in
  (* Its own resolver: loads search the including file's directory first (D3),
     and the rules file need not sit beside the model. *)
  let prog = read_rules (make_resolve rules_path) m rules_path in
  (* Parse the question first so the fixpoint computes only what it needs
     ([Derive.cone]). *)
  let rel, given = parse_ask spec in
  let t = Derive.run ~only:rel sp prog in
  let arity =
    match Derive_answers.sorts_of t rel with
    | Some ss -> List.length ss
    (* An undeclared relation is an author error, not an empty answer. *)
    | None -> die 2 ("no relation named `" ^ rel ^ "` in " ^ rules_path)
  in
  let args =
    match given with None -> List.init arity (fun _ -> None) | Some a -> a
  in
  if List.length args <> arity then
    die 2
      (rel ^ " takes " ^ string_of_int arity ^ " arguments, not "
      ^ string_of_int (List.length args)
      ^ ": " ^ spec);
  let render_rows tuples =
    if json then Json.to_string (Report_json.derive_rows t rel tuples)
    else Report_derive.rows t rel tuples
  in
  let render_why args =
    if json then Json.to_string (Report_json.derive_why t rel args)
    else Report_derive.why t rel args
  in
  let answer =
    if why then render_why (ground spec args)
    else
      match Derive_answers.query t rel args with
      | Some (Ok tuples) -> render_rows tuples
      (* A constant of the wrong sort is rejected as the .rules parser would. *)
      | Some (Error (i, srt)) ->
          die 2
            ("`"
            ^ Option.value ~default:"?" (List.nth args i)
            ^ "` is not " ^ Rules_terms.sort_name srt
            ^ ", which is what column "
            ^ string_of_int (i + 1)
            ^ " of `" ^ rel ^ "` takes")
      (* Unreachable: the arity and the declaration were both checked above. *)
      | None -> die 2 ("no relation named `" ^ rel ^ "` in " ^ rules_path)
  in
  say answer;
  flush stdout;
  exit 0
