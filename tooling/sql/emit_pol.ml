(* [Sql_ast.db] -> a .pol file, as text.

   Text rather than datums, and the reason is not convenience: the output is a
   model a person now OWNS. They will add transitions to it, write claims
   against it, and read it to find out what their database actually says — so
   it has to be commented, grouped, and spelled the way a person would spell
   it. A datum tree pretty-printed by the parser would be none of those.

   The shape of the file is fixed:

     the vocabulary   forms, one per domain actually used
     the schema       domains, then tables, then the laws that survived
     the instance     the seed rows, or an empty roster to fill in

   The vocabulary is generated rather than shipped. A stock `psql.lib.pol`
   could not hold a form for every `varchar(n)` anyone might declare, and a
   library that covered only the common widths would push the rest into a
   second mechanism. Generating exactly the forms this database needs keeps one
   mechanism and leaves the stdlib the only .pol the tool ships. *)

open Sql_ast

let buf_add = Buffer.add_string

(* ---- what the database uses --------------------------------------------- *)

type usage = {
  domains : Sql_names.domain list;  (** every distinct column domain *)
  members : (string * string) list;  (** opaque domain -> its single member *)
  nullable_of : string list;  (** domains needing the `?` form too *)
  refs_total : bool;
  refs_null : bool;
  refs_mutable : bool;
  refs_mutable_null : bool;
}

(* The primary key dissolves into the entity's identity — an entity IS the
   thing the key names, so a column repeating it is a column saying nothing.
   Unless it is ALSO a foreign key, in which case dropping it would drop an
   arrow, and the arrow is the part that means something. *)
let dissolved (t : table) (c : column) = t.pk = [ c.cname ] && c.refs = None
let carried (t : table) = List.filter (fun c -> not (dissolved t c)) t.columns

let usage_of (db : db) : usage =
  let cols = List.concat_map (fun t -> carried t) db.tables in
  let doms =
    List.sort_uniq compare
      (List.filter_map
         (fun c -> if c.refs = None then Some c.domain else None)
         cols)
  in
  let taken = ref [] in
  let members =
    List.filter_map
      (fun d ->
        match d with
        | Sql_names.Opaque n ->
            let m = Sql_names.member_for ~taken:!taken n in
            taken := m :: !taken;
            Some (n, m)
        | _ -> None)
      doms
  in
  let nullable_of =
    List.sort_uniq compare
      (List.filter_map
         (fun c ->
           if c.refs = None && c.nullable then
             Some (Sql_names.domain_name c.domain)
           else None)
         cols)
  in
  let has p = List.exists p cols in
  {
    domains = doms;
    members;
    nullable_of;
    refs_total = has (fun c -> c.refs <> None && c.fixed && not c.nullable);
    refs_null = has (fun c -> c.refs <> None && c.fixed && c.nullable);
    refs_mutable =
      has (fun c -> c.refs <> None && (not c.fixed) && not c.nullable);
    refs_mutable_null =
      has (fun c -> c.refs <> None && (not c.fixed) && c.nullable);
  }

(* ---- the vocabulary ----------------------------------------------------- *)

let emit_forms (b : Buffer.t) (u : usage) =
  buf_add b
    ";; ---- the SQL vocabulary, as forms over the 26 words ----\n\
     ;;\n\
     ;; A domain type and its column form SHARE ONE NAME. That is legal, and\n\
     ;; it is what makes a column two tokens: a form with slots only expands\n\
     ;; in list-HEAD position, so the same word inside `(to …)` stays data.\n\n";
  List.iter
    (fun d ->
      let n = Sql_names.domain_name d in
      buf_add b ("(form (" ^ n ^ " A) (arrow A (to " ^ n ^ ")))\n");
      if List.mem n u.nullable_of then
        buf_add b ("(form (" ^ n ^ "? A) (arrow A (to " ^ n ^ ") vacatable))\n"))
    u.domains;
  if u.refs_total || u.refs_null || u.refs_mutable || u.refs_mutable_null then begin
    buf_add b
      "\n\
       ;; References. `fk` is a key you never UPDATE — wiring, so it is not\n\
       ;; part of a state at all and costs the space nothing. `ref` is one you\n\
       ;; do; the export records the difference in a `-- pol:` pragma, because\n\
       ;; SQL has no way to state it.\n";
    if u.refs_total then buf_add b "(form (fk   A T) (arrow A (to T) fixed))\n";
    if u.refs_null then
      buf_add b "(form (fk?  A T) (arrow A (to T) fixed vacatable))\n";
    if u.refs_mutable then buf_add b "(form (ref  A T) (arrow A (to T)))\n";
    if u.refs_mutable_null then
      buf_add b "(form (ref? A T) (arrow A (to T) vacatable))\n"
  end

