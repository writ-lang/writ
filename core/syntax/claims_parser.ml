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

let modality_of = function
  | "never" -> Some Claims.Never
  | "possible" -> Some Claims.Possible
  | "live" -> Some Claims.Live
  | _ -> None

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
      | Reader.List ([ Reader.Atom (m, mp); f ], _) -> (
          match modality_of m with
          | None -> Errors.err ~pos:mp ("unknown modality `" ^ m ^ "`")
          | Some modality ->
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
          let* () = Grammar.check_guard schema binders g in
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
let parse (schema : Schema.t) (_inst : Instance.t) (datums : Reader.t list) :
    (Claims.t, Errors.t) result =
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
