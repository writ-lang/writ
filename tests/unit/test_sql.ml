(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* `pol sql` unit tests.

   The load-bearing one is the ROUND TRIP, and it is checked the strong way:
   not by diffing two texts, but by reading each side back through the real
   front end and comparing the two SCHEMAS. Text equality would be the wrong
   oracle anyway — the export normalises spellings on purpose (`character
   varying(255)` comes back as `varchar(255)`), so a text diff would report a
   difference that is not one, and, worse, would pass if both sides were
   equally wrong. Comparing the olog compares what the mapping claims to
   preserve.

   The rest of the file is the boundary: what the DDL says that pol declines,
   asserted to be declined rather than quietly half-carried. Those tests fail
   loudly the day someone "improves" the parser into guessing. *)

open Pol_data
open Pol_syntax
open Pol_sql

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let contains ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

let model_of_string (what : string) (s : string) : Model.t =
  match Reader.read_string s with
  | Error e -> failwith (what ^ ": read: " ^ Errors.to_string e)
  | Ok ds -> (
      match Expander.expand ds with
      | Error e -> failwith (what ^ ": expand: " ^ Errors.to_string e)
      | Ok ds -> (
          match Parser.parse_model ds with
          | Error e -> failwith (what ^ ": parse: " ^ Errors.to_string e)
          | Ok m -> m))

let import ?(name = "t") (sql : string) : string * Sql_ast.db =
  let db = Sql_parse.parse sql in
  let text, _ = Emit_pol.file ~name ~source:"t.sql" db in
  (text, db)

(* The schema as a comparable value: every type with its members, every arrow
   with the two flags that decide what a state IS, every law by name and body. *)
let projection (s : Schema.t) =
  let arrows_of (t : Schema.ty) =
    let flat =
      List.filter (fun (a : Schema.arrow) -> a.dom = t.name) s.arrows
    in
    let l = if flat = [] then t.arrows else flat in
    List.sort compare
      (List.map
         (fun (a : Schema.arrow) -> (a.name, a.cod, a.fixed, a.vacatable))
         l)
  in
  ( List.sort compare
      (List.map
         (fun (t : Schema.ty) ->
           ( t.name,
             (match t.flavor with
             | Schema.Enumerated vs -> vs
             | Schema.Open -> []),
             arrows_of t ))
         s.types),
    List.sort compare
      (List.map (fun (e : Schema.equation) -> e.name) s.equations) )

let round_trip (what : string) (sql : string) =
  let pol1, _ = import sql in
  let m1 = model_of_string (what ^ " (in)") pol1 in
  let ddl, _ = Emit_ddl.ddl m1.Model.schema in
  let pol2, _ = import ddl in
  let m2 = model_of_string (what ^ " (back)") pol2 in
  check
    (what ^ ": schema survives the round trip")
    (projection m1.Model.schema = projection m2.Model.schema);
  (m1, ddl)

(* --- the mapping, both directions ---------------------------------------- *)

let shop_sql =
  {|
CREATE TYPE order_status AS ENUM ('draft', 'shipped', 'void');
CREATE TABLE customers (
    id         uuid PRIMARY KEY,
    email      varchar(255) NOT NULL,
    active     boolean NOT NULL,
    tier       text CHECK (tier IN ('free', 'pro'))
);
CREATE TABLE orders (
    id         uuid PRIMARY KEY,
    buyer_id   uuid NOT NULL REFERENCES customers(id),
    status     order_status NOT NULL,
    total      numeric(10,2) NOT NULL,
    shipped_at timestamptz,
    CONSTRAINT shipped_needs_stamp
      CHECK (status <> 'shipped' OR shipped_at IS NOT NULL)
);
|}

