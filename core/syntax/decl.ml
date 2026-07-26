open Pol_data

(* Schema and instance decoding, split out of parser.ml so each file stays under
   the 300-line cap (design fold F8). Syntax layer: uses core + Grammar, never
   the engine. Every path is type-checked through [Schema.check_path] (fold F3),
   with the offending datum's [line:col] re-attached on failure. *)

let ( let* ) = Result.bind

let rec map_r f = function
  | [] -> Ok []
  | x :: xs ->
      let* y = f x in
      let* ys = map_r f xs in
      Ok (y :: ys)

let rec iter_r f = function
  | [] -> Ok ()
  | x :: xs ->
      let* () = f x in
      iter_r f xs

(* [(arrow NAME (to COD) FLAGS…)] — dom is the enclosing type by default, or an
   [(of TYPE)] clause when the arrow is declared at schema top level. The
   positions the §8.3 checks need travel beside the arrow as a
   [Decl_checks.arrow_at], exactly as [decode_equation] already does for a
   path. *)
let decode_arrow ~(dom : string) (d : Reader.t) :
    (Schema.arrow * Decl_checks.arrow_at, Errors.t) result =
  match d with
  | Reader.List
      (Reader.Atom ("arrow", _) :: Reader.Atom (name, np) :: clauses, _) -> (
      let dom = ref dom and cod = ref None in
      let cod_at = ref None and dom_at = ref None in
      let fixed = ref false and vacatable = ref false in
      (* §8.3: "FLAG is `fixed` or `vacatable`, each at most once." A repeat is
         not harmless idempotence — a flag written twice is an author who thinks
         they wrote two different things, and the second is the one we can point
         at. *)
      let once flag seen p =
        if !seen then
          Errors.err ~pos:p
            ("arrow `" ^ name ^ "` repeats the flag `" ^ flag
           ^ "` — §8.3 allows each flag at most once")
        else begin
          seen := true;
          Ok ()
        end
      in
      let scan c =
        match c with
        | Reader.List ([ Reader.Atom ("to", _); Reader.Atom (cd, cp) ], _) ->
            cod := Some cd;
            cod_at := Some cp;
            Ok ()
        | Reader.List (Reader.Atom ("to", tp) :: _, _) ->
            Errors.err ~pos:tp
              "an arrow codomain must be a named type, not an inline set"
        | Reader.List ([ Reader.Atom ("of", _); Reader.Atom (dm, dp) ], _) ->
            dom := dm;
            dom_at := Some dp;
            Ok ()
        | Reader.Atom ("fixed", p) -> once "fixed" fixed p
        | Reader.Atom ("vacatable", p) -> once "vacatable" vacatable p
        | other -> Reader.err_at other "unknown arrow clause"
      in
      let* () = iter_r scan clauses in
      match (!cod, !cod_at) with
      | Some cod, Some cod_at ->
          Ok
            ( {
                Schema.name;
                dom = !dom;
                cod;
                fixed = !fixed;
                vacatable = !vacatable;
              },
              { Decl_checks.name_at = np; cod_at; dom_at = !dom_at } )
      | _ -> Errors.err ~pos:np ("arrow `" ^ name ^ "` has no (to …) codomain"))
  | _ -> Reader.err_at d "expected an (arrow …) declaration"

(* [(type N (v…))] enumerated, or [(type N BODY…)] open with [(arrow …)] bodies.
   Returns the type and its nested arrows for the schema's flat arrow list. *)
let decode_type (d : Reader.t) :
    (Schema.ty * (Schema.arrow * Decl_checks.arrow_at) list, Errors.t) result =
  let is_arrow = function
    | Reader.List (Reader.Atom ("arrow", _) :: _, _) -> true
    | _ -> false
  in
  match d with
  | Reader.List (Reader.Atom ("type", _) :: Reader.Atom (name, _) :: clauses, _)
    -> (
      if List.exists is_arrow clauses then
        let* ars = map_r (decode_arrow ~dom:name) clauses in
        Ok ({ Schema.name; flavor = Open; arrows = List.map fst ars }, ars)
      else
        match clauses with
        | [] -> Ok ({ Schema.name; flavor = Open; arrows = [] }, [])
        | [ Reader.List (vals, _) ] ->
            let* vs =
              map_r
                (function
                  | Reader.Atom (s, p) -> Ok (s, p)
                  | Reader.List (_, p) ->
                      Errors.err ~pos:p "an enumerated value must be an atom")
                vals
            in
            (* §8.2: "VALUEs distinct." A repeated value costs the type nothing
               visible — the second is simply never reachable, since every
               lookup and every domain enumeration stops at the first — so the
               author's `(a a)` reads as a two-value type and behaves as a
               one-value type, silently. *)
            let rec distinct seen = function
              | [] -> Ok ()
              | (v, p) :: rest ->
                  if List.mem v seen then
                    Errors.err ~pos:p
                      ("`" ^ v ^ "` is already a value of type `" ^ name
                     ^ "` — §8.2 requires the values of a type to be distinct")
                  else distinct (v :: seen) rest
            in
            let* () = distinct [] vs in
            Ok
              ( {
                  Schema.name;
                  flavor = Enumerated (List.map fst vs);
                  arrows = [];
                },
                [] )
        | other :: _ -> Reader.err_at other "malformed type body")
  | _ -> Reader.err_at d "expected a (type …) declaration"

(* [(equation NAME (= P1 P2))]. Paths are type-checked after the schema is fully
   built (both sides share their root type as the common dom). *)
let decode_equation (d : Reader.t) :
    (Schema.equation * Errors.pos, Errors.t) result =
  match d with
  | Reader.List
      ( [
          Reader.Atom ("equation", _);
          Reader.Atom (name, _);
          Reader.List ([ Reader.Atom ("=", _); p1; p2 ], _);
        ],
        p ) ->
      let* lhs = Grammar.path p1 in
      let* rhs = Grammar.path p2 in
      Ok ({ Schema.name; lhs; rhs }, p)
  | _ ->
      Reader.err_at d "malformed equation: expected (equation NAME (= P1 P2))"

let decode_schema (d : Reader.t) : (Schema.t, Errors.t) result =
  match d with
  | Reader.List
      (Reader.Atom ("schema", _) :: Reader.Atom (name, _) :: clauses, _) ->
      let rec go types arrows eqs = function
        | [] ->
            let schema =
              {
                Schema.name;
                types = List.rev types;
                arrows = List.rev_map fst arrows;
                equations = List.rev_map fst eqs;
              }
            in
            let arrows = List.rev arrows in
            let* () = Decl_checks.check_arrows_fresh arrows in
            let* () = iter_r (Decl_checks.check_arrow schema) arrows in
            let* () =
              iter_r (Decl_checks.check_equation schema) (List.rev eqs)
            in
            Ok schema
        | c :: rest -> (
            match c with
            | Reader.List (Reader.Atom ("type", _) :: _, _) ->
                let* ty, ars = decode_type c in
                go (ty :: types) (List.rev_append ars arrows) eqs rest
            | Reader.List (Reader.Atom ("arrow", _) :: _, _) ->
                let* a, at = decode_arrow ~dom:"" c in
                if a.Schema.dom = "" then
                  Reader.err_at c "a top-level arrow needs an (of TYPE) domain"
                else go types ((a, at) :: arrows) eqs rest
            | Reader.List (Reader.Atom ("equation", _) :: _, _) ->
                let* eq = decode_equation c in
                go types arrows (eq :: eqs) rest
            | _ -> Reader.err_at c "unknown schema clause")
      in
      go [] [] [] clauses
  | _ -> Reader.err_at d "expected a (schema …) declaration"

(* [(instance N (of SCHEMA) (TYPE e…)… (ARROW (E V)…)…)]. The schema tells a
   roster clause (head is a type) from a valuation clause (head is an arrow). *)
let decode_instance (schemas : Schema.t list) (d : Reader.t) :
    (Instance.t, Errors.t) result =
  match d with
  | Reader.List
      (Reader.Atom ("instance", _) :: Reader.Atom (name, np) :: clauses, _) ->
      let sname =
        List.find_map
          (function
            | Reader.List ([ Reader.Atom ("of", _); Reader.Atom (sn, _) ], _) ->
                Some sn
            | _ -> None)
          clauses
      in
      let* sname =
        match sname with
        | Some sn -> Ok sn
        | None -> Errors.err ~pos:np "an instance needs an (of SCHEMA)"
      in
      let* schema =
        match List.find_opt (fun s -> s.Schema.name = sname) schemas with
        | Some s -> Ok s
        | None ->
            Errors.err ~pos:np
              ("instance refers to unknown schema `" ^ sname ^ "`")
      in
      let cell_of (arrow : string) (pair : Reader.t) =
        match pair with
        | Reader.List ([ Reader.Atom (e, _); Reader.Atom ("vacant", _) ], _) ->
            Ok ({ Instance.arrow; src = e }, Value.Vacant)
        | Reader.List ([ Reader.Atom (e, _); Reader.Atom (v, _) ], _) ->
            Ok ({ Instance.arrow; src = e }, Value.Filled v)
        | _ -> Reader.err_at pair "expected a valuation (E V)"
      in
      let rec go rosters valu = function
        | [] ->
            Ok
              {
                Instance.name;
                schema = sname;
                rosters = List.rev rosters;
                valuation = List.rev valu;
              }
        | c :: rest -> (
            match c with
            | Reader.List ([ Reader.Atom ("of", _); Reader.Atom (_, _) ], _) ->
                go rosters valu rest
            | Reader.List (Reader.Atom (h, hp) :: tl, _) -> (
                match Schema.type_of schema h with
                | Some _ ->
                    let* entities =
                      map_r
                        (function
                          | Reader.Atom (e, _) -> Ok e
                          | Reader.List (_, p) ->
                              Errors.err ~pos:p
                                "a roster entity must be an atom")
                        tl
                    in
                    go ({ Instance.ty = h; entities } :: rosters) valu rest
                | None ->
                    if
                      List.exists
                        (fun (a : Schema.arrow) -> a.Schema.name = h)
                        schema.Schema.arrows
                    then
                      let* pairs = map_r (cell_of h) tl in
                      go rosters (List.rev_append pairs valu) rest
                    else
                      Errors.err ~pos:hp
                        ("unknown instance clause `" ^ h
                       ^ "`: not a type or arrow of the schema"))
            | _ -> Reader.err_at c "malformed instance clause")
      in
      go [] [] clauses
  | _ -> Reader.err_at d "expected an (instance …) declaration"
