(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* §8's constraints that need the whole schema. Positions come from the
   decoder, since [Schema] data has none. *)

let ( let* ) = Result.bind

(* Where an arrow's name and endpoints were written. [dom_at] is [None] inside a
   [(type …)] body, where the domain is the enclosing type. *)
type arrow_at = {
  name_at : Errors.pos;
  cod_at : Errors.pos;
  dom_at : Errors.pos option;
}

(* §8.3: an arrow's endpoint types must be declared. *)
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

(* §8.3: arrow names are unique per owner, keyed (dom, name) (§7). *)
let check_arrows_fresh (arrows : (Schema.arrow * arrow_at) list) :
    (unit, Errors.t) result =
  let seen = Hashtbl.create 16 in
  let rec go = function
    | [] -> Ok ()
    | ((a : Schema.arrow), at) :: rest ->
        let key = (a.Schema.dom, a.Schema.name) in
        if Hashtbl.mem seen key then
          Errors.err ~pos:at.name_at
            ("arrow `" ^ a.Schema.name ^ "` is already declared on `"
           ^ a.Schema.dom
           ^ "` — §8.3 gives each type's arrow names one namespace of their own"
            )
        else begin
          Hashtbl.add seen key ();
          go rest
        end
  in
  go arrows

(* The type a checked chain lands in. *)
let path_cod (s : Schema.t) env (p : Value.path) : (string, Errors.t) result =
  match Schema.check_path s env p with
  | Error _ as e -> e
  | Ok arrows -> (
      match List.rev arrows with
      | last :: _ -> Ok last.Schema.cod
      | [] -> (
          match List.assoc_opt p.Value.root env with
          | Some ty -> Ok ty
          | None -> Ok ""))

(* A law's chains, resolved with the subject bound to itself ([(case, case)]).
   Two compared chains must land in one type (see [Grammar.check_is]). *)
let rec check_body (s : Schema.t) ~roster ~binders env (g : Guard.t) :
    (unit, Errors.t) result =
  match g with
  | Guard.And gs | Guard.Or gs -> check_body_each s ~roster ~binders env gs
  | Guard.Not g -> check_body s ~roster ~binders env g
  | Guard.Some_ (x, ty, g) ->
      check_body s ~roster ~binders:(x :: binders) ((x, ty) :: env) g
  | Guard.Defined p -> Result.map (fun _ -> ()) (path_cod s env p)
  (* §10.2's literal rule. Without a roster (the schema does not know who
     exists, §8.2), only enumerated codomains are decided outright. *)
  | Guard.Is (p, Guard.Lit v) -> (
      let* lcod = path_cod s env p in
      match Grammar.lit_fault s ~roster ~binders lcod v with
      | None -> Ok ()
      | Some msg -> Errors.err msg)
  | Guard.Is (p, Guard.Chain q) ->
      let* lcod = path_cod s env p in
      let* rcod = path_cod s env q in
      if String.equal lcod rcod then Ok ()
      else
        Errors.err
          ("a law compares a chain landing in `" ^ lcod
         ^ "` with one landing in `" ^ rcod
         ^ "` — comparing two chains needs a single target type")

and check_body_each s ~roster ~binders env = function
  | [] -> Ok ()
  | g :: rest ->
      let* () = check_body s ~roster ~binders env g in
      check_body_each s ~roster ~binders env rest

(* [check_equation] runs at schema decode with no roster;
   [check_equations_in] runs again once the instance is known. *)
let check_body_of (s : Schema.t) ~roster (eq : Schema.equation) :
    (unit, Errors.t) result =
  match Guard.free_roots eq.Schema.body with
  | [ root ] when Schema.type_of s root <> None ->
      check_body s ~roster ~binders:[] [ (root, root) ] eq.Schema.body
  | _ -> Ok ()

(* Laws (§8.6) rechecked once the instance (§9.1) is known. Equations have no
   position, so the error names the law. *)
let check_equations_in (s : Schema.t) (roster : (string * string) list) :
    (unit, Errors.t) result =
  let rec go = function
    | [] -> Ok ()
    | (eq : Schema.equation) :: rest ->
        let* () =
          Result.map_error
            (fun (e : Errors.t) ->
              { e with Errors.msg = "law `" ^ eq.Schema.name ^ "` — " ^ e.msg })
            (check_body_of s ~roster:(Some roster) eq)
        in
        go rest
  in
  go s.Schema.equations

let check_equation (s : Schema.t) ((eq, pos) : Schema.equation * Errors.pos) :
    (unit, Errors.t) result =
  match Guard.free_roots eq.Schema.body with
  | [] ->
      Errors.err ~pos
        ("law `" ^ eq.Schema.name
       ^ "` has no subject — every chain in it is bound by a `some`, so there \
          is no type for the law to range over")
  | r1 :: r2 :: _ ->
      Errors.err ~pos
        ("law `" ^ eq.Schema.name ^ "` ranges over two types, `" ^ r1
       ^ "` and `" ^ r2
       ^ "` — §8.6 gives a law one subject; bind the others with `some`")
  | [ root ] ->
      if Schema.type_of s root = None then
        Errors.err ~pos
          ("law `" ^ eq.Schema.name ^ "` ranges over `" ^ root
         ^ "`, which is not a declared type")
      else
        Result.map_error
          (fun (e : Errors.t) -> { e with Errors.pos = Some pos })
          (check_body s ~roster:None ~binders:[]
             [ (root, root) ]
             eq.Schema.body)
