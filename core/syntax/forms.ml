open Pol_data

(* Form declarations: [(form PATTERN TEMPLATE…)] collected into a [form_def]
   with hygiene checks (kernel §0.2, §6). Blank names are the ALL-CAPS words
   in the pattern; [&rest] names the single splice blank, in last position; the
   template may mention only reserved words, blanks, and EARLIER forms. That
   last rule — a template can name neither itself nor a not-yet-declared
   form — is what makes the one-shot fixpoint (expander.ml) terminate. *)

type form_def = {
  name : string;
  pattern : Reader.t;
  template : Reader.t list;
  blanks : string list;
  rest : string option;
}

let ( let* ) = Result.bind

(* The 26 reserved words, plus the interrogator's file-format words (so a claims
   library's forms may head their templates with [property]/[query]/…, and a
   rules library's with [relation]/[rule]). A form may not be named a reserved
   word, a blank may not collide with one, and these are exactly the callable
   heads a template may legally mention.

   Reserving a word has a price, paid once per entry: [allowed_head] below lets
   a template mention it freely, so a template naming a form that does not exist
   yet stops being an error the moment that name joins this list. There is no
   way to charge it per file type — one expander serves all three, and a form's
   legality must not depend on which file happens to load it. *)
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

(* A blank is an ALL-CAPS atom: at least one A–Z, and no a–z.

   [Rules.is_var] in the OPTIONAL interrogator extension spells the same test
   for a different concept — a rule variable, not a form blank. The
   duplication is deliberate: sharing one definition would point the kernel's
   form expander at an extension a conforming processor need not implement.
   Change one and the other stays as it is. *)
let is_blank s =
  s <> ""
  && String.exists (fun c -> c >= 'A' && c <= 'Z') s
  && not (String.exists (fun c -> c >= 'a' && c <= 'z') s)

(* Collect the ALL-CAPS blank atoms of a nested (structural) pattern item,
   prepending onto [acc]. [&rest] is a top-level-only construct; reject it
   below the top level. *)
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

(* Read the pattern items after the head into (blanks, rest), enforcing ≤1
   [&rest] and only in last position. Non-blank literals match literally in the
   expander and are not recorded as blanks; a nested list matches structurally,
   contributing the blanks it contains (kernel §6). *)
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

(* [open_heads] relaxes ONE rule below, for one file type, and the reason is
   that the rule is unanswerable there rather than unwanted.

   A template's heads are checked against what the expander knows: reserved
   words, the form's own blanks, and forms already declared. In a .pol or
   .claims file that is the whole vocabulary, so an unknown head IS a typo or a
   forward reference. In a .rules file it is not: a rule body's heads are
   RELATIONS, which do not exist until the program is parsed — the extension's
   built-ins (`situation`, `edge`, `holds`) and every relation the file itself
   declares. The expander cannot know any of them, so the check there rejects
   correct programs and catches nothing.

   Nothing is lost by relaxing it, which is the condition for doing so: an
   unknown head in a rule body is refused by [Rules_check] with its own position
   and the declaration to add — a better diagnostic than this one, arriving where
   the knowledge is. The self-recursion rule is NOT relaxed; it needs no
   vocabulary.

   It is a flag rather than a list of the extension's words on purpose. A list
   would put the interrogator's vocabulary inside the kernel's expander, which
   a conforming processor (§14) need not implement — the same coupling
   [is_blank]'s note above declines — and it would still be wrong, since no
   list can contain the relations a file has yet to declare. *)
let collect ?(open_heads = false) (d : Reader.t) ~(earlier : form_def list) :
    (form_def, Errors.t) result =
  (* `=>` was the language's only infix token. It carried no information the
     position does not already give — the pattern is element 2, the templates
     are the rest — so removing it makes §2.5's "every datum is a parenthesised
     list headed by a word" true without exception. *)
  match d with
  (* An un-migrated form would otherwise be READ, not refused: `=>` is now an
     ordinary atom, so the old spelling parses as a form whose first template
     is `=>` — a different form, accepted in silence. Name it instead. *)
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
      (* Reject a template that names its own form (recursion) or a head that
         is neither reserved, a blank, nor an earlier form (a forward
         reference). *)
      let allowed_head h =
        open_heads || is_reserved h || List.mem h all_blanks
        || List.mem h earlier_names
      in
      (* A nullary form is invoked as a bare atom, so a bare atom equal to the
         name is a self-invocation. A form with blanks is only ever invoked as a
         list head, so its name occurring as a bare (non-head) atom is data — a
         §7 claim-form names itself as the [property]/[query] symbol — and must
         not be flagged. *)
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
