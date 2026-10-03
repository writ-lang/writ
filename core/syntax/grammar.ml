(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Guard / effect / path decoders and their schema checks (fold F3).

   .afk-flow/check-grammar.py treats every clean lowercase string literal from
   [let rec guard] on as a keyword the editor must highlight, so error
   messages there always contain a space or a capital. *)

let ( let* ) = Result.bind

(* A literal path atom [E.a1.….an]; an empty segment is an error. *)
let path (d : Reader.t) : (Value.path, Errors.t) result =
  match d with
  | Reader.Atom (s, p) -> (
      match Reader.split_dots s with
      | [] -> Errors.err ~pos:p "empty path atom"
      | root :: steps ->
          if root = "" || List.exists (fun seg -> seg = "") steps then
            Errors.err ~pos:p ("malformed dotted path `" ^ s ^ "`")
          else Ok { Value.root; steps })
  | Reader.List (_, p) -> Errors.err ~pos:p "expected a path, found a list"

(* The value target of [(is P V)] / [(set P V)]: an element or entity atom. *)
let target (d : Reader.t) : (string, Errors.t) result =
  match d with
  | Reader.Atom (s, p) ->
      if s = "" then Errors.err ~pos:p "empty value atom" else Ok s
  | Reader.List (_, p) -> Errors.err ~pos:p "expected an element or entity name"

(* The right-hand side of [(is P V)]: a dotted atom is a chain, anything else a
   literal (§10.2; see [Guard.rhs]). *)
let rhs (d : Reader.t) : (Model.rhs, Errors.t) result =
  match d with
  | Reader.Atom (s, _) when String.contains s '.' ->
      let* p = path d in
      Ok (Model.Chain p)
  | _ ->
      let* v = target d in
      Ok (Model.Lit v)

(* ---- the guard decoder: the drift-checked region begins here ------------- *)

let rec guard (d : Reader.t) : (Model.guard, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom (k, kp) :: args, _) -> (
      match (k, args) with
      | "and", gs ->
          let* gs = map_guards gs in
          Ok (Model.And gs)
      | "or", gs ->
          let* gs = map_guards gs in
          Ok (Model.Or gs)
      | "not", [ g ] ->
          let* g = guard g in
          Ok (Model.Not g)
      | "is", [ pd; vd ] ->
          let* pth = path pd in
          let* r = rhs vd in
          Ok (Model.Is (pth, r))
      | "defined", [ pd ] ->
          let* pth = path pd in
          Ok (Model.Defined pth)
      | "some", [ binder; body ] ->
          let* x, ty = binder_of binder in
          let* g = guard body in
          Ok (Model.Some_ (x, ty, g))
      | _ ->
          (* An unknown head is usually a library form with a missing
             [(load …)]; name it (§0.7). *)
          if List.mem k [ "and"; "or"; "not"; "is"; "defined"; "some" ] then
            Errors.err ~pos:kp "malformed guard clause"
          else
            Errors.err ~pos:kp
              ("unknown guard `" ^ k
             ^ "` — if it is a library form, check the (load …) that declares \
                it; there is no implicit prelude"))
  | Reader.List (_, p) -> Errors.err ~pos:p "malformed guard clause"
  | Reader.Atom (_, p) ->
      Errors.err ~pos:p "expected a guard clause, found a bare atom"

and map_guards = function
  | [] -> Ok []
  | g :: rest ->
      let* g = guard g in
      let* rest = map_guards rest in
      Ok (g :: rest)

and binder_of (d : Reader.t) : (string * string, Errors.t) result =
  match d with
  | Reader.List ([ Reader.Atom (x, _); Reader.Atom (ty, _) ], _) -> Ok (x, ty)
  | _ -> Reader.err_at d "expected a binder shaped (VAR TYPE)"

