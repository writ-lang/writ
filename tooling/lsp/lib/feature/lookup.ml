(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Hover: the name under the cursor → a short description of what it is. One tree
   walk, one rendering. Two vocabularies answer: the closed kernel + interrogator
   words (a static table — they cannot be derived, the parser matches them as
   string literals) and the form heads the buffer's loaded libraries bring in
   (derived, through the injected [resolve], by [Completion.form_heads_of]).

   A word in neither is simply [None] — an unrecognised token has nothing to say.
   NEVER raises. *)

open Pol_syntax

(* Kernel §9 reserved words, each with the shape a reference card would show. *)
let reserved_desc =
  [
    ("use", "(use SCHEMA) — the schema a model runs on");
    ("load", "(load \"FILE\") — include a library's declarations");
    ("schema", "(schema NAME …) — an Olog: types, arrows, equations");
    ("type", "(type NAME …) — an object of the world category");
    ("arrow", "(arrow NAME (to TYPE) [fixed] [vacatable]) — a morphism");
    ("to", "(to TYPE) — an arrow's codomain");
    ("fixed", "fixed — set once by the instance, then immutable (wiring)");
    ("vacatable", "vacatable — a partial arrow; its cell may be vacant");
    ("equation", "(equation NAME (= PATH PATH)) — a law two routes must obey");
    ("=", "(= PATH PATH) — Kleene equality of two paths");
    ("instance", "(instance NAME SCHEMA CLAUSE…) — one clause per entity");
    ("initial", "(initial INSTANCE) — the starting state");
    ("vacant", "vacant — the empty cell of a vacatable arrow");
    ("transition", "(transition [NAME] (when G) (do E…)) — one control edge");
    ("when", "(when GUARD) — a transition's domain of definition");
    ("do", "(do EFFECT…) — the effects a transition applies, in order");
    ("set", "(set PATH VALUE) — write a mutable cell");
    ("vacate", "(vacate PATH) — empty a vacatable cell");
    ("gap", "(gap \"MSG\") — the rules run out; the move has no successor");
    ("form", "(form PATTERN TEMPLATE…) — the one extension mechanism");
    ("&rest", "&rest SLOT — captures the remaining pattern items");
    ("and", "(and G…) — conjunction (vacuously true)");
    ("or", "(or G…) — disjunction (vacuously false)");
    ("not", "(not G) — negation");
    ("is", "(is PATH VALUE) — path is defined and equals VALUE");
    ("defined", "(defined PATH) — every step of the path is defined");
    ("some", "(some (x TYPE) G) — some roster entity satisfies G");
  ]

(* The interrogator's file-format words (kernel §9) — not the language. *)
let interrogator_desc =
  [
    ("property", "(property NAME \"text\" (MODALITY FORMULA)) — a claim");
    ("never", "(never F) — no reachable state satisfies F");
    ("possible", "(possible F) — some reachable state satisfies F");
    ("live", "(live F) — from every reachable state, an F-state stays reachable");
    ( "inevitable",
      "(inevitable F [(fair MOVE…)]) — every run reaches an F-state; stronger \
       than live, which asks only that one stays reachable" );
    ( "fair",
      "(fair MOVE…) — inside an inevitable: assume these moves are not starved \
       for ever" );
    ("query", "(query NAME (where …) GUARD) — reported bindings");
    ("where", "(where (VAR TYPE)…) — a query's binders");
    ("accept", "(accept TRANSITION EQUATION…) — acknowledge known breakage");
    ("check", "(check … via FUNCTOR) — pull a property back along a functor");
    ("via", "via FUNCTOR — the functor a check transports along");
    ("functor", "(functor NAME (from S) (to T) …) — a schema map");
    ("from", "(from SCHEMA) — a functor's source schema");
    ("over", "(over TYPE…) — the objects a functor is defined over");
    ("map", "(map ARROW ARROW) — a functor's action on an arrow");
  ]

let describe_word resolve src w =
  match List.assoc_opt w (reserved_desc @ interrogator_desc) with
  | Some d -> Some d
  | None ->
      if List.mem w (Completion.form_heads_of resolve src) then
        Some ("form " ^ w ^ " — a library form")
      else None

(* The token under the cursor, or [None] on a delimiter, in whitespace, or past
   the end — positions a client legitimately sends and about which there is
   nothing to say. *)
let word (t : Text.t) pos =
  let w, r = Text.word_at t (Text.offset_of_lsp t pos) in
  if w = "" then None else Some (w, r)

let hover (t : Text.t) ~(resolve : Loader.resolve) pos : Json.t option =
  match word t pos with
  | None -> None
  | Some (w, r) -> (
      match describe_word resolve t.Text.src w with
      | None -> None
      | Some value ->
          Some
            (Json.Assoc
               [
                 ( "contents",
                   Json.Assoc
                     [
                       ("kind", Json.String "plaintext");
                       ("value", Json.String value);
                     ] );
                 ("range", Text.json_of_range r);
               ]))
