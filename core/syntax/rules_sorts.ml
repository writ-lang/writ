open Pol_data

(* Extension §3 — sorts, by a program-wide least fixpoint over
   [(relation, column) → sort], seeded by built-in positions, by a typed
   relation declaration, by an unambiguous arrow name's [dom], and by the [cod]
   of a path's last arrow for an [(is PATH V)] value.

   Why a FIXPOINT and not left-to-right first use, which is what §1's prose
   sounds like: in §1's own transitive closure the recursive rule's [Y] occurs
   only in the head and in a sort-transparent relation literal, so nothing in
   that rule can type it. It is typed by [subordinate]'s second column, which is
   learned from the OTHER rule. A per-rule pass cannot see that; a program-wide
   relaxation can, and it is the only reading under which the specification's
   own example is legal.

   Why chain resolution lives INSIDE the loop: the dom of a path's first arrow
   seeds its root, but only when the arrow name is owned by exactly one type —
   [river.pol] gives [at] to both [traveler] and [cargo]. An ambiguous name does
   not seed, and the variable waits for another occurrence, possibly in another
   rule and possibly only after a column it feeds has itself been learned.
   Resolution and inference are therefore one fixpoint, not two phases — which
   is also why [Grammar.check_guard] is unusable here: it wants the
   variable→type environment up front, and that is the answer being computed.
   Path type-checking runs afterwards, in [Rules_paths], and so does the check
   that a CONSTANT inhabits its column: constants never seed, so a relation of
   pure constants carries no model content and is unwritable — §3's price. *)

let ( let* ) = Result.bind

(* Eta-expanded: a bare alias would be weakly polymorphic. *)
let iter_r f xs = Rules_terms.iter_r f xs
let col_why = Rules_terms.col_why

(* ── The tables the fixpoint relaxes ─────────────────────────────────────── *)

(* Each entry keeps the position and the reason that forced it: §3 asks a
   conflict to name BOTH occurrences, and a sort with no provenance cannot. *)
type seed = { srt : Rules.sort; at : Errors.pos; why : string }

type st = {
  m : Model.t;
  tcols : (string * int, seed) Hashtbl.t;
  tvars : (Rules.rule_id * string, seed) Hashtbl.t;
  mutable changed : bool;
}

(* What the fixpoint settled. Variables are keyed by rule, because a rule's
   variables are scoped to it: the [X] of one rule is not the [X] of the next. *)
type t = {
  columns : ((string * int) * Rules.sort) list;
  variables : ((Rules.rule_id * string) * Rules.sort) list;
}

let var_sort (s : t) (rid : Rules.rule_id) (x : string) : Rules.sort option =
  List.assoc_opt (rid, x) s.variables

let col_sort (s : t) (rel : string) (i : int) : Rules.sort option =
  List.assoc_opt (rel, i) s.columns

(* A conflict is blamed at the SECOND occurrence and names the first's position:
   the second is what the author is free to change, the first is the evidence
   for why they must. *)
let put st tbl key what (s : seed) : (unit, Errors.t) result =
  match Hashtbl.find_opt tbl key with
  | Some old when old.srt = s.srt -> Ok ()
  | Some old ->
      Errors.err ~pos:s.at
        (what ^ " is "
        ^ Rules_terms.sort_name s.srt
        ^ " here, forced by " ^ s.why ^ ", but at " ^ Rules_terms.pos_str old.at
        ^ " it is "
        ^ Rules_terms.sort_name old.srt
        ^ ", forced by " ^ old.why)
  | None ->
      Hashtbl.replace tbl key s;
      st.changed <- true;
      Ok ()

let seed_var st rid (t : Rules.term) (srt : Rules.sort) (why : string) =
  match t with
  | Rules.Const _ -> Ok ()
  | Rules.Var (x, at) ->
      put st st.tvars (rid, x) ("`" ^ x ^ "`") { srt; at; why }

(* A column and the term written in it teach each other whichever of them is
   known. That two-way flow, across rules, is what carries [subordinate]'s
   second column from the base rule to the recursive one. *)
let seed_arg st rid rel i (t : Rules.term) =
  let* () =
    match Hashtbl.find_opt st.tcols (rel, i) with
    | Some c -> seed_var st rid t c.srt (col_why rel i)
    | None -> Ok ()
  in
  match t with
  | Rules.Const _ -> Ok ()
  | Rules.Var (x, at) -> (
      match Hashtbl.find_opt st.tvars (rid, x) with
      | None -> Ok ()
      | Some v ->
          put st st.tcols (rel, i) (col_why rel i)
            { srt = v.srt; at; why = "`" ^ x ^ "`" })

let seed_args st rid rel ts =
  let rec go i = function
    | [] -> Ok ()
    | t :: rest ->
        let* () = seed_arg st rid rel i t in
        go (i + 1) rest
  in
  go 0 ts

(* ── Chain resolution ────────────────────────────────────────────────────── *)

(* Arrow names are dom-scoped (kernel §7), so a name may be owned by several
   types. Exactly one owner is a seed; more than one is silence. *)
let arrow_doms (s : Schema.t) (name : string) : string list =
  List.sort_uniq String.compare
    (List.filter_map
       (fun (a : Schema.arrow) ->
         if a.Schema.name = name then Some a.Schema.dom else None)
       s.Schema.arrows)

let rec walk (s : Schema.t) (cur : string) = function
  | [] -> Some cur
  | (step, _) :: rest -> (
      match Schema.arrow_in s ~dom:cur step with
      | None -> None
      | Some a -> walk s a.Schema.cod rest)

(* The type a path is rooted at, if it is known YET. [None] is not a failure —
   it tells the fixpoint to come back next round. *)
let root_type st rid (benv : (string * string) list) (p : Rules.gpath) =
  match p.Rules.root with
  | Rules.Const (c, _) -> (
      match List.assoc_opt c benv with
      | Some ty -> Some ty
      | None -> Instance.type_of_entity st.m.Model.initial c)
  | Rules.Var (x, _) -> (
      match Hashtbl.find_opt st.tvars (rid, x) with
      | Some { srt = Rules.Entity ty; _ } -> Some ty
      | Some _ | None -> None)

let seed_root st rid (p : Rules.gpath) =
  match (p.Rules.root, p.Rules.steps) with
  | Rules.Var (x, _), (a, _) :: _ when not (Hashtbl.mem st.tvars (rid, x)) -> (
      match arrow_doms st.m.Model.schema a with
      | [ dom ] ->
          seed_var st rid p.Rules.root (Rules.Entity dom)
            ("the root of the path `" ^ Rules_terms.path_str p ^ "`")
      (* Ambiguous, or no such arrow at all: seed nothing, and let another
         occurrence sort it. A missing arrow is [Rules_paths]' error to make. *)
      | _ -> Ok ())
  | _ -> Ok ()

let rec seed_guard st rid benv (g : Rules.gexp) =
  match g with
  | Rules.Is (p, v) -> (
      let* () = seed_root st rid p in
      match root_type st rid benv p with
      | None -> Ok ()
      | Some rt -> (
          match walk st.m.Model.schema rt p.Rules.steps with
          | None -> Ok ()
          | Some cod ->
              seed_var st rid v (Rules.Entity cod)
                ("the codomain of `" ^ Rules_terms.path_str p ^ "`")))
  | Rules.Defined p -> seed_root st rid p
  | Rules.And gs | Rules.Or gs -> iter_r (seed_guard st rid benv) gs
  | Rules.Not (g, _) -> seed_guard st rid benv g
  | Rules.Some_ (x, ty, g, _) -> seed_guard st rid ((x, ty) :: benv) g

(* ── Seeds ───────────────────────────────────────────────────────────────── *)

let bwhy k i = "column " ^ string_of_int (i + 1) ^ " of built-in `" ^ k ^ "`"

let seed_builtin st rid (b : Rules.builtin) =
  match b with
  | Rules.Situation_ s -> seed_var st rid s Rules.Situation (bwhy "situation" 0)
  | Rules.Init s -> seed_var st rid s Rules.Situation (bwhy "init" 0)
  | Rules.Edge_ (e, s1, s2) ->
      let* () = seed_var st rid e Rules.Edge (bwhy "edge" 0) in
      let* () = seed_var st rid s1 Rules.Situation (bwhy "edge" 1) in
      seed_var st rid s2 Rules.Situation (bwhy "edge" 2)
  | Rules.Gap_edge (e, s) ->
      let* () = seed_var st rid e Rules.Edge (bwhy "gap-edge" 0) in
      seed_var st rid s Rules.Situation (bwhy "gap-edge" 1)
  (* The G of [(holds S G)] is not a term and is never sorted; its CONTENTS are
     seeded exactly as a bare guard's are. *)
  | Rules.Holds (s, g) ->
      let* () = seed_var st rid s Rules.Situation (bwhy "holds" 0) in
      seed_guard st rid [] g

let seed_literal st rid (l : Rules.literal) =
  match l with
  | Rules.Pos_rel (r, ts, _) | Rules.Neg_rel (r, ts, _) -> seed_args st rid r ts
  | Rules.Built_in (b, _) -> seed_builtin st rid b
  | Rules.Guard (g, _) -> seed_guard st rid [] g

let seed_rule st (r : Rules.rule) =
  let* () = seed_args st r.Rules.id r.Rules.head r.Rules.head_args in
  iter_r (seed_literal st r.Rules.id) r.Rules.body

let seed_decl st (r : Rules.relation) =
  match r.Rules.cols with
  | Rules.Arity _ -> Ok ()
  | Rules.Sorts ss ->
      let name = r.Rules.rel_name in
      let why = "the declaration of `" ^ name ^ "`" in
      let rec go i = function
        | [] -> Ok ()
        | s :: rest ->
            let* () =
              match s with
              | Rules.Entity ty when Schema.type_of st.m.Model.schema ty = None
                ->
                  Errors.err ~pos:r.Rules.rel_pos
                    (col_why name i ^ " names `" ^ ty
                   ^ "`, which the schema does not declare")
              | Rules.Entity _ | Rules.Situation | Rules.Edge ->
                  put st st.tcols (name, i) (col_why name i)
                    { srt = s; at = r.Rules.rel_pos; why }
            in
            go (i + 1) rest
      in
      go 0 ss

(* ── Verdicts, once nothing more can be learned ──────────────────────────── *)

let unsorted_var st (r : Rules.rule) =
  let bad =
    List.find_map
      (function
        | Rules.Var (x, p) when not (Hashtbl.mem st.tvars (r.Rules.id, x)) ->
            Some (x, p)
        | Rules.Var _ | Rules.Const _ -> None)
      (Rules_terms.terms_of_rule r)
  in
  match bad with
  | None -> Ok ()
  | Some (x, p) ->
      Errors.err ~pos:p
        ("the type of variable `" ^ x
       ^ "` cannot be inferred; put it in a column that has a sort, or give \
          one a sort with (relation NAME (T1 … Tn))")

let unsorted_cols st (r : Rules.relation) =
  let name = r.Rules.rel_name in
  let unknown i =
    if Hashtbl.mem st.tcols (name, i) then None
    else Some (string_of_int (i + 1))
  in
  match List.filter_map unknown (List.init (Rules_terms.arity_of r) Fun.id) with
  | [] -> Ok ()
  | ms ->
      Errors.err ~pos:r.Rules.rel_pos
        ("the sort of column"
        ^ (if List.length ms > 1 then "s " else " ")
        ^ String.concat ", " ms ^ " of `" ^ name
        ^ "` cannot be inferred; declare it as (relation " ^ name
        ^ " (T1 … Tn))")

(* ── The fixpoint ────────────────────────────────────────────────────────── *)

let infer (m : Model.t) (p : Rules_parser.t) : (t, Errors.t) result =
  let st =
    { m; tcols = Hashtbl.create 32; tvars = Hashtbl.create 64; changed = true }
  in
  let* () = iter_r (seed_decl st) p.Rules_parser.relations in
  (* A round that changes anything fills at least one table entry, and the two
     tables have finitely many keys, so this terminates. The bound is written
     down rather than trusted: one round per key that could ever be filled. *)
  let bound =
    List.fold_left
      (fun n r -> n + Rules_terms.arity_of r)
      0 p.Rules_parser.relations
    + List.fold_left
        (fun n r -> n + List.length (Rules_terms.terms_of_rule r))
        0 p.Rules_parser.rules
    + 1
  in
  let rec loop k =
    if (not st.changed) || k > bound then Ok ()
    else begin
      st.changed <- false;
      let* () = iter_r (seed_rule st) p.Rules_parser.rules in
      loop (k + 1)
    end
  in
  let* () = loop 0 in
  (* The variable comes first: §1 asks for an error AT the variable, and an
     unsortable variable always leaves the column it feeds unsorted too, so
     reporting the column would bury the answer one indirection away. *)
  let* () = iter_r (unsorted_var st) p.Rules_parser.rules in
  let* () = iter_r (unsorted_cols st) p.Rules_parser.relations in
  let entries tbl = Hashtbl.fold (fun k v acc -> (k, v.srt) :: acc) tbl [] in
  Ok
    {
      columns = List.sort compare (entries st.tcols);
      variables = List.sort compare (entries st.tvars);
    }