let () =
  let m, _ = round_trip "shop" shop_sql in
  let s = m.Model.schema in
  let ty n = Schema.type_of s n in
  let arrow dom n = Schema.arrow_in s ~dom n in
  (* a table is a type, and its members come from the instance *)
  check "table -> open type"
    (match ty "orders" with
    | Some { flavor = Schema.Open; _ } -> true
    | _ -> false);
  (* the primary key dissolves: an entity IS its identity *)
  check "single-column primary key emits no arrow" (arrow "orders" "id" = None);
  (* a foreign key is an arrow, and wiring by default *)
  check "foreign key -> fixed arrow"
    (match arrow "orders" "buyer-id" with
    | Some a -> a.cod = "customers" && a.fixed && not a.vacatable
    | None -> false);
  (* NULL is vacatable; NOT NULL is total *)
  check "NULL -> vacatable"
    (match arrow "orders" "shipped-at" with
    | Some a -> a.vacatable
    | None -> false);
  check "NOT NULL -> total"
    (match arrow "orders" "total" with
    | Some a -> not a.vacatable
    | None -> false);
  (* an opaque domain has exactly ONE member: that is what makes a NOT NULL
     scalar column cost the state product nothing *)
  check "opaque domain has one member"
    (match ty "numeric-10-2" with
    | Some { flavor = Schema.Enumerated [ _ ]; _ } -> true
    | _ -> false);
  (* the scalars whose values are worth naming keep them *)
  check "boolean keeps its two members"
    (match ty "bool" with
    | Some { flavor = Schema.Enumerated [ "true"; "false" ]; _ } -> true
    | _ -> false);
  check "enum keeps its members"
    (match ty "order-status" with
    | Some { flavor = Schema.Enumerated [ "draft"; "shipped"; "void" ]; _ } ->
        true
    | _ -> false);
  (* a CHECK … IN over a textual column IS the column's type, not a law *)
  check "CHECK IN promotes to an enumerated domain"
    (match ty "customers-tier" with
    | Some { flavor = Schema.Enumerated [ "free"; "pro" ]; _ } -> true
    | _ -> false);
  (* a single-row CHECK becomes a law — the thing `pol check` then reports a
     move can BREAK *)
  check "CHECK -> equation"
    (List.exists
       (fun (e : Schema.equation) -> e.name = "shipped-needs-stamp")
       s.equations)

(* --- what SQL says and pol declines -------------------------------------- *)

let declined_for ~(sub : string) (sql : string) =
  let _, db = import sql in
  List.exists (fun (d : Sql_ast.decline) -> contains ~sub d.why) db.declines

let () =
  (* UNIQUE is unsayable, not unimplemented: a pol law ranges over ONE entity
     of its subject type, and a bare `some` binder is not comparable, so "two
     distinct rows agree" has no spelling at all. *)
  check "UNIQUE column constraint is declined"
    (declined_for ~sub:"UNIQUE"
       "CREATE TABLE t (id text PRIMARY KEY, a text UNIQUE);");
  check "UNIQUE table constraint is declined"
    (declined_for ~sub:"UNIQUE"
       "CREATE TABLE t (id text PRIMARY KEY, a text, UNIQUE (a));");
  check "CREATE UNIQUE INDEX is declined"
    (declined_for ~sub:"UNIQUE" "CREATE UNIQUE INDEX i ON t (a);");
  (* arithmetic has no reading in a language with no numbers *)
  check "an arithmetic CHECK is declined"
    (declined_for ~sub:"expressible fragment"
       "CREATE TABLE t (id text PRIMARY KEY, n int CHECK (n > 0));");
  (* comparing an opaque column to a literal names a member that cannot exist *)
  check "a CHECK against an opaque column is declined"
    (declined_for ~sub:"opaque domain"
       "CREATE TABLE t (id text PRIMARY KEY, a text, b text, CONSTRAINT c \
        CHECK (a = 'x' OR b IS NOT NULL));");
  check "a composite primary key is declined"
    (declined_for ~sub:"composite key"
       "CREATE TABLE t (a text NOT NULL, b text NOT NULL, PRIMARY KEY (a, b));");
  check "an array column is declined"
    (declined_for ~sub:"array column"
       "CREATE TABLE t (id text PRIMARY KEY, xs text[]);");
  check "DEFAULT is declined"
    (declined_for ~sub:"DEFAULT"
       "CREATE TABLE t (id text PRIMARY KEY, a text DEFAULT 'x');")

(* --- the junction table still crosses ------------------------------------ *)

let () =
  let sql =
    "CREATE TABLE a (id text PRIMARY KEY);\n\
     CREATE TABLE b (id text PRIMARY KEY);\n\
     CREATE TABLE ab (a_id text NOT NULL REFERENCES a(id), b_id text NOT NULL \
     REFERENCES b(id), PRIMARY KEY (a_id, b_id));"
  in
  let m, _ = round_trip "junction" sql in
  let s = m.Model.schema in
  (* the CONSTRAINT is declined; the TABLE is not. Note it does NOT become
     stdlib's `span`, which fixes the arrow names to left/right and would
     discard the column names the export needs. *)
  check "junction table keeps both arrows under their own names"
    (match
       (Schema.arrow_in s ~dom:"ab" "a-id", Schema.arrow_in s ~dom:"ab" "b-id")
     with
    | Some x, Some y -> x.cod = "a" && y.cod = "b"
    | _ -> false)

(* --- pg_dump, which is the only input that matters in practice ----------- *)

let () =
  let sql =
    {|
SET statement_timeout = 0;
CREATE FUNCTION public.touch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();   -- a semicolon; and another;
  RETURN NEW;
END;
$$;
CREATE TABLE public.orders (
    id uuid NOT NULL,
    status character varying(20) NOT NULL,
    shipped_at timestamp with time zone,
    CONSTRAINT orders_status_check CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'shipped'::character varying])::text[]))),
    CONSTRAINT orders_shipped CHECK ((((status)::text <> 'shipped'::text) OR (shipped_at IS NOT NULL)))
);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_pkey PRIMARY KEY (id);
|}
  in
  let m, _ = round_trip "pg_dump" sql in
  let s = m.Model.schema in
  (* the dollar-quoted body holds three semicolons; if the splitter counted
     them the table would have been cut into fragments and nothing below would
     hold *)
  check "a dollar-quoted body does not split statements"
    (Schema.type_of s "orders" <> None);
  check "the schema qualifier is dropped, not folded into the name"
    (Schema.type_of s "public-orders" = None);
  check "`character varying(20)` folds onto varchar-20"
    (match Schema.arrow_in s ~dom:"orders" "status" with
    | Some a -> a.cod = "orders-status"
    | None -> false);
  check "= ANY (ARRAY[…]) is read as IN (…)"
    (match Schema.type_of s "orders-status" with
    | Some { flavor = Schema.Enumerated [ "draft"; "shipped" ]; _ } -> true
    | _ -> false);
  check "`timestamp with time zone` folds onto timestamptz"
    (match Schema.arrow_in s ~dom:"orders" "shipped-at" with
    | Some a -> a.cod = "timestamptz" && a.vacatable
    | None -> false);
  check "a primary key added by ALTER TABLE still dissolves"
    (Schema.arrow_in s ~dom:"orders" "id" = None);
  check "the cast-laden CHECK still becomes a law"
    (List.exists
       (fun (e : Schema.equation) -> e.name = "orders-shipped")
       s.equations)