let effect (d : Reader.t) : (Model.effect, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom (k, kp) :: args, _) -> (
      match (k, args) with
      | "set", [ pd; vd ] ->
          let* pth = path pd in
          let* r = rhs vd in
          Ok (Model.Set (pth, r))
      | "vacate", [ pd ] ->
          let* pth = path pd in
          Ok (Model.Vacate pth)
      | "gap", [ Reader.Atom (msg, _) ] -> Ok (Model.Gap msg)
      | _ -> Errors.err ~pos:kp "malformed effect clause")
  | Reader.List (_, p) -> Errors.err ~pos:p "malformed effect clause"
  | Reader.Atom (_, p) -> Errors.err ~pos:p "expected an effect clause"

(* ---- path type-checking, positions re-attached (fold F3) ----------------- *)

type env = (string * string) list

(* §10.2: a literal must lie in the chain's target domain. With no [roster]
   (a law, a claims query), an open codomain can still reject a type name or a
   [some] binder. *)
let lit_fault (s : Schema.t) ~(roster : env option) ~(binders : string list)
    (cod : string) (v : string) : string option =
  let fault () =
    Some
      (if List.mem v binders then
         "`" ^ v
         ^ "` is a `some` binder, and a bare binder is not comparable — §10.2 \
            reads an atom with no dot as a literal, so this asks for an entity \
            of that name"
       else if Schema.type_of s v <> None then
         "`" ^ v
         ^ "` names a type, not a value — §7 gives types and entities one \
            namespace, so nothing in a roster can be called this"
       else "value " ^ v ^ " not in codomain " ^ cod)
  in
  match Schema.type_of s cod with
  | Some { flavor = Enumerated _; _ } ->
      if List.mem v (Schema.elements_of s cod) then None else fault ()
  | Some { flavor = Open; _ } -> (
      match roster with
      | Some r -> if List.assoc_opt v r = Some cod then None else fault ()
      | None ->
          if List.mem v binders || Schema.type_of s v <> None then fault ()
          else None)
  | None -> None

(* Check a path and return the type it lands in. *)
let check_path_cod (s : Schema.t) (env : env) (d : Reader.t) :
    (string, Errors.t) result =
  let* pth = path d in
  match Schema.check_path s env pth with
  | Error e -> Error { e with Errors.pos = Some (Reader.pos_of d) }
  | Ok arrows -> (
      match List.rev arrows with
      | last :: _ -> Ok last.Schema.cod
      | [] -> (
          match List.assoc_opt pth.Value.root env with
          | Some ty -> Ok ty
          | None -> Ok ""))

let check_path_at (s : Schema.t) (env : env) (d : Reader.t) :
    (unit, Errors.t) result =
  Result.map (fun _ -> ()) (check_path_cod s env d)

(* [env] types every possible path root, entity or binder. [roster] and
   [binders] keep them apart for [lit_fault]: an entity is a value, a binder
   is not. *)
let rec check_guard_in (s : Schema.t) ~(roster : env option)
    ~(binders : string list) (env : env) (d : Reader.t) :
    (unit, Errors.t) result =
  let recur = check_guard_in s ~roster ~binders in
  match d with
  | Reader.List (Reader.Atom (k, _) :: args, _) -> (
      match (k, args) with
      | "and", gs | "or", gs -> check_each s ~roster ~binders env gs
      | "not", [ g ] -> recur env g
      | "is", [ pd; vd ] -> check_is s ~roster ~binders env pd vd
      | "is", pd :: _ -> check_path_at s env pd
      | "defined", [ pd ] -> check_path_at s env pd
      | "some", [ binder; body ] ->
          let* x, ty = binder_of binder in
          check_guard_in s ~roster ~binders:(x :: binders) ((x, ty) :: env) body
      | _ -> Ok ())
  | _ -> Ok ()

(* Two compared chains must land in one type; otherwise the guard is never
   true and no one is told. A literal right side goes to [lit_fault]. *)
and check_is s ~roster ~binders env pd vd =
  let* lcod = check_path_cod s env pd in
  match vd with
  | Reader.Atom (v, _) when String.contains v '.' ->
      let* rcod = check_path_cod s env vd in
      if String.equal lcod rcod then Ok ()
      else
        Reader.err_at vd
          ("this chain lands in `" ^ rcod ^ "`, but the left one lands in `"
         ^ lcod ^ "` — comparing two chains needs a single target type")
  | _ -> (
      let* v = target vd in
      match lit_fault s ~roster ~binders lcod v with
      | None -> Ok ()
      | Some msg -> Reader.err_at vd msg)

