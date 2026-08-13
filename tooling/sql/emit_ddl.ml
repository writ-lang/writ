(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Schema.t] -> CREATE TABLE. The other direction of the one mapping.

   It reads the SCHEMA and nothing else, which is what makes it a reading of the
   model rather than of the file: the instance is one starting configuration,
   not the table's contents, and transitions are moves, not DDL. So there is no
   `--with-data` here — a writ instance exported as INSERTs would be a handful
   of rows with an opaque domain's single member standing in for every string,
   which is data in shape only.

   Two conventions carry what SQL has no way to state, both written as
   `-- writ:` pragmas that [Sql_parse] reads back:

     -- writ: mutable   a foreign key the model UPDATEs
     -- writ: fixed     a non-reference column the model never writes

   Their absence is the common case, so the DDL stays ordinary SQL. *)

open Writ_data

type note = { line : int; what : string; why : string }

let buf_add = Buffer.add_string

(* The flat [arrows] list is authoritative; the per-type one is the fallback a
   schema built only from nested declarations leaves behind (Schema.arrow_in
   makes the same choice). *)
let all_arrows (s : Schema.t) : Schema.arrow list =
  match s.arrows with
  | [] -> List.concat_map (fun (t : Schema.ty) -> t.arrows) s.types
  | l -> l

let arrows_of (s : Schema.t) (t : Schema.ty) : Schema.arrow list =
  match
    List.filter (fun (a : Schema.arrow) -> a.dom = t.name) (all_arrows s)
  with
  | [] -> t.arrows
  | l -> l

(* Open is a table, Enumerated is a domain — and that is not a heuristic but
   the mapping read backwards. A table's rows live in the instance, which is
   exactly what an OPEN type says of its members; a domain's values are fixed
   by the schema, which is what an ENUMERATED type says. *)
let is_table (t : Schema.ty) =
  match t.flavor with Schema.Open -> true | Schema.Enumerated _ -> false

let members (t : Schema.ty) =
  match t.flavor with Schema.Enumerated vs -> vs | Schema.Open -> []

let is_bool (t : Schema.ty) = t.name = "bool" && members t = [ "true"; "false" ]

(* An opaque domain is one whose single member carries no information — which
   is the whole of what "writ cannot look inside a varchar" amounts to. *)
let is_opaque (t : Schema.ty) =
  match members t with [ _ ] -> true | _ -> false

let sql_type_of (s : Schema.t) (cod : string) : string =
  match Schema.type_of s cod with
  | None -> "text"
  | Some t ->
      if is_table t then "text" (* a foreign key matches the synthetic id *)
      else if is_bool t then "boolean"
      else if is_opaque t then Sql_names.sql_of_domain t.name
      else Sql_names.ident_to_sql t.name

let key_column (s : Schema.t) (t : Schema.ty) : string =
  let taken = List.map (fun (a : Schema.arrow) -> a.name) (arrows_of s t) in
  if List.mem "id" taken then "writ_id" else "id"

(* ---- equations as CHECK constraints ------------------------------------- *)

(* The fragment a row-level CHECK can hold: boolean structure over this row's
   own columns. A chain of two arrows leaves the row (`order.buyer.active` is a
   join), and a `some` binder quantifies over a roster — neither is something a
   CHECK constraint can see, so both are reported rather than approximated. *)
let rec sql_of_guard (s : Schema.t) (subject : string) (g : Guard.t) :
    string option =
  let ( let* ) = Option.bind in
  let one_step (p : Value.path) =
    if p.root = subject then
      match p.steps with [ c ] -> Some (Sql_names.ident_to_sql c) | _ -> None
    else None
  in
  match g with
  | Guard.And gs ->
      let* parts = all_of (List.map (sql_of_guard s subject) gs) in
      Some ("(" ^ String.concat " AND " parts ^ ")")
  | Guard.Or gs ->
      let* parts = all_of (List.map (sql_of_guard s subject) gs) in
      Some ("(" ^ String.concat " OR " parts ^ ")")
  | Guard.Not g ->
      let* x = sql_of_guard s subject g in
      Some ("(NOT " ^ x ^ ")")
  | Guard.Defined p ->
      let* c = one_step p in
      Some ("(" ^ c ^ " IS NOT NULL)")
  | Guard.Is (p, Guard.Lit v) ->
      let* c = one_step p in
      (* a boolean column compares against a keyword; everything else against a
         quoted member name *)
      let is_boolean =
        match
          List.find_opt
            (fun (a : Schema.arrow) ->
              a.dom = subject && [ a.name ] = p.Value.steps)
            (all_arrows s)
        with
        | Some a -> (
            match Schema.type_of s a.cod with
            | Some t -> is_bool t
            | None -> false)
        | None -> false
      in
      if is_boolean then Some ("(" ^ c ^ " = " ^ v ^ ")")
      else Some ("(" ^ c ^ " = '" ^ Sql_names.ident_to_sql v ^ "')")
  | Guard.Is (_, Guard.Chain _) | Guard.Some_ _ -> None

