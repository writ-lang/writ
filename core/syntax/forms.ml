open Pol_data

(* Form declarations: [(form PATTERN => TEMPLATE…)] collected into a [form_def]
   with hygiene checks (kernel §0.2, §6). Slot names are the ALL-CAPS words in
   the pattern; [&rest] names the single splice slot, in last position; the
   template may mention only reserved words, slots, and EARLIER forms. That last
   rule — a template can name neither itself nor a not-yet-declared form — is
   what makes the one-shot fixpoint (expander.ml) terminate. *)

type form_def = {
  name : string;
  pattern : Reader.t;
  template : Reader.t list;
  slots : string list;
  rest : string option;
}

let ( let* ) = Result.bind

(* The 28 reserved words, plus the interrogator's file-format words (so a claims
   library's forms may head their templates with [property]/[query]/…). A form
   may not be named a reserved word, a slot may not collide with one, and these
   are exactly the callable heads a template may legally mention. *)
let reserved =
  [
    "use";
    "load";
    "schema";
    "type";
    "arrow";
    "to";
    "of";
    "fixed";
    "vacatable";
    "equation";
    "=";
    "instance";
    "initial";
    "vacant";
    "transition";
    "when";
    "do";
    "set";
    "vacate";
    "gap";
    "form";
    "&rest";
    "and";
    "or";
    "not";
    "is";
    "defined";
    "some";
    "property";
    "never";
    "possible";
    "live";
    "query";
    "where";
    "accept";
    "check";
    "via";
    "functor";
    "from";
    "over";
    "map";
  ]

let is_reserved w = List.mem w reserved

(* A slot is an ALL-CAPS atom: at least one A–Z, and no a–z. *)
let is_slot s =
  s <> ""
  && String.exists (fun c -> c >= 'A' && c <= 'Z') s
  && not (String.exists (fun c -> c >= 'a' && c <= 'z') s)

(* Collect the ALL-CAPS slot atoms of a nested (structural) pattern item,
   prepending onto [acc]. [&rest] is a top-level-only construct; reject it
   below the top level. *)
let rec nested_slots acc (it : Reader.t) : (string list, Errors.t) result =
  match it with
  | Reader.Atom ("&rest", p) ->
      Errors.err ~pos:p "&rest may not appear inside a nested form pattern"
  | Reader.Atom (a, _) -> Ok (if is_slot a then a :: acc else acc)
  | Reader.List (items, _) -> nested_slots_all acc items

and nested_slots_all acc = function
  | [] -> Ok acc
  | x :: xs ->
      let* acc = nested_slots acc x in
      nested_slots_all acc xs

(* Read the pattern items after the head into (slots, rest), enforcing ≤1
   [&rest] and only in last position. Non-slot literals match literally in the
   expander and are not recorded as slots; a nested list matches structurally,
   contributing the slots it contains (kernel §6). *)
let rec parse_items acc = function
  | [] -> Ok (List.rev acc, None)
  | Reader.Atom ("&rest", p) :: tl -> (
      match tl with
      | [ Reader.Atom (r, _) ] -> Ok (List.rev acc, Some r)
      | [] -> Errors.err ~pos:p "&rest must be followed by a slot name"
      | _ -> Errors.err ~pos:p "&rest must be in the last position")
  | Reader.Atom (a, _) :: tl ->
      if is_slot a then parse_items (a :: acc) tl else parse_items acc tl
  | Reader.List (items, _) :: tl ->
      let* nested = nested_slots_all [] items in
      parse_items (nested @ acc) tl

let collect (d : Reader.t) ~(earlier : form_def list) :
    (form_def, Errors.t) result =
  match d with
  | Reader.List
      ( Reader.Atom ("form", _) :: pattern :: Reader.Atom ("=>", _) :: template,
        _ )
    when template <> [] ->
      let* name, name_pos, slots, rest =
        match pattern with
        | Reader.Atom (n, p) -> Ok (n, p, [], None)
        | Reader.List (Reader.Atom (n, p) :: items, _) ->
            let* slots, rest = parse_items [] items in
            Ok (n, p, slots, rest)
        | Reader.List (_, p) ->
            Errors.err ~pos:p "a form pattern must be headed by a name"
      in
      let earlier_names = List.map (fun fd -> fd.name) earlier in
      let all_slots = slots @ match rest with Some r -> [ r ] | None -> [] in
      let clashes s = is_reserved s || List.mem s earlier_names in
      let* () =
        if is_reserved name then
          Errors.err ~pos:name_pos
            ("a form may not be named the reserved word `" ^ name ^ "`")
        else if List.mem name earlier_names then
          Errors.err ~pos:name_pos ("form `" ^ name ^ "` is already declared")
        else
          match List.find_opt clashes all_slots with
          | Some s ->
              Errors.err ~pos:name_pos
                ("slot `" ^ s ^ "` collides with a name in scope")
          | None -> Ok ()
      in
      (* Reject a template that names its own form (recursion) or a head that is
         neither reserved, a slot, nor an earlier form (a forward reference). *)
      let allowed_head h =
        is_reserved h || List.mem h all_slots || List.mem h earlier_names
      in
      (* A nullary form is invoked as a bare atom, so a bare atom equal to the
         name is a self-invocation. A form with slots is only ever invoked as a
         list head, so its name occurring as a bare (non-head) atom is data — a
         §7 claim-form names itself as the [property]/[query] symbol — and must
         not be flagged. *)
      let nullary = slots = [] && rest = None in
      let rec scan (t : Reader.t) =
        match t with
        | Reader.Atom (a, p) ->
            if a = name && nullary then
              Errors.err ~pos:p
                ("form `" ^ name ^ "` recurses: its template references itself")
            else Ok ()
        | Reader.List (Reader.Atom (h, hp) :: tl, _) ->
            if h = name then
              Errors.err ~pos:hp
                ("form `" ^ name ^ "` recurses: its template references itself")
            else if allowed_head h then scan_all tl
            else
              Errors.err ~pos:hp
                ("template of `" ^ name ^ "` mentions `" ^ h
               ^ "`, a form not yet declared")
        | Reader.List (items, _) -> scan_all items
      and scan_all = function
        | [] -> Ok ()
        | x :: xs ->
            let* () = scan x in
            scan_all xs
      in
      let* () = scan_all template in
      Ok { name; pattern; template; slots; rest }
  | Reader.List (Reader.Atom ("form", _) :: _, p) ->
      Errors.err ~pos:p "malformed form: expected (form PATTERN => TEMPLATE …)"
  | _ -> Reader.err_at d "expected a (form …) declaration"