and check_each s ~roster ~binders env = function
  | [] -> Ok ()
  | g :: rest ->
      let* () = check_guard_in s ~roster ~binders env g in
      check_each s ~roster ~binders env rest

(* A model guard is checked against the initial instance (§9.2). A claims
   query has only its binders, so entity literals there go unjudged (§16). *)
let check_guard (s : Schema.t) (env : env) (d : Reader.t) :
    (unit, Errors.t) result =
  check_guard_in s ~roster:(Some env) ~binders:[] env d

let check_query_guard (s : Schema.t) (binders : env) (d : Reader.t) :
    (unit, Errors.t) result =
  check_guard_in s ~roster:None ~binders:(List.map fst binders) binders d

(* The arrow an effect writes: the path's last; [None] if it has no steps. *)
let written_arrow (s : Schema.t) (env : env) (pd : Reader.t) :
    (Schema.arrow option, Errors.t) result =
  let* pth = path pd in
  match Schema.check_path s env pth with
  | Error e -> Error { e with Errors.pos = Some (Reader.pos_of pd) }
  | Ok arrows -> Ok (List.nth_opt (List.rev arrows) 0)

(* §8.3: no move may write a fixed arrow; the write would be a phantom
   self-loop. [what] has a space so the drift check skips it. *)
let check_mutable (what : string) (a : Schema.arrow) (pd : Reader.t) :
    (unit, Errors.t) result =
  if a.Schema.fixed then
    Reader.err_at pd
      ("arrow `" ^ a.Schema.name ^ "` is fixed, so no move may " ^ what
     ^ " — §8.3 makes a fixed answer wiring the instance sets once")
  else Ok ()

(* Kernel §5: [(set P V)] requires V in the codomain of P's last arrow. *)
let check_set (s : Schema.t) (env : env) (pd : Reader.t) (vd : Reader.t) :
    (unit, Errors.t) result =
  let* last = written_arrow s env pd in
  match last with
  | None -> Ok ()
  | Some last -> (
      let* () = check_mutable "set it" last pd in
      let cod = last.Schema.cod in
      match vd with
      (* A chain on the right must land in the same codomain, as in
         [check_is]. *)
      | Reader.Atom (v, _) when String.contains v '.' ->
          let* rcod = check_path_cod s env vd in
          if String.equal rcod cod then Ok ()
          else
            Reader.err_at vd
              ("this chain lands in `" ^ rcod ^ "`, but `" ^ last.Schema.name
             ^ "` takes `" ^ cod ^ "`")
      | _ -> (
          let* v = target vd in
          (* No binders: a [some] never scopes over the [do]. *)
          match lit_fault s ~roster:(Some env) ~binders:[] cod v with
          | None -> Ok ()
          | Some msg -> Reader.err_at vd msg))

(* §9.3: only a [vacatable] arrow may be emptied, so the engine never reaches
   a situation [State.build_ctx] would refuse as an instance. *)
let check_vacate (s : Schema.t) (env : env) (pd : Reader.t) :
    (unit, Errors.t) result =
  let* last = written_arrow s env pd in
  match last with
  | None -> Ok ()
  | Some a ->
      let* () = check_mutable "empty it" a pd in
      if a.Schema.vacatable then Ok ()
      else
        Reader.err_at pd
          ("arrow `" ^ a.Schema.name
         ^ "` is not vacatable, so no move may empty it — §9.3 permits an \
            empty slot only where the arrow allows one")

let check_effect (s : Schema.t) (env : env) (d : Reader.t) :
    (unit, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom (k, _) :: args, _) -> (
      match (k, args) with
      | "set", [ pd; vd ] -> check_set s env pd vd
      | "vacate", [ pd ] -> check_vacate s env pd
      | _ -> Ok ())
  | _ -> Ok ()
