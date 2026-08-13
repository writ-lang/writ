(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Pol_data

(* [.claims] datums -> [Claims.t] (core). [(property NAME "text" (MODALITY
   FORMULA))] with MODALITY ∈ never/possible/live; [(query NAME (where (x
   TYPE)…) GUARD)]; [(accept TRANSITION EQUATION…)]. Guards are decoded through
   [Grammar.guard].

   Path type-checking differs by kind. A QUERY guard is checked at parse time
   (fold F3): a mistyped binding is a genuine author error. A PROPERTY FORMULA is
   deliberately NOT path-checked here (kernel §8): a formula naming a type/arrow/
   value the schema lacks is *n/a*, not an author error — only its SHAPE is
   decoded, and resolution is deferred to [Checker.check], which returns
   [Not_applicable]. Renamed from [claims] (fold F2) so it does not collide with
   core's [claims.ml] under [include_subdirs unqualified]. *)

let ( let* ) = Result.bind

let rec map_r f = function
  | [] -> Ok []
  | x :: xs ->
      let* y = f x in
      let* ys = map_r f xs in
      Ok (y :: ys)

(* The modality words, as data rather than as a match, because a second copy of
   this list exists for the editor and drifted the first time a word was added
   to one of them. [Pol_lsp] reads it from here, so there is one list. An
   [Inevitable] here carries no fairness clause: the clause is parsed after the
   word is recognised, below. *)
let modalities =
  [
    ("never", Claims.Never);
    ("possible", Claims.Possible);
    ("live", Claims.Live);
    ("inevitable", Claims.Inevitable []);
  ]

let modality_of w = List.assoc_opt w modalities

(* The optional trailing clause of an [inevitable]: the moves the question
   assumes are not starved. Named moves, never a guard — a fairness assumption
   is about the scheduler, and the scheduler picks transitions. *)
let fair_of (d : Reader.t) : (string list, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom ("fair", fp) :: moves, _) ->
      if moves = [] then
        Errors.err ~pos:fp "(fair …) needs at least one move to assume fair"
      else
        map_r
          (function
            | Reader.Atom (m, _) -> Ok m
            | d -> Reader.err_at d "a fairness assumption names a move")
          moves
  | _ -> Reader.err_at d "expected (fair MOVE…) after an inevitable formula"

let binder_of (d : Reader.t) : (string * string, Errors.t) result =
  match d with
  | Reader.List ([ Reader.Atom (x, _); Reader.Atom (ty, _) ], _) -> Ok (x, ty)
  | _ -> Reader.err_at d "expected a binder shaped (VAR TYPE)"

let decode_property (d : Reader.t) : (Claims.property, Errors.t) result =
  match d with
  | Reader.List
      ( [
          Reader.Atom ("property", _);
          Reader.Atom (name, _);
          Reader.Atom (text, _);
          formula;
        ],
        _ ) -> (
      match formula with
      | Reader.List (Reader.Atom (m, mp) :: f :: rest, _)
        when List.length rest <= 1 -> (
          match modality_of m with
          | None -> Errors.err ~pos:mp ("unknown modality `" ^ m ^ "`")
          | Some modality ->
              (* Only [inevitable] takes a fairness clause: the other three are
                 about which situations exist, and no assumption about the
                 scheduler changes that. *)
              let* modality =
                match (modality, rest) with
                | _, [] -> Ok modality
                | Claims.Inevitable _, [ d ] ->
                    let* ms = fair_of d in
                    Ok (Claims.Inevitable ms)
                | _, d :: _ ->
                    Reader.err_at d
                      ("`" ^ m ^ "` takes a formula and nothing else")
              in
              (* Shape only — path/arrow/value resolution is the checker's, so an
                 unknown one surfaces as n/a, not a parse error (kernel §8). *)
              let* g = Grammar.guard f in
              Ok { Claims.name; text; modality; formula = g })
      | _ -> Reader.err_at formula "a property needs (MODALITY FORMULA)")
  | _ ->
      Reader.err_at d
        "malformed property: (property NAME \"text\" (MODALITY FORMULA))"

let decode_query (schema : Schema.t) (d : Reader.t) :
    (Claims.query, Errors.t) result =
  match d with
  | Reader.List
      ([ Reader.Atom ("query", _); Reader.Atom (name, _); where; g ], _) -> (
      match where with
      | Reader.List (Reader.Atom ("where", _) :: binders, _) ->
          let* binders = map_r binder_of binders in
          let* guard = Grammar.guard g in
          let* () = Grammar.check_query_guard schema binders g in
          Ok { Claims.name; binders; guard }
      | _ -> Reader.err_at where "a query needs a (where (VAR TYPE)…)")
  | _ -> Reader.err_at d "malformed query"

let decode_accepts (d : Reader.t) : (Claims.accept list, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom ("accept", _) :: Reader.Atom (tr, _) :: eqs, _)
    when eqs <> [] ->
      map_r
        (function
          | Reader.Atom (eq, _) -> Ok { Claims.tr; eq }
          | d ->
              Reader.err_at d "accept expects a transition then equation names")
        eqs
  | _ -> Reader.err_at d "malformed accept: (accept TRANSITION EQUATION…)"

(* [inst] is unused: property formulas are no longer path-checked here (their
   entity env belonged to that check), and query guards carry their own binder
   env. The parameter stays for the loader's fixed call shape. *)
let parse (schema : Schema.t) (inst : Instance.t) (datums : Reader.t list) :
    (Claims.t, Errors.t) result =
  (* §7 has no shadowing, and a [where] or [some] binder here can shadow a name
     from the model just as one in a transition can — the guards are the same
     guards (§16.1, §16.2). The model is already built by the time a .claims
     file is parsed, so the names come off it rather than from a second scan;
     [Names] states the rule for both. *)
  let* () = Names.check_binders (Names.taken_in schema inst) datums in
  let rec go props queries accepts = function
    | [] ->
        Ok
          {
            Claims.props = List.rev props;
            queries = List.rev queries;
            accepts = List.rev accepts;
          }
    | d :: rest -> (
        match d with
        | Reader.List (Reader.Atom ("property", _) :: _, _) ->
            let* p = decode_property d in
            go (p :: props) queries accepts rest
        | Reader.List (Reader.Atom ("query", _) :: _, _) ->
            let* q = decode_query schema d in
            go props (q :: queries) accepts rest
        | Reader.List (Reader.Atom ("accept", _) :: _, _) ->
            let* a = decode_accepts d in
            go props queries (List.rev_append a accepts) rest
        | Reader.List (Reader.Atom ("schema", _) :: _, _)
        | Reader.List (Reader.Atom ("instance", _) :: _, _) ->
            (* declarations a loaded library brought in — not questions *)
            go props queries accepts rest
        | other -> Reader.err_at other "unknown claims declaration")
  in
  go [] [] [] datums
