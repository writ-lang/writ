open Pol_data

(* §8's constraints that can only be stated once the schema is *whole*, split out
   of decl.ml at the seam that file's own comments already draw: decoding turns a
   datum into data, and these checks resolve names against the assembled result.
   A type may be declared after the arrow that points at it, and an arrow may be
   declared at schema top level for a type whose body declares another of the
   same name — neither is visible to a decoder walking one clause at a time.

   The positions travel here from the decoder because [Schema.arrow] and
   [Schema.equation] are data, not syntax, and carry none of their own. *)

let ( let* ) = Result.bind

(* Where an arrow named itself and its endpoints, so §8.3's constraints can each
   be blamed at the atom that got it wrong. [dom_at] is [None] when the arrow
   sits inside a [(type …)] body, because then its domain is the enclosing type
   and cannot fail to be declared. *)
type arrow_at = {
  name_at : Errors.pos;
  cod_at : Errors.pos;
  dom_at : Errors.pos option;
}

(* §8.3: "The `to` TYPE must be a *named*, declared type" — and the same for an
   explicit [(of TYPE)] domain.

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

(* §8.3: "NAME fresh among the owner's arrows (§7)" — *among the owner's*, which
   is why this is not [Names]' business. §7 is explicit that two types may each
   own an arrow called `status`, and the river scenario leans on it
   (traveler.at, cargo.at), so the key is the pair (dom, name) and never the
   name alone.

   Two arrows of one name on one type would otherwise both stand, with
   [Schema.arrow_in] silently returning whichever its scan reaches first — so
   the duplicate decides what every chain through that arrow *means*, and the
   author is never told there was a choice. The whole schema has to be in hand
   because the two declarations need not sit together: one may be nested in the
   [(type …)] body and the other written at schema top level with an
   [(of TYPE)] domain naming it. *)
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

let check_equation (s : Schema.t) ((eq, pos) : Schema.equation * Errors.pos) :
    (unit, Errors.t) result =
  let side (p : Value.path) =
    match Schema.check_path s [ (p.Value.root, p.Value.root) ] p with
    | Ok _ -> Ok ()
    | Error e -> Error { e with Errors.pos = Some pos }
  in
  let* () = side eq.Schema.lhs in
  side eq.Schema.rhs
