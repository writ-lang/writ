(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* [(form PATTERN TEMPLATE…)] declarations, with hygiene checks (kernel §0.2,
   §6). A template may mention only reserved words, blanks and earlier forms,
   which is what makes expansion terminate. *)

type form_def = {
  name : string;
  pattern : Reader.t;
  template : Reader.t list;
  blanks : string list;
  rest : string option;
}

let ( let* ) = Result.bind

(* The 26 reserved words plus the claims and rules file words: no form or
   blank may take one, and templates may use them as heads. *)
let reserved =
  [
    "use";
    "load";
    "schema";
    "type";
    "arrow";
    "to";
    "fixed";
    "vacatable";
    "equation";
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
    "inevitable";
    "query";
    "where";
    "accept";
    "check";
    "via";
    "functor";
    "from";
    "over";
    "map";
    "relation";
    "rule";
  ]

let is_reserved w = List.mem w reserved

(* A blank is an ALL-CAPS atom: at least one A–Z, and no a–z. Deliberately
   separate from [Rules.is_var] (see there). *)
let is_blank s =
  s <> ""
  && String.exists (fun c -> c >= 'A' && c <= 'Z') s
  && not (String.exists (fun c -> c >= 'a' && c <= 'z') s)

(* The blanks of a nested pattern item; [&rest] is not allowed there. *)
let rec nested_blanks acc (it : Reader.t) : (string list, Errors.t) result =
  match it with
  | Reader.Atom ("&rest", p) ->
      Errors.err ~pos:p "&rest may not appear inside a nested form pattern"
  | Reader.Atom (a, _) -> Ok (if is_blank a then a :: acc else acc)
  | Reader.List (items, _) -> nested_blanks_all acc items

and nested_blanks_all acc = function
  | [] -> Ok acc
  | x :: xs ->
      let* acc = nested_blanks acc x in
      nested_blanks_all acc xs

(* The pattern items as (blanks, rest); [&rest] at most once, last (§6). *)
let rec parse_items acc = function
  | [] -> Ok (List.rev acc, None)
  | Reader.Atom ("&rest", p) :: tl -> (
      match tl with
      | [ Reader.Atom (r, _) ] -> Ok (List.rev acc, Some r)
      | [] -> Errors.err ~pos:p "&rest must be followed by a blank name"
      | _ -> Errors.err ~pos:p "&rest must be in the last position")
  | Reader.Atom (a, _) :: tl ->
      if is_blank a then parse_items (a :: acc) tl else parse_items acc tl
  | Reader.List (items, _) :: tl ->
      let* nested = nested_blanks_all [] items in
      parse_items (nested @ acc) tl

(* [open_heads] (.rules files) skips the unknown-head check: relation names
   are unknown here, and [Rules_check] reports them. *)
let collect ?(open_heads = false) (d : Reader.t) ~(earlier : form_def list) :
    (form_def, Errors.t) result =
  match d with
  (* The old `(form P => T)` spelling would otherwise parse as a form whose
     first template is `=>`. *)
  | Reader.List (Reader.Atom ("form", _) :: _ :: Reader.Atom ("=>", ap) :: _, _)
    ->
      Errors.err ~pos:ap
        "`=>` is no longer part of a form: write (form PATTERN TEMPLATE …), \
         with the template following the pattern directly"
  | Reader.List (Reader.Atom ("form", _) :: pattern :: template, _)
    when template <> [] ->
      let* name, name_pos, blanks, rest =
        match pattern with
        | Reader.Atom (n, p) -> Ok (n, p, [], None)
        | Reader.List (Reader.Atom (n, p) :: items, _) ->
            let* blanks, rest = parse_items [] items in
            Ok (n, p, blanks, rest)
        | Reader.List (_, p) ->
            Errors.err ~pos:p "a form pattern must be headed by a name"
      in
      let earlier_names = List.map (fun fd -> fd.name) earlier in
      let all_blanks =
        blanks @ match rest with Some r -> [ r ] | None -> []
      in
      let clashes s = is_reserved s || List.mem s earlier_names in
      let* () =
        if is_reserved name then
          Errors.err ~pos:name_pos
            ("a form may not be named the reserved word `" ^ name ^ "`")
        else if List.mem name earlier_names then
          Errors.err ~pos:name_pos ("form `" ^ name ^ "` is already declared")
        else
          match List.find_opt clashes all_blanks with
          | Some s ->
              Errors.err ~pos:name_pos
                ("blank `" ^ s ^ "` collides with a name in scope")
          | None -> Ok ()
      in
      (* Reject self-reference and forward references. *)
      let allowed_head h =
        open_heads || is_reserved h || List.mem h all_blanks
        || List.mem h earlier_names
      in
      (* Only a nullary form is invoked as a bare atom; for other forms the
         name as an atom is data (a claim-form names itself, §7). *)
      let nullary = blanks = [] && rest = None in
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
      Ok { name; pattern; template; blanks; rest }
  | Reader.List (Reader.Atom ("form", _) :: _, p) ->
      Errors.err ~pos:p "malformed form: expected (form PATTERN TEMPLATE …)"
  | _ -> Reader.err_at d "expected a (form …) declaration"
