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

(* A law is a guard (§8.6), not a pair of chains. It ranges over one type — its
   guard's single free root, the subject the implicit quantification is about —
   which [Decl] checks at declaration and [Eval] binds at evaluation. *)
type equation = { name : string; body : Guard.t }

type t = {
  name : string;
  types : ty list;
  arrows : arrow list;
  equations : equation list;
}

let type_of (s : t) (name : string) : ty option =
  List.find_opt (fun (ty : ty) -> ty.name = name) s.types

(* Arrow names are scoped to their dom type (kernel §2 namespace), so an arrow
   is looked up by the pair (dom, name). The flat [s.arrows] is authoritative;
   the per-type [arrows] list is consulted as a fallback so a schema built only
   with types (arrows nested under them) still resolves. *)
let arrow_in (s : t) ~(dom : string) (name : string) : arrow option =
  let matches (a : arrow) = a.dom = dom && a.name = name in
  match List.find_opt matches s.arrows with
  | Some a -> Some a
  | None -> (
      match type_of s dom with
      | Some ty -> List.find_opt (fun (a : arrow) -> a.name = name) ty.arrows
      | None -> None)

let cod_type (s : t) (a : arrow) : ty option = type_of s a.cod

(* The elements a type can take: the declared values of an enumerated type. An
   open type's elements live in the instance roster, not the schema, so the
   schema alone reports none. *)
let elements_of (s : t) (name : string) : string list =
  match type_of s name with
  | Some { flavor = Enumerated vs; _ } -> vs
  | Some { flavor = Open; _ } | None -> []

(* Kernel §3 / fold F3: type-check a literal path [E.a1.…an] against the schema.
   [env] binds every name that may head a path to its type — an instance entity
   OR a [some]-bound variable, supplied by the caller the same way. The root is
   resolved through [env]; each step must be an arrow whose dom is the current
   type, and the walk advances to that arrow's cod. On success the arrows are
   returned in path order (so a caller can, e.g., read off the final cod); on
   failure a diagnostic names the offending step. The [Value.path] carries no
   source position, so [pos] is [None] here — the caller (which holds the datum)
   attaches the [line:col]. *)
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
