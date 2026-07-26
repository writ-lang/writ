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

(* The right-hand side of [(is P V)]: a dotted atom is a second chain, anything
   else a literal (§10.2). The test is lexical and deliberately so — the reader
   already splits a dotted atom (§5.2), a literal element or entity name never
   contains a dot, and therefore no guard written before chains were allowed
   here can change meaning. The cost is that a bare [some]-binder stays
   uncomparable, having no dot either; the chains that motivate comparing at
   all are dotted. *)
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
          (* A known head with the wrong shape is malformed; an UNKNOWN head is
             almost always a library form whose [(load …)] is missing, and after
             `=` moved to the standard library that is the first thing anyone
             hits. §0.7 promises such a name surfaces as a name error, so say
             which name, rather than blaming the parentheses. *)
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

(* A checked path, and the type it lands in — the last arrow's cod, or the
   root's own type where the chain has no steps. Comparing two chains needs the
   landing type, which [check_path_at] used to discard. *)
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

let rec check_guard (s : Schema.t) (env : env) (d : Reader.t) :
    (unit, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom (k, _) :: args, _) -> (
      match (k, args) with
      | "and", gs | "or", gs -> check_each s env gs
      | "not", [ g ] -> check_guard s env g
      | "is", [ pd; vd ] -> check_is s env pd vd
      | "is", pd :: _ -> check_path_at s env pd
      | "defined", [ pd ] -> check_path_at s env pd
      | "some", [ binder; body ] ->
          let* x, ty = binder_of binder in
          check_guard s ((x, ty) :: env) body
      | _ -> Ok ())
  | _ -> Ok ()

(* [(is A B)] with a chain on the right compares two cells, so they must be
   cells of one type — the chain analogue of §10.2's "V in the chain's target
   domain". Without this a mistyped comparison is not an error but a guard that
   is simply never true, which is the worst of both: no diagnostic, and a move
   that silently never fires. A literal right side is left to [check_set]'s
   sibling rules as before. *)
and check_is s env pd vd =
  let* lcod = check_path_cod s env pd in
  match vd with
  | Reader.Atom (v, _) when String.contains v '.' ->
      let* rcod = check_path_cod s env vd in
      if String.equal lcod rcod then Ok ()
      else
        Reader.err_at vd
          ("this chain lands in `" ^ rcod ^ "`, but the left one lands in `"
         ^ lcod ^ "` — comparing two chains needs a single target type")
  | _ -> Ok ()

and check_each s env = function
  | [] -> Ok ()
  | g :: rest ->
      let* () = check_guard s env g in
      check_each s env rest

(* The arrow an effect writes to: the last of the path's arrows, with the path's
   own [line:col] to blame. [None] for a rootless path (no steps, so nothing is
   written); a rejected path keeps reporting at the path atom, as before. *)
let written_arrow (s : Schema.t) (env : env) (pd : Reader.t) :
    (Schema.arrow option, Errors.t) result =
  let* pth = path pd in
  match Schema.check_path s env pth with
  | Error e -> Error { e with Errors.pos = Some (Reader.pos_of pd) }
  | Ok arrows -> Ok (List.nth_opt (List.rev arrows) 0)

(* §8.3: "`fixed` — the answer is set once by the instance and never changes:
   wiring." So no move may write a fixed arrow, by either effect.

   This is not a tidiness rule. [State.build_ctx] hoists every fixed cell out of
   the state vector, so a write to one has no cell to land in: the effect is
   applied, changes nothing, and the move becomes a self-loop on every situation
   its guard admits. Those phantom edges are not cosmetic — every modality answer
   is computed over that graph, and [live] (AG EF F) reads a self-loop as
   progress. An illegal write does not merely go unnoticed; it invents structure
   and then gets asked questions about it.

   [(vacate P)] is checked here too and not only for [vacatable], because a
   `fixed vacatable` arrow is otherwise the same hole through the other effect.

   [what] arrives as a phrase rather than a bare verb so it carries a space: this
   region is the drift-checked one, where a clean lowercase one-word literal is
   read as a keyword the editor must highlight. *)
let check_mutable (what : string) (a : Schema.arrow) (pd : Reader.t) :
    (unit, Errors.t) result =
  if a.Schema.fixed then
    Reader.err_at pd
      ("arrow `" ^ a.Schema.name ^ "` is fixed, so no move may " ^ what
     ^ " — §8.3 makes a fixed answer wiring the instance sets once")
  else Ok ()

(* Kernel §5: [(set P V)] additionally requires V lie in the codomain of P's last
   arrow — an enumerated value of it, or (for an open cod) an entity the env
   declares of that type. The value's own [line:col] is re-attached on a
   rejection. *)
let check_set (s : Schema.t) (env : env) (pd : Reader.t) (vd : Reader.t) :
    (unit, Errors.t) result =
  let* last = written_arrow s env pd in
  match last with
  | None -> Ok ()
  | Some last ->
      let* () = check_mutable "set it" last pd in
      let* v = target vd in
      let cod = last.Schema.cod in
      let ok =
        match Schema.type_of s cod with
        | Some { flavor = Enumerated _; _ } ->
            List.mem v (Schema.elements_of s cod)
        | Some { flavor = Open; _ } -> List.assoc_opt v env = Some cod
        | None -> true
      in
      if ok then Ok ()
      else Reader.err_at vd ("value " ^ v ^ " not in codomain " ^ cod)

(* §9.3 makes emptiness the privilege of a [vacatable] arrow, and
   [State.build_ctx] enforces it on an *instance*: an unset, non-vacatable cell
   is rejected there. A [(vacate P)] on such an arrow let the engine walk into
   exactly the state its own totality check forbids — reachable, reported, and
   unrepresentable as a written instance. The engine must not be able to reach a
   situation the instance rules would refuse. *)
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
