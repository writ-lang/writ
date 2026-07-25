open Pol_data

(* The value grammar: datum -> guard / effect / path / target decoders. This is
   the single source the editor's TextMate grammar is drift-checked against
   (.afk-flow/check-grammar.py): the checker reads every clean lowercase string
   literal from [let rec guard] to end-of-file and asserts each is highlighted.
   So the guard keywords [and or not is defined some] and the effect keywords
   [set vacate gap] live here as bare literals, and every error message in that
   region carries a space or a capital so it is filtered out.

   Decoding is purely structural — a [Value.path] is split off a dotted atom via
   [Reader.split_dots]; type-checking a path against the schema is [check_guard]
   / [check_effect] (fold F3), which re-attach the datum's [line:col] to a
   [Schema.check_path] rejection. Callers (parser, claims_parser) run both. *)

let ( let* ) = Result.bind

(* A literal path atom [E.a1.….an], split on '.' into a [Value.path]. A leading
   or trailing dot leaves an empty segment and is a read error. *)
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
          let* v = target vd in
          Ok (Model.Is (pth, v))
      | "defined", [ pd ] ->
          let* pth = path pd in
          Ok (Model.Defined pth)
      | "some", [ binder; body ] ->
          let* x, ty = binder_of binder in
          let* g = guard body in
          Ok (Model.Some_ (x, ty, g))
      | _ -> Errors.err ~pos:kp "malformed guard clause")
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
          let* v = target vd in
          Ok (Model.Set (pth, v))
      | "vacate", [ pd ] ->
          let* pth = path pd in
          Ok (Model.Vacate pth)
      | "gap", [ Reader.Atom (msg, _) ] -> Ok (Model.Gap msg)
      | _ -> Errors.err ~pos:kp "malformed effect clause")
  | Reader.List (_, p) -> Errors.err ~pos:p "malformed effect clause"
  | Reader.Atom (_, p) -> Errors.err ~pos:p "expected an effect clause"

(* ---- path type-checking, positions re-attached (fold F3) ----------------- *)

type env = (string * string) list

let check_path_at (s : Schema.t) (env : env) (d : Reader.t) :
    (unit, Errors.t) result =
  let* pth = path d in
  match Schema.check_path s env pth with
  | Ok _ -> Ok ()
  | Error e -> Error { e with Errors.pos = Some (Reader.pos_of d) }

let rec check_guard (s : Schema.t) (env : env) (d : Reader.t) :
    (unit, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom (k, _) :: args, _) -> (
      match (k, args) with
      | "and", gs | "or", gs -> check_each s env gs
      | "not", [ g ] -> check_guard s env g
      | "is", pd :: _ -> check_path_at s env pd
      | "defined", [ pd ] -> check_path_at s env pd
      | "some", [ binder; body ] ->
          let* x, ty = binder_of binder in
          check_guard s ((x, ty) :: env) body
      | _ -> Ok ())
  | _ -> Ok ()

and check_each s env = function
  | [] -> Ok ()
  | g :: rest ->
      let* () = check_guard s env g in
      check_each s env rest

(* Kernel §5: [(set P V)] additionally requires V lie in the codomain of P's
   last arrow. [Schema.check_path] validates the path and hands back its arrows
   in order; the last arrow's [cod] is the type V must inhabit — an enumerated
   value of it, or (for an open cod) an entity the env declares of that type.
   The value's own [line:col] is re-attached on a rejection. *)
let check_set (s : Schema.t) (env : env) (pd : Reader.t) (vd : Reader.t) :
    (unit, Errors.t) result =
  let* pth = path pd in
  match Schema.check_path s env pth with
  | Error e -> Error { e with Errors.pos = Some (Reader.pos_of pd) }
  | Ok arrows -> (
      let* v = target vd in
      match List.rev arrows with
      | [] -> Ok ()
      | last :: _ ->
          let cod = last.Schema.cod in
          let ok =
            match Schema.type_of s cod with
            | Some { flavor = Enumerated _; _ } ->
                List.mem v (Schema.elements_of s cod)
            | Some { flavor = Open; _ } -> List.assoc_opt v env = Some cod
            | None -> true
          in
          if ok then Ok ()
          else Reader.err_at vd ("value " ^ v ^ " not in codomain " ^ cod))

let check_effect (s : Schema.t) (env : env) (d : Reader.t) :
    (unit, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom (k, _) :: args, _) -> (
      match (k, args) with
      | "set", [ pd; vd ] -> check_set s env pd vd
      | "vacate", [ pd ] -> check_path_at s env pd
      | _ -> Ok ())
  | _ -> Ok ()