(* ---- guards ------------------------------------------------------------- *)

let rec guard (subject : string) (c : check) : string =
  let path col = subject ^ "." ^ col in
  match c with
  | C_and cs -> "(and " ^ String.concat " " (List.map (guard subject) cs) ^ ")"
  | C_or cs -> "(or " ^ String.concat " " (List.map (guard subject) cs) ^ ")"
  | C_not x -> "(not " ^ guard subject x ^ ")"
  | C_null col -> "(not (defined " ^ path col ^ "))"
  | C_notnull col -> "(defined " ^ path col ^ ")"
  | C_is (col, v) -> "(is " ^ path col ^ " " ^ Sql_names.ident_to_pol v ^ ")"
  | C_in (col, [ v ]) ->
      "(is " ^ path col ^ " " ^ Sql_names.ident_to_pol v ^ ")"
  | C_in (col, vs) ->
      "(or "
      ^ String.concat " "
          (List.map
             (fun v -> "(is " ^ path col ^ " " ^ Sql_names.ident_to_pol v ^ ")")
             vs)
      ^ ")"

(* ---- the schema --------------------------------------------------------- *)

let column_datum (c : column) : string =
  match c.refs with
  | Some t ->
      let head =
        match (c.fixed, c.nullable) with
        | true, false -> "fk"
        | true, true -> "fk?"
        | false, false -> "ref"
        | false, true -> "ref?"
      in
      "(" ^ head ^ " " ^ c.cname ^ " " ^ t ^ ")"
  | None ->
      let n = Sql_names.domain_name c.domain in
      if c.fixed then
        (* A non-reference column that is never written is rare — it only
           arises on the way back from a model somebody wrote by hand — and it
           would need a second sigil to sugar. So it stays spelled out in the
           kernel, which is also the reading of the `-- pol: fixed` pragma that
           carried it: wiring, not state. *)
        "(arrow " ^ c.cname ^ " (to " ^ n ^ ") fixed"
        ^ (if c.nullable then " vacatable" else "")
        ^ ")"
      else "(" ^ n ^ (if c.nullable then "?" else "") ^ " " ^ c.cname ^ ")"

let emit_schema (b : Buffer.t) (name : string) (db : db) (u : usage) =
  buf_add b ("\n(schema " ^ name ^ "\n");
  buf_add b
    "\n\
    \  ;; ---- domains ----\n\
    \  ;; An opaque domain has ONE member, so a total arrow into it has one\n\
    \  ;; filling: a NOT NULL scalar column costs the state space nothing. A\n\
    \  ;; nullable one costs a factor of two, which is the one distinction pol\n\
    \  ;; can decide about a varchar — whether it is there.\n";
  List.iter
    (fun d ->
      match d with
      | Sql_names.Bool -> buf_add b "  (type bool (true false))\n"
      | Sql_names.Enum _ -> ()
      | Sql_names.Opaque n ->
          let m = try List.assoc n u.members with Not_found -> n ^ "*" in
          buf_add b ("  (type " ^ n ^ " (" ^ m ^ "))\n"))
    u.domains;
  (* only the enums a column actually lands in: a declared type no arrow
     reaches is a name taken out of the global space for nothing *)
  let used = List.map Sql_names.domain_name u.domains in
  List.iter
    (fun e ->
      if List.mem e.ename used then
        buf_add b
          ("  (type " ^ e.ename ^ " (" ^ String.concat " " e.emembers ^ "))\n"))
    db.enums;
  buf_add b "\n  ;; ---- tables ----\n";
  List.iter
    (fun t ->
      (match t.comment with
      | Some c -> buf_add b ("  ; " ^ c ^ "\n")
      | None -> ());
      buf_add b ("  (type " ^ t.tname);
      (match carried t with
      | [] -> ()
      | cols ->
          List.iter
            (fun c ->
              buf_add b ("\n    " ^ column_datum c);
              match c.comment with
              | Some cm -> buf_add b ("   ; " ^ cm)
              | None -> ())
            cols);
      buf_add b ")\n")
    db.tables;
  let laws =
    List.concat_map (fun t -> List.map (fun ck -> (t, ck)) t.checks) db.tables
  in
  if laws <> [] then begin
    buf_add b
      "\n\
      \  ;; ---- laws ----\n\
      \  ;; A CHECK is a claim the world is measured against, not a filter on\n\
      \  ;; it: `pol check` reports not only where a law is broken but WHICH\n\
      \  ;; move can break it.\n";
    List.iter
      (fun (t, (n, c)) ->
        buf_add b ("  (equation " ^ n ^ "\n    " ^ guard t.tname c ^ ")\n"))
      laws
  end;
  buf_add b ")\n"

