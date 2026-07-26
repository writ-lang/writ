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

(* Where an arrow named its endpoint types, so §8.3's "the `to` TYPE must be a
   *named*, declared type" can be blamed at the atom that got it wrong. The
   arrow itself carries no position — [Schema.arrow] is data, not syntax — so
   the positions travel beside it as far as [check_arrow], exactly as
   [decode_equation] already does for a path. [dom_at] is [None] when the arrow
   sits inside a [(type …)] body, because then its domain is the enclosing type
   and cannot fail to be declared. *)
type arrow_at = { cod_at : Errors.pos; dom_at : Errors.pos option }

(* [(arrow NAME (to COD) FLAGS…)] — dom is the enclosing type by default, or an
   [(of TYPE)] clause when the arrow is declared at schema top level. *)
let decode_arrow ~(dom : string) (d : Reader.t) :
    (Schema.arrow * arrow_at, Errors.t) result =
  match d with
  | Reader.List
      (Reader.Atom ("arrow", _) :: Reader.Atom (name, np) :: clauses, _) -> (
      let dom = ref dom and cod = ref None in
      let cod_at = ref None and dom_at = ref None in
      let fixed = ref false and vacatable = ref false in
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
        | Reader.Atom ("fixed", _) ->
            fixed := true;
            Ok ()
        | Reader.Atom ("vacatable", _) ->
            vacatable := true;
            Ok ()
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
              { cod_at; dom_at = !dom_at } )
      | _ -> Errors.err ~pos:np ("arrow `" ^ name ^ "` has no (to …) codomain"))
  | _ -> Reader.err_at d "expected an (arrow …) declaration"

(* [(type N (v…))] enumerated, or [(type N BODY…)] open with [(arrow …)] bodies.
   Returns the type and its nested arrows for the schema's flat arrow list. *)
let decode_type (d : Reader.t) :
    (Schema.ty * (Schema.arrow * arrow_at) list, Errors.t) result =
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
                  | Reader.Atom (s, _) -> Ok s
                  | Reader.List (_, p) ->
                      Errors.err ~pos:p "an enumerated value must be an atom")
                vals
            in
            Ok ({ Schema.name; flavor = Enumerated vs; arrows = [] }, [])
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

(* §8.3: "The `to` TYPE must be a *named*, declared type" — and the same for an
   explicit [(of TYPE)] domain. Checked here rather than in [decode_arrow]
   because a type may be declared after the arrow that points at it, so the
   schema has to be whole first.

   Without this the name simply never resolves, and the model fails much later
   with an unpositioned complaint about a *cell* — "mutable cell box.f for p is
   not vacatable and has no value" — which blames the instance for a fault in
   the schema and never mentions the type that does not exist. Wrong stage,
   wrong file when a library is involved, and no line:col at all, which §13
   requires of every error. *)
let check_arrow (s : Schema.t) ((a, at) : Schema.arrow * arrow_at) :
    (unit, Errors.t) result =
  let declared t = Schema.type_of s t <> None in
  let blame pos role t =
    Errors.err ~pos
      ("arrow `" ^ a.Schema.name ^ "` names an undeclared type `" ^ t
     ^ "` as its " ^ role)
  in
  let* () =
    if declared a.Schema.cod then Ok ()
    else blame at.cod_at "codomain" a.Schema.cod
  in
  match at.dom_at with
  | Some p when not (declared a.Schema.dom) -> blame p "domain" a.Schema.dom
  | _ -> Ok ()

let check_equation (s : Schema.t) ((eq, pos) : Schema.equation * Errors.pos) :
    (unit, Errors.t) result =
  let side (p : Value.path) =
    match Schema.check_path s [ (p.Value.root, p.Value.root) ] p with
    | Ok _ -> Ok ()
    | Error e -> Error { e with Errors.pos = Some pos }
  in
  let* () = side eq.Schema.lhs in
  side eq.Schema.rhs

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
            let* () = iter_r (check_arrow schema) (List.rev arrows) in
            let* () = iter_r (check_equation schema) (List.rev eqs) in
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
