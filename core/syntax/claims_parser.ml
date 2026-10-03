(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* [.claims] datums -> [Claims.t]. Query guards are path-checked here; property
   formulas only for shape, since one naming something absent is n/a
   (kernel §8). *)

let ( let* ) = Result.bind

let rec map_r f = function
  | [] -> Ok []
  | x :: xs ->
      let* y = f x in
      let* ys = map_r f xs in
      Ok (y :: ys)

(* The modality words, as data so [Writ_lsp] can share the list. The fairness
   clause of [inevitable] is parsed separately. *)
let modalities =
  [
    ("never", Claims.Never);
    ("possible", Claims.Possible);
    ("live", Claims.Live);
    ("inevitable", Claims.Inevitable []);
  ]

let modality_of w = List.assoc_opt w modalities

(* [inevitable]'s optional [(fair MOVE…)]: named moves, since fairness is about
   which transitions the scheduler picks. *)
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

(* A property's optional [(show QUERY…)] (§16.1). Positions are kept so an
   undeclared name can be blamed once the whole file is read. *)
let show_of (d : Reader.t) : ((string * Errors.pos) list, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom ("show", sp) :: names, _) ->
      if names = [] then
        Errors.err ~pos:sp "(show …) needs at least one query name"
      else
        map_r
          (function
            | Reader.Atom (q, p) -> Ok (q, p)
            | d -> Reader.err_at d "(show …) names queries")
          names
  | _ -> Reader.err_at d "expected (show QUERY…) after the modality"

let binder_of (d : Reader.t) : (string * string, Errors.t) result =
  match d with
  | Reader.List ([ Reader.Atom (x, _); Reader.Atom (ty, _) ], _) -> Ok (x, ty)
  | _ -> Reader.err_at d "expected a binder shaped (VAR TYPE)"

let decode_property (d : Reader.t) :
    (Claims.property * (string * Errors.pos) list, Errors.t) result =
  match d with
  | Reader.List
      ( Reader.Atom ("property", _)
        :: Reader.Atom (name, _)
        :: Reader.Atom (text, _)
        :: formula :: tail,
        _ )
    when List.length tail <= 1 -> (
      match formula with
      | Reader.List (Reader.Atom (m, mp) :: f :: rest, _)
        when List.length rest <= 1 -> (
          match modality_of m with
          | None -> Errors.err ~pos:mp ("unknown modality `" ^ m ^ "`")
          | Some modality ->
              (* Only [inevitable] takes a fairness clause. *)
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
              (* Shape only; resolution is the checker's (kernel §8). *)
              let* g = Grammar.guard f in
              let* shows =
                match tail with [] -> Ok [] | s :: _ -> show_of s
              in
              Ok
                ( {
                    Claims.name;
                    text;
                    modality;
                    formula = g;
                    show = List.map fst shows;
                  },
                  shows ))
      | _ -> Reader.err_at formula "a property needs (MODALITY FORMULA)")
  | _ ->
      Reader.err_at d
        "malformed property: (property NAME \"text\" (MODALITY FORMULA) [(show \
         QUERY…)])"

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

(* [inst] is used only for the shadowing check. *)
let parse (schema : Schema.t) (inst : Instance.t) (datums : Reader.t list) :
    (Claims.t, Errors.t) result =
  (* No shadowing (§7): binders here are checked against the built model's
     names (§16.1, §16.2). *)
  let* () = Names.check_binders (Names.taken_in schema inst) datums in
  let rec go props queries accepts shows = function
    | [] ->
        (* Checked last, so a query may follow the property that shows it. *)
        let declared = List.map (fun (q : Claims.query) -> q.name) queries in
        let* () =
          match
            List.find_opt (fun (q, _) -> not (List.mem q declared)) shows
          with
          | Some (q, pos) ->
              Errors.err ~pos ("(show " ^ q ^ ") names no query in this file")
          | None -> Ok ()
        in
        Ok
          {
            Claims.props = List.rev props;
            queries = List.rev queries;
            accepts = List.rev accepts;
          }
    | d :: rest -> (
        match d with
        | Reader.List (Reader.Atom ("property", _) :: _, _) ->
            let* p, s = decode_property d in
            go (p :: props) queries accepts (s @ shows) rest
        | Reader.List (Reader.Atom ("query", _) :: _, _) ->
            let* q = decode_query schema d in
            go props (q :: queries) accepts shows rest
        | Reader.List (Reader.Atom ("accept", _) :: _, _) ->
            let* a = decode_accepts d in
            go props queries (List.rev_append a accepts) shows rest
        | Reader.List (Reader.Atom ("schema", _) :: _, _)
        | Reader.List (Reader.Atom ("instance", _) :: _, _) ->
            (* declarations a loaded library brought in — not questions *)
            go props queries accepts shows rest
        | other -> Reader.err_at other "unknown claims declaration")
  in
  go [] [] [] [] datums
