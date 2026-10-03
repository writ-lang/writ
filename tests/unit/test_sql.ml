(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* `writ sql` unit tests. The round trip compares schemas read back through the
   front end, not text, since the export normalises spellings. The rest pins
   what DDL says that writ declines. *)

open Writ_data
open Writ_syntax
open Writ_sql

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

let import ?(name = "t") ?(with_data = false) (sql : string) :
    string * Sql_ast.db =
  let db = Sql_parse.parse ~with_data sql in
  let text, _ = Emit_writ.file ~name ~source:"t.sql" db in
  (text, db)

(* The schema as a comparable value. *)
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
  (* so a NOT NULL scalar column costs the state product nothing *)
  check "opaque domain has one member"
    (match ty "numeric-10-2" with
    | Some { flavor = Schema.Enumerated [ _ ]; _ } -> true
    | _ -> false);
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
  (* a single-row CHECK becomes a law *)
  check "CHECK -> equation"
    (List.exists
       (fun (e : Schema.equation) -> e.name = "shipped-needs-stamp")
       s.equations)

(* --- what SQL says and writ declines -------------------------------------- *)

let declined_for ~(sub : string) (sql : string) =
  let _, db = import sql in
  List.exists (fun (d : Sql_ast.decline) -> contains ~sub d.why) db.declines

let () =
  (* UNIQUE is unsayable: a writ law ranges over one entity, so "two distinct
     rows agree" has no spelling. *)
  check "UNIQUE column constraint is declined"
    (declined_for ~sub:"UNIQUE"
       "CREATE TABLE t (id text PRIMARY KEY, a text UNIQUE);");
  check "UNIQUE table constraint is declined"
    (declined_for ~sub:"UNIQUE"
       "CREATE TABLE t (id text PRIMARY KEY, a text, UNIQUE (a));");
  check "CREATE UNIQUE INDEX is declined"
    (declined_for ~sub:"UNIQUE" "CREATE UNIQUE INDEX i ON t (a);");
  (* no numbers, so no arithmetic; a column against a constant crosses as
     regions (below) *)
  check "an arithmetic CHECK is declined"
    (declined_for ~sub:"expressible fragment"
       "CREATE TABLE t (id text PRIMARY KEY, n int, m int, CHECK (n + m > 0));");
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
  (* not stdlib's `span`, which would lose the column names *)
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
  (* the dollar-quoted body holds three semicolons *)
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

(* Mutability is the column fact SQL cannot state; only the pragma carries
   it. *)
let () =
  let writ =
    "(form (text A) (arrow A (to text)))\n\
     (form (ref A T) (arrow A (to T)))\n\
     (schema m\n\
    \  (type text (txt))\n\
    \  (type a (text label))\n\
    \  (type b (ref link a) (arrow note (to text) fixed)))\n\
     (instance seed m)\n\
     (use m) (initial seed)\n"
  in
  let m1 = model_of_string "pragma" writ in
  let ddl, _ = Emit_ddl.ddl m1.Model.schema in
  check "a mutable foreign key exports a pragma"
    (contains ~sub:"-- writ: mutable" ddl);
  check "a fixed non-reference column exports a pragma"
    (contains ~sub:"-- writ: fixed" ddl);
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

(* Provenance (docs/bridges.md §5): an imported law carries its CHECK's
   line. *)
let () =
  let text, _ =
    import
      "CREATE TABLE orders (\n\
      \  id uuid PRIMARY KEY,\n\
      \  status text NOT NULL CHECK (status IN ('open','shipped')),\n\
      \  shipped_at timestamptz,\n\
      \  CONSTRAINT shipped_needs_stamp CHECK (status <> 'shipped' OR \
       shipped_at IS NOT NULL)\n\
       );"
  in
  check "origin: a law carries the line of its CHECK"
    (contains ~sub:"; writ:origin t.sql:5\n  (equation shipped-needs-stamp" text);
  let m = model_of_string "origin" text in
  ignore m;
  (* Read back through the loader, the pragma becomes the law's origin. *)
  let resolve : Loader.resolve = fun _ -> Ok text in
  match Loader.read_model resolve "orders.writ" with
  | Ok m ->
      check "origin: the loader attaches it to the equation"
        (List.exists
           (fun (e : Schema.equation) ->
             e.name = "shipped-needs-stamp" && e.origin = Some "t.sql:5")
           m.Model.schema.Schema.equations)
  | Error e -> check ("origin: read back: " ^ Errors.to_string e) false

(* --- regions: a column compared against constants --------------------------- *)

let () =
  let text, db =
    import ~with_data:true
      "CREATE TABLE orders (\n\
      \  id uuid PRIMARY KEY,\n\
      \  qty int NOT NULL CHECK (qty >= 1),\n\
      \  CONSTRAINT small_order CHECK (qty < 500),\n\
      \  CONSTRAINT bulk_needs_review CHECK (qty < 100 OR qty = 100)\n\
       );\n\
       INSERT INTO orders (id, qty) VALUES ('o1', 42);"
  in
  let m = model_of_string "regions" text in
  let s = m.Model.schema in
  check "regions: the column becomes an enumerated domain of its pieces"
    (match
       List.find_opt
         (fun (t : Schema.ty) -> t.name = "orders-qty-range")
         s.types
     with
    | Some
        {
          flavor =
            Schema.Enumerated
              [
                "below-1";
                "exactly-1";
                "between-1-and-100";
                "exactly-100";
                "between-100-and-500";
                "exactly-500";
                "above-500";
              ];
          _;
        } ->
        true
    | _ -> false);
  check "regions: every CHECK survives as a law"
    (List.for_all
       (fun n ->
         List.exists (fun (e : Schema.equation) -> e.name = n) s.equations)
       [ "small-order"; "bulk-needs-review" ]);
  check "regions: nothing was declined" (db.declines = []);
  check "regions: a seed row's number lands in its piece"
    (contains ~sub:"(qty between-1-and-100)" text);
  (* an integral column has no piece strictly between adjacent integers *)
  let text, _ =
    import
      "CREATE TABLE t (id uuid PRIMARY KEY, n int CHECK (n > 4 AND n < 5));"
  in
  check "regions: no empty piece between adjacent integers"
    (contains ~sub:"(type t-n-range (below-4 exactly-4 exactly-5 above-5))" text);
  check "regions: two columns compared is still declined"
    (declined_for ~sub:"expressible fragment"
       "CREATE TABLE t (id uuid PRIMARY KEY, a int, b int, CHECK (a < b));");
  check "regions: a constant against a text column is declined"
    (declined_for ~sub:"not numeric"
       "CREATE TABLE t (id uuid PRIMARY KEY, a text, CHECK (a < 5));")

let () = print_string ("test_sql: " ^ string_of_int !passed ^ " passed\n")
