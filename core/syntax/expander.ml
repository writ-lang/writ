open Pol_data

(* One-shot fixpoint expansion, no computation (kernel §0.2, §6). Datums are
   processed left-to-right: a [(form …)] registers into the running scope (via
   [Forms.collect]) and is dropped from the output; any other datum is rewritten
   to a fixpoint by substituting a form invocation's blanks and splicing its one
   [&rest] through [@BLANK]. Because [Forms.collect] forbade a template from
   naming itself or a later form, no invocation can introduce a cycle, so the
   fixpoint always terminates; a large step cap is only a safety net. *)

let ( let* ) = Result.bind
let cap = 100_000
let is_splice s = String.length s > 1 && s.[0] = '@'

(* A form is nullary when it takes no blanks and no [&rest]. Only a nullary
   form is invoked as a bare atom, so only a nullary name may expand in atom
   position; a form WITH blanks is invoked as a list head, so its name occurring
   as a bare atom is data (e.g. a §7 claim-form's [(property NAME …)] symbol)
   and is left untouched. *)
let is_nullary (fd : Forms.form_def) =
  fd.Forms.blanks = [] && fd.Forms.rest = None

let splice_name s = String.sub s 1 (String.length s - 1)

let rec map_r f = function
  | [] -> Ok []
  | x :: xs ->
      let* y = f x in
      let* ys = map_r f xs in
      Ok (y :: ys)

let rec concat_map_r f = function
  | [] -> Ok []
  | x :: xs ->
      let* y = f x in
      let* ys = concat_map_r f xs in
      Ok (y @ ys)

(* Match a form's pattern against an invocation's args, binding each blank to a
   datum and the optional [&rest] to the remaining datums. *)
let bind (fd : Forms.form_def) (args : Reader.t list) (pos : Errors.pos) :
    ( (string * Reader.t) list * (string * Reader.t list) option,
      Errors.t )
    result =
  let pat_items =
    match fd.Forms.pattern with
    | Reader.List (_ :: items, _) -> items
    | Reader.Atom _ | Reader.List ([], _) -> []
  in
  (* Match one pattern item against one argument, extending [env]. A nested
     list matches structurally; [&rest] never appears below the top level. *)
  let rec match1 env (pat : Reader.t) (arg : Reader.t) =
    match pat with
    | Reader.Atom (a, _) when Forms.is_blank a -> Ok ((a, arg) :: env)
    | Reader.Atom (lit, lp) -> (
        match arg with
        | Reader.Atom (a, _) when a = lit -> Ok env
        | _ ->
            Errors.err ~pos:lp
              ("form pattern literal `" ^ lit
             ^ "` does not match the invocation"))
    | Reader.List (pits, lp) -> (
        match arg with
        | Reader.List (aits, _) -> match_all env lp pits aits
        | Reader.Atom _ ->
            Errors.err ~pos:lp
              "the invocation does not match a structural form pattern")
  and match_all env lp pits aits =
    match (pits, aits) with
    | [], [] -> Ok env
    | p :: ps, a :: az ->
        let* env = match1 env p a in
        match_all env lp ps az
    | _ :: _, [] | [], _ :: _ ->
        Errors.err ~pos:lp
          "the invocation does not match a structural form pattern"
  in
  let rec go env pats args =
    match (pats, args) with
    | [], [] -> Ok (List.rev env, None)
    | Reader.Atom ("&rest", _) :: Reader.Atom (r, _) :: _, rest_args ->
        Ok (List.rev env, Some (r, rest_args))
    | _ :: _, [] -> Errors.err ~pos "too few arguments to a form invocation"
    | [], _ :: _ -> Errors.err ~pos "too many arguments to a form invocation"
    | pat :: ps, arg :: az ->
        let* env = match1 env pat arg in
        go env ps az
  in
  go [] pat_items args

(* Rewrite a template datum: blanks become their bound datums, and an [@BLANK]
   atom splices the [&rest] binding into its enclosing list. *)
let rec subst env rest (d : Reader.t) : (Reader.t, Errors.t) result =
  match d with
  | Reader.Atom (a, p) -> (
      match Reader.split_dots a with
      | [] | [ _ ] -> (
          (* A bare atom (no dot): the whole atom is the blank key, and its
             bound datum — atom or list — replaces it. *)
          match List.assoc_opt a env with
          | Some v -> Ok v
          | None -> Ok d)
      | head :: tail -> (
          (* A dot-path: substitute only its ROOT segment, keeping the rest. *)
          match List.assoc_opt head env with
          | None -> Ok d
          | Some (Reader.Atom (e, _)) ->
              Ok (Reader.Atom (String.concat "." (e :: tail), p))
          | Some (Reader.List _) ->
              Errors.err ~pos:p
                ("form blank `" ^ head
               ^ "` heads a path but is bound to a list, not an entity")))
  | Reader.List (items, p) ->
      let one it =
        match it with
        | Reader.Atom (s, _) when is_splice s -> (
            match rest with
            | Some (rname, ds) when splice_name s = rname -> Ok ds
            | _ ->
                let* x = subst env rest it in
                Ok [ x ])
        | _ ->
            let* x = subst env rest it in
            Ok [ x ]
      in
      let* parts = map_r one items in
      Ok (Reader.List (List.concat parts, p))

let instantiate (fd : Forms.form_def) (args : Reader.t list) (pos : Errors.pos)
    : (Reader.t list, Errors.t) result =
  let* env, rest = bind fd args pos in
  map_r (subst env rest) fd.Forms.template

let expand ?(open_heads = false) (datums : Reader.t list) :
    (Reader.t list, Errors.t) result =
  let forms = ref [] in
  let find n =
    List.find_opt (fun (fd : Forms.form_def) -> fd.name = n) !forms
  in
  (* Expression position: a form must expand to exactly one datum. *)
  let rec expr depth (d : Reader.t) : (Reader.t, Errors.t) result =
    if depth > cap then Reader.err_at d "form expansion exceeded the step limit"
    else
      match d with
      | Reader.Atom (a, p) -> (
          match find a with
          | Some fd when is_nullary fd -> (
              let* out = instantiate fd [] p in
              match out with
              | [ one ] -> expr (depth + 1) one
              | _ ->
                  Errors.err ~pos:p
                    ("nullary form `" ^ a
                   ^ "` expands to several datums where one is required"))
          | Some _ | None -> Ok d)
      | Reader.List (Reader.Atom (h, hp) :: args, p) -> (
          match find h with
          | Some fd -> (
              let* out = instantiate fd args hp in
              match out with
              | [ one ] -> expr (depth + 1) one
              | _ ->
                  Errors.err ~pos:hp
                    ("form `" ^ h
                   ^ "` expands to several datums where one is required"))
          | None ->
              let* items = map_r (expr depth) (Reader.Atom (h, hp) :: args) in
              Ok (Reader.List (items, p)))
      | Reader.List (items, p) ->
          let* items = map_r (expr depth) items in
          Ok (Reader.List (items, p))
  in
  (* Statement position: a form invocation may splice out several datums. *)
  let rec stmt depth (d : Reader.t) : (Reader.t list, Errors.t) result =
    if depth > cap then Reader.err_at d "form expansion exceeded the step limit"
    else
      match d with
      | Reader.Atom (a, p) -> (
          match find a with
          | Some fd when is_nullary fd ->
              let* out = instantiate fd [] p in
              concat_map_r (stmt (depth + 1)) out
          | Some _ | None -> Ok [ d ])
      | Reader.List (Reader.Atom (h, hp) :: args, _) -> (
          match find h with
          | Some fd ->
              let* out = instantiate fd args hp in
              concat_map_r (stmt (depth + 1)) out
          | None ->
              let* d' = expr depth d in
              Ok [ d' ])
      | _ ->
          let* d' = expr depth d in
          Ok [ d' ]
  in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | d :: rest -> (
        match d with
        | Reader.List (Reader.Atom ("form", _) :: _, _) ->
            let* fd = Forms.collect ~open_heads d ~earlier:!forms in
            forms := !forms @ [ fd ];
            go acc rest
        | _ ->
            let* ds = stmt 0 d in
            go (List.rev_append ds acc) rest)
  in
  go [] datums