(* --- what only a pragma can carry ---------------------------------------- *)

(* Mutability is the one column fact SQL cannot state: a foreign key the model
   UPDATEs and one it never touches are the same DDL. Without the pragma the
   export would be lossy in a way no re-import could detect, so this test is
   the round trip's real edge. *)
let () =
  let pol =
    "(form (text A) (arrow A (to text)))\n\
     (form (ref A T) (arrow A (to T)))\n\
     (schema m\n\
    \  (type text (txt))\n\
    \  (type a (text label))\n\
    \  (type b (ref link a) (arrow note (to text) fixed)))\n\
     (instance seed m)\n\
     (use m) (initial seed)\n"
  in
  let m1 = model_of_string "pragma" pol in
  let ddl, _ = Emit_ddl.ddl m1.Model.schema in
  check "a mutable foreign key exports a pragma"
    (contains ~sub:"-- pol: mutable" ddl);
  check "a fixed non-reference column exports a pragma"
    (contains ~sub:"-- pol: fixed" ddl);
  let pol2, _ = import ~name:"m" ddl in
  let m2 = model_of_string "pragma (back)" pol2 in
  check "mutability survives the round trip"
    (projection m1.Model.schema = projection m2.Model.schema)

(* --- names ---------------------------------------------------------------- *)

let () =
  check "identifier translation inverts"
    (Sql_names.ident_to_sql (Sql_names.ident_to_pol "shipped_at") = "shipped_at");
  check "a parameterised domain re-acquires its parentheses"
    (Sql_names.sql_of_domain "varchar-255" = "varchar(255)");
  check "a multi-word type keeps its space"
    (Sql_names.sql_of_domain "double-precision" = "double precision");
  check "a user-defined domain keeps its underscore"
    (Sql_names.sql_of_domain "order-status" = "order_status");
  (* members share the global namespace with types and entities (kernel §7) *)
  check "a colliding member falls back to a spelling nothing else can take"
    (Sql_names.member_for ~taken:[ "ts" ] "timestamp" = "timestamp*")

let () = print_string ("test_sql: " ^ string_of_int !passed ^ " passed\n")
