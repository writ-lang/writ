(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Extension §9's output for `writ derive`: a relation's rows and the
   derivation tree behind one fact, as pure strings. The row shape resembles
   [Report.query_rows], but a derived relation has no query datum, no "at"
   situation, and positional columns, so it is rendered separately. *)

(* ── Atoms ───────────────────────────────────────────────────────────────── *)

(* A situation prints as its bare index ([0], [3]), never [s0], which could be
   a legal entity name. Notation is sort-directed, so a bound query can name a
   situation by typing [0]. *)

let indent (depth : int) : string = String.make (2 * depth) ' '

let path (p : Value.path) : string =
  String.concat "." (p.Value.root :: p.Value.steps)

(* A kernel guard as its source datum, unparenthesised for a bare leaf line;
   nested operands get their parentheses back. *)
let rec guard (g : Model.guard) : string =
  match g with
  | Model.Is (p, Model.Lit v) -> "is " ^ path p ^ " " ^ v
  | Model.Is (p, Model.Chain q) -> "is " ^ path p ^ " " ^ path q
  | Model.Defined p -> "defined " ^ path p
  | Model.And gs -> "and " ^ operands gs
  | Model.Or gs -> "or " ^ operands gs
  | Model.Not g -> "not " ^ nested g
  | Model.Some_ (x, ty, g) -> "some (" ^ x ^ " " ^ ty ^ ") " ^ nested g

and nested (g : Model.guard) : string = "(" ^ guard g ^ ")"

and operands (gs : Model.guard list) : string =
  String.concat " " (List.map nested gs)

(* ── Rows (§9) ───────────────────────────────────────────────────────────── *)

let atom_row (t : Derive_table.t) (rel : string) (tup : int array) : string =
  "  " ^ String.concat "  " (Derive_answers.row t rel tup)

(* A header with the row count, then the rows. The count makes an empty answer
   (§9) look like an answer rather than a truncated report. *)
let rows (t : Derive_table.t) (rel : string) (tuples : int array list) : string
    =
  let n = List.length tuples in
  let header =
    rel ^ "  (" ^ string_of_int n ^ if n = 1 then " row)" else " rows)"
  in
  String.concat "\n" (header :: List.map (atom_row t rel) tuples)

(* ── Derivation trees (§7) ───────────────────────────────────────────────── *)

let fact_text (t : Derive_table.t) (f : Rules.fact) : string =
  String.concat " "
    (f.Rules.rel :: Derive_answers.row t f.Rules.rel f.Rules.args)

(* Two spaces of indent per level. Three kinds of premise are leaves, printed
   differently because they are justified differently:
   - an extensional fact ([edge nabu-speaks 0 1]), read off [Space.t];
   - a ground guard ([is nabu.reports-to mid]), in kernel guard syntax;
   - a completed-stratum negation ([not q mid]), justified by stratification. *)
let rec node (t : Derive_table.t) (depth : int) (id : Rules.fact_id) :
    string list =
  let line =
    indent depth
    ^
    match Derive_answers.fact t id with
    | Some f -> fact_text t f
    | None -> "?"
  in
  match Derive_answers.derivation t id with
  | None -> [ line ]
  | Some d -> line :: List.concat_map (premise t (depth + 1)) d.Rules.premises

and premise (t : Derive_table.t) (depth : int) (p : Rules.premise) : string list
    =
  match p with
  | Rules.Premise_fact id -> node t depth id
  | Rules.Premise_guard g -> [ indent depth ^ guard g ]
  | Rules.Premise_absent (rel, args) ->
      [
        indent depth ^ "not "
        ^ String.concat " " (rel :: Derive_answers.row t rel args);
      ]

(* [--why] on an underived fact is an answer (§7): it is named and reported
   "not derived", and the caller exits 0. *)
let why (t : Derive_table.t) (rel : string) (args : string list) : string =
  let asked = String.concat " " (rel :: args) in
  match Derive_answers.fact_id t rel args with
  | None -> asked ^ "\n" ^ indent 1 ^ "not derived"
  | Some id -> String.concat "\n" (node t 0 id)
