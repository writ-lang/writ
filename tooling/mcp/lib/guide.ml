(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The writ_guide topics: the language as an LLM client needs it to write a
   model unaided. Written topics are ../guide/*.md, embedded at build time
   (Guide_data); `errors` and `errors.<code>` are generated from Diagnose's
   table, so a code cannot exist without its topic. test_mcp checks every
   example in them still behaves as the text says. *)

let example_block = function
  | Diagnose.Model s -> "```lisp\n; model (model_source)\n" ^ s ^ "```\n"
  | Diagnose.Claims s ->
      "```lisp\n; claims (claims_source), against the model below\n" ^ s
      ^ "```\n"
  | Diagnose.Rules s ->
      "```lisp\n; rules (rules_source), against the model below\n" ^ s ^ "```\n"
  | Diagnose.Call s -> "```\n" ^ s ^ "\n```\n"

let needs_base = function
  | Diagnose.Claims _ | Diagnose.Rules _ -> true
  | _ -> false

let error_topic (e : Diagnose.entry) =
  "**Cause.** " ^ e.cause ^ "\n\n**Fix.** " ^ e.hint ^ "\n\n**Wrong:**\n\n"
  ^ example_block e.wrong ^ "\n**Right:**\n\n" ^ example_block e.right
  ^
  if needs_base e.wrong then
    "\nThe model they are checked against:\n\n```lisp\n" ^ Diagnose.base
    ^ "```\n"
  else ""

let errors_index () =
  "Every error a writ tool returns carries one of these codes, with `found`, \
   `expected`, `hint` and, for a misspelt name, a corrected `fix` line. Ask \
   for `errors.<code>` for a wrong and a right example.\n\n"
  ^ String.concat "\n"
      (List.map
         (fun (e : Diagnose.entry) -> "- `" ^ e.code ^ "`: " ^ e.cause)
         Diagnose.codes)
  ^ "\n"

let topics () : (string * string) list =
  Guide_data.topics
  @ [ ("errors", errors_index ()) ]
  @ List.map
      (fun (e : Diagnose.entry) -> ("errors." ^ e.code, error_topic e))
      Diagnose.codes

let names () = List.map fst (topics ())

(* A topic's one-line summary: its first non-blank line. *)
let summary body =
  match
    List.find_opt
      (fun l -> String.trim l <> "")
      (String.split_on_char '\n' body)
  with
  | Some l -> String.trim l
  | None -> ""

let unknown_listing bad =
  "# unknown topic"
  ^ (if List.length bad > 1 then "s" else "")
  ^ ": " ^ String.concat ", " bad ^ "\n\nValid topics:\n\n"
  ^ String.concat "\n"
      (List.filter_map
         (fun (n, _) ->
           if String.length n > 7 && String.sub n 0 7 = "errors." then None
           else Some ("- `" ^ n ^ "`"))
         (topics ()))
  ^ "\n- `errors.<code>`, one per code listed in `errors`\n"

(* One `# topic.<name>` section per item, in the order asked; unknown names
   get the valid list rather than an error. A trailing `topic.` is accepted,
   since clients echo the heading back. *)
let get (items : string list) : string =
  let all = topics () in
  let strip n =
    if String.length n > 6 && String.sub n 0 6 = "topic." then
      String.sub n 6 (String.length n - 6)
    else n
  in
  let items = List.map (fun n -> strip (String.trim n)) items in
  let items = if items = [] then [ "index" ] else items in
  let found, bad =
    List.partition_map
      (fun n ->
        match List.assoc_opt n all with
        | Some body -> Left ("# topic." ^ n ^ "\n\n" ^ body)
        | None -> Right n)
      items
  in
  String.concat "\n\n" (found @ if bad = [] then [] else [ unknown_listing bad ])