(* ---- the instance ------------------------------------------------------- *)

let value_for (db : db) (u : usage) (c : column) (v : string option) : string =
  match v with
  | None -> "vacant"
  | Some raw -> (
      match c.refs with
      | Some _ -> Sql_names.ident_to_pol raw
      | None -> (
          match c.domain with
          | Sql_names.Bool ->
              if String.lowercase_ascii raw = "t" then "true"
              else if String.lowercase_ascii raw = "f" then "false"
              else Sql_names.ident_to_pol raw
          | Sql_names.Enum _ -> Sql_names.ident_to_pol raw
          | Sql_names.Opaque n -> (
              ignore db;
              try List.assoc n u.members with Not_found -> n ^ "*")))

let emit_instance (b : Buffer.t) (name : string) (db : db) (u : usage) =
  buf_add b ("\n(instance seed " ^ name);
  if db.rows = [] then
    buf_add b
      "\n\
      \  ; No rows were read. An instance is ONE starting configuration, not a\n\
      \  ; data dump — name the few entities your question is about and give\n\
      \  ; each arrow a value.\n"
  else
    List.iter
      (fun r ->
        match table_named db r.rtable with
        | None -> ()
        | Some t ->
            let pk = match t.pk with [ p ] -> p | _ -> "" in
            let ent =
              match List.assoc_opt pk r.rvals with
              | Some (Some v) -> Sql_names.ident_to_pol v
              | _ -> ""
            in
            if ent <> "" then begin
              buf_add b ("\n  (" ^ t.tname ^ " " ^ ent);
              List.iter
                (fun c ->
                  let v =
                    match List.assoc_opt c.cname r.rvals with
                    | Some v -> v
                    | None -> if c.nullable then None else Some ""
                  in
                  let v =
                    match v with
                    | Some "" when c.refs = None -> Some "x"
                    | other -> other
                  in
                  buf_add b (" (" ^ c.cname ^ " " ^ value_for db u c v ^ ")"))
                (carried t);
              buf_add b ")"
            end)
      db.rows;
  buf_add b ")\n"

(* ---- the file ----------------------------------------------------------- *)

(* Two names in one global space (kernel §7) is a redeclaration, and the one
   way this mapping can produce one is a table named after a SQL type. Reported
   rather than repaired: renaming the domain would break the export, since the
   codomain's name IS the column's type on the way back. *)
let name_clashes (db : db) (u : usage) : decline list =
  let domain_names =
    List.map Sql_names.domain_name u.domains
    @ List.map (fun e -> e.ename) db.enums
  in
  List.filter_map
    (fun t ->
      if List.mem t.tname domain_names then
        Some
          {
            dline = t.tline;
            what = "table " ^ t.sql_tname;
            why =
              "collides with the domain of the same name — types and entities \
               share one namespace";
          }
      else None)
    db.tables

let file ~(name : string) ~(source : string) (db : db) : string * decline list =
  let u = usage_of db in
  let b = Buffer.create 4096 in
  buf_add b
    (";; " ^ name ^ ".pol — read from " ^ source
   ^ " by `pol sql`.\n\
      ;;\n\
      ;; A relational schema IS a finitely presented category, so this is a\n\
      ;; reading rather than a translation: a table is a type, a foreign key\n\
      ;; is an arrow, NULL is `vacatable`, an enum keeps its members. What a\n\
      ;; column's value MEANS crosses only where it has finitely many values\n\
      ;; worth naming; everything else is present, and opaque.\n\
      ;;\n\
      ;; What the DDL said and this file does not is on stderr, by line.\n\n");
  emit_forms b u;
  emit_schema b name db u;
  emit_instance b name db u;
  buf_add b ("\n(use " ^ name ^ ")\n(initial seed)\n");
  (Buffer.contents b, name_clashes db u)
