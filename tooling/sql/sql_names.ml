(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The naming layer, shared by both directions of the mapping.

   - Identifiers round-trip exactly: `snake_case` <-> `kebab-case`; anything
     that would not survive the trip is refused.
   - Domain types round-trip exactly, since on export the arrow's codomain is
     the SQL type: `varchar(255)` <-> `varchar-255`.
   - Members of an opaque domain need not round-trip, so they get short
     mnemonics (`v255`, `ts`, `amt`). *)

(* ---- identifiers -------------------------------------------------------- *)

(* Identifiers of [A-Za-z0-9_] translate reversibly; anything else is refused,
   since a renamed column no longer matches its database. *)
let translatable (s : string) : bool =
  s <> ""
  && String.for_all
       (fun c ->
         (c >= 'a' && c <= 'z')
         || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9')
         || c = '_')
       s

let tr (from_c : char) (to_c : char) (s : string) : string =
  String.map (fun c -> if c = from_c then to_c else c) s

(* SQL -> writ, lowercased as PostgreSQL folds unquoted identifiers. *)
let ident_to_pol (s : string) : string = tr '_' '-' (String.lowercase_ascii s)
let ident_to_sql (s : string) : string = tr '-' '_' s

(* ---- domain types ------------------------------------------------------- *)

(* A column's SQL type, normalised. [Bool] crosses with its two members; other
   scalars are opaque. *)
type domain =
  | Bool
  | Enum of string  (** a named enumerated domain: its members are known *)
  | Opaque of string  (** a domain writ carries but cannot look inside *)

let domain_name = function Bool -> "bool" | Enum n -> n | Opaque n -> n

(* PostgreSQL's alternative type spellings, folded to the short one that
   [sql_of_domain] emits; round trips compare models, not text. *)
let alias : (string * string) list =
  [
    ("character varying", "varchar");
    ("character", "char");
    ("integer", "int");
    ("int4", "int");
    ("int8", "bigint");
    ("int2", "smallint");
    ("decimal", "numeric");
    ("float4", "real");
    ("float8", "double precision");
    ("timestamp with time zone", "timestamptz");
    ("timestamp without time zone", "timestamp");
    ("time with time zone", "timetz");
    ("time without time zone", "time");
    (* serial types are int columns with a sequence default *)
    ("serial", "int");
    ("bigserial", "bigint");
    ("smallserial", "smallint");
  ]

let canonical (base : string) : string =
  match List.assoc_opt base alias with Some c -> c | None -> base

(* [base] and its parenthesised [args], e.g. `numeric` and `["10"; "2"]`. *)
let domain_of_sql (base : string) (args : string list) : domain =
  let base = canonical (String.lowercase_ascii (String.trim base)) in
  (* as for identifiers, so `order_status` matches its enum's domain *)
  let norm b = tr '_' '-' (tr ' ' '-' b) in
  match (base, args) with
  | ("bool" | "boolean"), _ -> Bool
  | b, [] -> Opaque (norm b)
  | b, args -> Opaque (String.concat "-" (norm b :: args))

(* The inverse, for export. Only these types take arguments, so only they
   re-acquire parentheses. *)
let parameterised = [ "varchar"; "char"; "numeric"; "bit"; "varbit" ]

(* The one canonical type name with a space; elsewhere a dash was an
   underscore. *)
let spaced = [ ("double-precision", "double precision") ]

let sql_of_domain (name : string) : string =
  match List.assoc_opt name spaced with
  | Some s -> s
  | None -> (
      match String.split_on_char '-' name with
      | base :: (_ :: _ as args) when List.mem base parameterised ->
          base ^ "(" ^ String.concat "," args ^ ")"
      | _ -> tr '-' '_' name)

(* ---- members ------------------------------------------------------------ *)

(* Readable members for common domains; anything else falls back to a
   spelling that cannot collide. *)
let mnemonic (name : string) : string =
  match String.split_on_char '-' name with
  | [ "text" ] -> "txt"
  | [ "varchar"; n ] -> "v" ^ n
  | [ "char"; n ] -> "c" ^ n
  | [ "int" ] -> "i"
  | [ "bigint" ] -> "i8"
  | [ "smallint" ] -> "i2"
  | "numeric" :: _ -> "num"
  | [ "real" ] | [ "double"; "precision" ] -> "flt"
  | [ "money" ] -> "amt"
  | [ "timestamptz" ] -> "tsz"
  | [ "timestamp" ] -> "ts"
  | [ "date" ] -> "dt"
  | [ "time" ] | [ "timetz" ] -> "tm"
  | [ "interval" ] -> "iv"
  | [ "uuid" ] -> "uid"
  | [ "json" ] | [ "jsonb" ] -> "js"
  | [ "bytea" ] -> "bin"
  | [ "inet" ] | [ "cidr" ] -> "ip"
  | _ -> name ^ "*"

(* Members share the global name space (kernel §7), so two domains may not
   take one mnemonic. The fallback appends `*`, which no SQL identifier holds.
   [taken] is threaded so the same input always gives the same text. *)
let member_for ~(taken : string list) (name : string) : string =
  let m = mnemonic name in
  if List.mem m taken then name ^ "*" else m
