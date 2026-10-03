(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The Olog: the world category. Types are objects, arrows are morphisms,
   equations are the relational routes that must agree. *)

type flavor = Enumerated of string list | Open

type arrow = {
  name : string;
  dom : string;
  cod : string;
  fixed : bool;
  vacatable : bool;
}

type ty = { name : string; flavor : flavor; arrows : arrow list }

(* A law is a guard (§8.6) over one type: its single free root, which [Decl]
   checks and [Eval] binds. [origin] is as on a transition. *)
type equation = { name : string; body : Guard.t; origin : string option }

type t = {
  name : string;
  types : ty list;
  arrows : arrow list;
  equations : equation list;
}

let type_of (s : t) (name : string) : ty option =
  List.find_opt (fun (ty : ty) -> ty.name = name) s.types

(* Arrow names are scoped to their dom (kernel §2). The flat [s.arrows] is
   authoritative; the per-type list is a fallback for schemas built only with
   nested arrows. *)
let arrow_in (s : t) ~(dom : string) (name : string) : arrow option =
  let matches (a : arrow) = a.dom = dom && a.name = name in
  match List.find_opt matches s.arrows with
  | Some a -> Some a
  | None -> (
      match type_of s dom with
      | Some ty -> List.find_opt (fun (a : arrow) -> a.name = name) ty.arrows
      | None -> None)

let cod_type (s : t) (a : arrow) : ty option = type_of s a.cod

(* The declared values of an enumerated type. Open types' elements live in the
   instance roster, so this returns none for them. *)
let elements_of (s : t) (name : string) : string list =
  match type_of s name with
  | Some { flavor = Enumerated vs; _ } -> vs
  | Some { flavor = Open; _ } | None -> []

(* Kernel §3: type-check a path; [env] types its possible roots. Returns the
   arrows in order. The caller attaches the error's position. *)
let check_path (s : t) (env : (string * string) list) (p : Value.path) :
    (arrow list, Errors.t) result =
  match List.assoc_opt p.root env with
  | None -> Errors.err ("unknown entity or variable `" ^ p.root ^ "`")
  | Some root_ty ->
      let rec walk (cur : string) (acc : arrow list) = function
        | [] -> Ok (List.rev acc)
        | step :: rest -> (
            match arrow_in s ~dom:cur step with
            | None -> Errors.err ("`" ^ cur ^ "` has no arrow `" ^ step ^ "`")
            | Some a -> walk a.cod (a :: acc) rest)
      in
      walk root_ty [] p.steps
