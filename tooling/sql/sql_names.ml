(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The naming layer — the part of the mapping that must agree with itself in
   both directions, so it lives in one module that both emitters call.

   Three separate namings happen here and they have different obligations:

   - IDENTIFIERS (a table or column name) must round-trip exactly, because a
     name is the only thing carrying a column's identity across. `snake_case`
     becomes `kebab-case` and back, and anything that would not survive the
     trip is refused rather than mangled.

   - DOMAIN TYPES (a column's SQL type) must round-trip exactly, because on the
     way back the arrow's codomain IS the SQL type — that is the whole reason
     the import needs no annotation file. `varchar(255)` becomes `varchar-255`
     because parentheses are reader delimiters and a pol atom may not hold one.

   - MEMBERS (the single element of an opaque domain) need NOT round-trip, and
     saying so is what buys them a short spelling. An opaque domain has exactly
     one member by construction, so nothing about a column's SQL type is
     recovered from it — the codomain already said that. It appears only in an
     instance, where it is written once per row per column, so it is worth a
     mnemonic (`v255`, `ts`, `amt`) rather than a derivation. *)

(* ---- identifiers -------------------------------------------------------- *)

(* A pol atom may hold anything but whitespace, parens, a semicolon and a double
   quote (reader.ml), and `.` besides, which is the path separator. SQL
   identifiers are far
   narrower than that in practice, so the test is on the SQL side: an ordinary
   unquoted identifier is [A-Za-z0-9_$], and those are exactly the ones whose
   translation is reversible. A quoted identifier holding anything else is
   REFUSED, not repaired — a silently renamed column is a column whose export
   no longer matches the database it came from. *)
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

(* SQL -> pol. Lowercased because unquoted SQL identifiers are case-insensitive
   and fold to lower in PostgreSQL, so `Orders` and `orders` are one table and
   must not become two types. *)
let ident_to_pol (s : string) : string = tr '_' '-' (String.lowercase_ascii s)

(* pol -> SQL. The inverse on everything [translatable] admits. *)
let ident_to_sql (s : string) : string = tr '-' '_' s

(* ---- domain types ------------------------------------------------------- *)

(* A column's SQL type, normalised. [Bool] is singled out because it is the one
   scalar whose values are worth naming — two of them — so it crosses with its
   members intact and costs the state space a factor of 2 rather than 1. *)
type domain =
  | Bool
  | Enum of string  (** a named enumerated domain: its members are known *)
  | Opaque of string  (** a domain pol carries but cannot look inside *)

let domain_name = function Bool -> "bool" | Enum n -> n | Opaque n -> n

(* PostgreSQL spells several types more than one way; the alias table folds
   them so that `character varying(255)` and `varchar(255)` become one domain
   rather than two identical ones with different names. The canonical spelling
   is the short one, which is also what [sql_of_domain] emits — so an export is
   normalised DDL, not a reproduction of the input's spelling. That is a real
   difference and the reason round-tripping is defined on the MODEL (via `pol
   compare`) rather than on the text. *)
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
    (* the serial types are int columns with a sequence default; the sequence
       is not a column fact, and pol has no numbers to receive it anyway *)
    ("serial", "int");
    ("bigserial", "bigint");
    ("smallserial", "smallint");
  ]

let canonical (base : string) : string =
  match List.assoc_opt base alias with Some c -> c | None -> base

(* [base] is the type word(s) with any parenthesised arguments already split
   off in [args] — `numeric` and `["10"; "2"]`. The arguments join with `-`
   because they are part of the type's identity (`varchar(255)` and
   `varchar(64)` are different domains and a model that conflated them would
   export the wrong DDL). *)
let domain_of_sql (base : string) (args : string list) : domain =
  let base = canonical (String.lowercase_ascii (String.trim base)) in
  (* `_` becomes `-` here for the same reason it does in an identifier: a
     user-defined type is named by its author, and `order_status` must land on
     the same domain the enum declaration produced. No built-in SQL type holds
     an underscore, so the two spellings cannot be confused. *)
  let norm b = tr '_' '-' (tr ' ' '-' b) in
  match (base, args) with
  | ("bool" | "boolean"), _ -> Bool
  | b, [] -> Opaque (norm b)
  | b, args -> Opaque (String.concat "-" (norm b :: args))

(* The inverse, used by the export. A domain name is `base` or `base-arg-arg`,
   and only the types that TAKE arguments may re-acquire parentheses — without
   that test `timestamptz` would be read as base `timestamptz` with no args
   (correct) but `double-precision` as base `double` with argument `precision`
   (nonsense). So the argument-taking types are named. *)
let parameterised = [ "varchar"; "char"; "numeric"; "bit"; "varbit" ]

(* Canonicalisation leaves exactly one type name holding a space, so the
   general rule can be "a dash was an underscore" — which is what a
   user-defined domain needs — and the exception can be a one-line table
   rather than a guess about which dashes were spaces. *)
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

(* Mnemonics for the domains a real schema is mostly made of. The table is
   short because it only has to cover what people actually declare; anything
   absent falls back to a derivation that cannot collide.

   These are read, not written by a machine downstream, which is the entire
   justification for a lookup table over a rule. *)
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

(* Members share the global name space with types and entities (kernel §7), so
   two domains may not take one mnemonic. [taken] is threaded rather than held
   in a global because the emitters build a whole file at a time and a fresh
   run must give a fresh file: the same input twice must produce the same text,
   or a `pol sql | diff` check would report drift that is not there.

   The fallback appends `*` — legal in an atom, absent from SQL identifiers, so
   it can never collide with a mnemonic OR with a translated name. *)
let member_for ~(taken : string list) (name : string) : string =
  let m = mnemonic name in
  if List.mem m taken then name ^ "*" else m