and all_of (xs : string option list) : string list option =
  List.fold_right
    (fun x acc ->
      match (x, acc) with Some v, Some l -> Some (v :: l) | _ -> None)
    xs (Some [])

(* ---- the file ----------------------------------------------------------- *)

let ddl (s : Schema.t) : string * note list =
  let b = Buffer.create 4096 in
  let notes = ref [] in
  let note what why = notes := { line = 0; what; why } :: !notes in
  let tables = List.filter is_table s.types in
  let domains = List.filter (fun t -> not (is_table t)) s.types in
  buf_add b
    ("-- Emitted from the writ schema `" ^ s.name
   ^ "` by `writ sql`.\n\
      --\n\
      -- Every type that takes its members from the instance is a table; every\n\
      -- type whose members the schema fixes is a domain. A domain with ONE\n\
      -- member is a value writ carries but cannot look inside, and comes back\n\
      -- as the SQL type its name records.\n\
      --\n\
      -- Each table gets a synthetic key, because a writ entity IS its identity\n\
      -- and carries no column saying so.\n\n");
  (* enumerated domains that are not opaque and not boolean *)
  List.iter
    (fun (t : Schema.ty) ->
      if arrows_of s t <> [] then
        note ("type " ^ t.name)
          "an enumerated type with arrows — a domain has no columns, so its \
           arrows have no table to sit in";
      if (not (is_bool t)) && not (is_opaque t) then
        match members t with
        | [] -> ()
        | ms ->
            buf_add b
              ("CREATE TYPE "
              ^ Sql_names.ident_to_sql t.name
              ^ " AS ENUM ("
              ^ String.concat ", "
                  (List.map (fun m -> "'" ^ Sql_names.ident_to_sql m ^ "'") ms)
              ^ ");\n"))
    domains;
  if List.exists (fun t -> (not (is_bool t)) && not (is_opaque t)) domains then
    buf_add b "\n";
  (* tables *)
  List.iter
    (fun (t : Schema.ty) ->
      let key = key_column s t in
      buf_add b ("CREATE TABLE " ^ Sql_names.ident_to_sql t.name ^ " (\n");
      buf_add b ("    " ^ key ^ " text NOT NULL,\n");
      List.iter
        (fun (a : Schema.arrow) ->
          let is_ref =
            match Schema.type_of s a.cod with
            | Some ct -> is_table ct
            | None -> false
          in
          let pragma =
            if is_ref && not a.fixed then "   -- writ: mutable"
            else if (not is_ref) && a.fixed then "   -- writ: fixed"
            else ""
          in
          buf_add b
            ("    "
            ^ Sql_names.ident_to_sql a.name
            ^ " " ^ sql_type_of s a.cod
            ^ (if a.vacatable then "" else " NOT NULL")
            ^ "," ^ pragma ^ "\n"))
        (arrows_of s t);
      (* the laws whose subject is this table *)
      List.iter
        (fun (e : Schema.equation) ->
          match Guard.free_roots e.body with
          | [ r ] when r = t.name -> (
              match sql_of_guard s t.name e.body with
              | Some sql ->
                  buf_add b
                    ("    CONSTRAINT "
                    ^ Sql_names.ident_to_sql e.name
                    ^ " CHECK " ^ sql ^ ",\n")
              | None ->
                  note ("equation " ^ e.name)
                    "outside what a row-level CHECK can see (a chain through \
                     another table, or a `some` over a roster)")
          | _ -> ())
        s.equations;
      buf_add b ("    PRIMARY KEY (" ^ key ^ ")\n);\n\n"))
    tables;
  (* foreign keys last, so table order never matters *)
  List.iter
    (fun (t : Schema.ty) ->
      List.iter
        (fun (a : Schema.arrow) ->
          match Schema.type_of s a.cod with
          | Some ct when is_table ct ->
              let target = Sql_names.ident_to_sql ct.name in
              buf_add b
                ("ALTER TABLE "
                ^ Sql_names.ident_to_sql t.name
                ^ " ADD CONSTRAINT "
                ^ Sql_names.ident_to_sql (t.name ^ "-" ^ a.name ^ "-fk")
                ^ " FOREIGN KEY ("
                ^ Sql_names.ident_to_sql a.name
                ^ ") REFERENCES " ^ target ^ " (" ^ key_column s ct ^ ");\n")
          | _ -> ())
        (arrows_of s t))
    tables;
  (* equations that belong to no table at all *)
  List.iter
    (fun (e : Schema.equation) ->
      match Guard.free_roots e.body with
      | [ r ] when List.exists (fun (t : Schema.ty) -> t.name = r) tables -> ()
      | _ ->
          note ("equation " ^ e.name)
            "its subject is not a table, so there is no row for a CHECK to \
             range over")
    s.equations;
  (Buffer.contents b, List.rev !notes)
