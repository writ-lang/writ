(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* [.rules] datums -> relation declarations and rules (extension §1, §2).
   [(relation NAME ARITY)] or the typed [(relation NAME (T1 … Tn))];
   [(rule HEAD LITERAL…)] where a literal is a relation, a negated relation, one
   of §2's five built-ins, or a guard. The positioned atoms a literal is built
   from — terms, paths, guards — are [Rules_guard]'s, which is also where the
   reason for not going through [Grammar] is written down.

   This module DECODES and nothing else. Sort inference, stratification and
   range restriction are read-time rejections too, but they are program-wide
   fixpoints rather than shape checks, and they live in [Rules_check]. What is
   rejected here is what a single datum can be judged on: an arity, a shape, a
   term where a datum belongs. *)

let ( let* ) = Result.bind
let map_r = Rules_guard.map_r
let term = Rules_guard.term

(* Extension §2's table, each built-in beside the shape it is written in. Their
   arities and per-position sorts are fixed, so a literal headed by one of these
   is never a user relation, and a wrong arity can name the right one. *)
let builtins =
  [
    ("situation", "(situation S)");
    ("init", "(init S)");
    ("edge", "(edge E S1 S2)");
    ("gap-edge", "(gap-edge E S)");
    ("phase", "(phase S P)");
    ("phase-step", "(phase-step P Q)");
    ("holds", "(holds S G)");
  ]

let is_builtin k = List.mem_assoc k builtins

(* The kernel's guard vocabulary (§10.2). A body literal headed by one of these
   is a guard, not a relation — which is also how [(not …)] is read in a body:
   [(not (is …))] is a negated GUARD, [(not (R …))] a negated relation. *)
let guard_words = [ "and"; "or"; "not"; "is"; "defined"; "some" ]

(* ── Built-in literals ───────────────────────────────────────────────────── *)

let builtin (k : string) (kp : Errors.pos) (args : Reader.t list) :
    (Rules.builtin, Errors.t) result =
  match (k, args) with
  | "situation", [ s ] ->
      let* s = term s in
      Ok (Rules.Situation_ s)
  | "init", [ s ] ->
      let* s = term s in
      Ok (Rules.Init s)
  | "edge", [ e; s1; s2 ] ->
      let* e = term e in
      let* s1 = term s1 in
      let* s2 = term s2 in
      Ok (Rules.Edge_ (e, s1, s2))
  | "gap-edge", [ e; s ] ->
      let* e = term e in
      let* s = term s in
      Ok (Rules.Gap_edge (e, s))
  | "phase", [ s; p ] ->
      let* s = term s in
      let* p = term p in
      Ok (Rules.Phase (s, p))
  | "phase-step", [ p; q ] ->
      let* p = term p in
      let* q = term q in
      Ok (Rules.Phase_step (p, q))
  | "holds", [ s; g ] ->
      let* s = term s in
      let* g = Rules_guard.holds_guard g in
      Ok (Rules.Holds (s, g))
  | _ ->
      Errors.err ~pos:kp
        ("the built-in relation `" ^ k ^ "` is written " ^ List.assoc k builtins)

(* ── Body literals ───────────────────────────────────────────────────────── *)

let literal (d : Reader.t) : (Rules.literal, Errors.t) result =
  match d with
  | Reader.Atom (_, p) ->
      Errors.err ~pos:p "expected a body literal, found a bare atom"
  | Reader.List (Reader.Atom (h, hp) :: args, dp) -> (
      match (h, args) with
      | "not", [ Reader.List (Reader.Atom (r, rp) :: rargs, _) ]
        when not (List.mem r guard_words) ->
          if is_builtin r then
            Errors.err ~pos:rp
              ("the built-in relation `" ^ r
             ^ "` cannot be negated; negate a declared relation instead")
          else if rargs = [] then
            Errors.err ~pos:rp "a relation literal needs at least one argument"
          else
            let* ts = map_r term rargs in
            Ok (Rules.Neg_rel (r, ts, dp))
      | _ when List.mem h guard_words ->
          let* g = Rules_guard.guard d in
          Ok (Rules.Guard (g, dp))
      | _ when is_builtin h ->
          let* b = builtin h hp args in
          Ok (Rules.Built_in (b, dp))
      | _, [] ->
          Errors.err ~pos:hp "a relation literal needs at least one argument"
      | _ ->
          let* ts = map_r term args in
          Ok (Rules.Pos_rel (h, ts, dp)))
  | Reader.List (_, p) ->
      Errors.err ~pos:p "a body literal starts with a relation or guard name"

(* ── Declarations ────────────────────────────────────────────────────────── *)

let no_nullary =
  "a relation needs at least one column; a yes/no question is the emptiness of \
   a one-column answer set, which also gives you a witness"

(* A column names a sort. The two sort words are capitalised and everything else
   names a schema type, which is what keeps the stdlib quiver's lowercase
   [(type edge …)] readable beside the [Edge] sort. The one spelling that cannot
   be disentangled is a schema type actually NAMED [Situation] or [Edge]: the
   sort word wins, so the type would be silently unreachable. That is rejected
   here, at the declaration, which is the only place in a .rules file where the
   collision can be seen. *)
let column (schema : Schema.t) (d : Reader.t) : (Rules.sort, Errors.t) result =
  match d with
  | Reader.List (_, p) ->
      Errors.err ~pos:p "expected a sort word or a schema type name"
  | Reader.Atom ((("Situation" | "Edge") as w), p) -> (
      match Schema.type_of schema w with
      | Some _ ->
          Errors.err ~pos:p
            ("`" ^ w
           ^ "` is a sort word here, but the schema declares a type of that \
              name; rename the type")
      | None -> Ok (if w = "Situation" then Rules.Situation else Rules.Edge))
  | Reader.Atom (t, p) ->
      if t = "" then Errors.err ~pos:p "empty type name"
      else Ok (Rules.Entity t)

let decode_relation (schema : Schema.t) (d : Reader.t) :
    (Rules.relation, Errors.t) result =
  match d with
  | Reader.List
      ([ Reader.Atom ("relation", _); Reader.Atom (name, np); cols ], dp) ->
      if is_builtin name then
        Errors.err ~pos:np
          ("`" ^ name
         ^ "` is a built-in relation (extension §2) and cannot be redeclared")
      else
        let* cols =
          match cols with
          | Reader.Atom (a, ap) -> (
              match int_of_string_opt a with
              | Some n when n > 0 -> Ok (Rules.Arity n)
              | Some _ -> Errors.err ~pos:ap no_nullary
              | None ->
                  Errors.err ~pos:ap
                    ("expected an arity or a column list, found `" ^ a ^ "`"))
          | Reader.List ([], p) -> Errors.err ~pos:p no_nullary
          | Reader.List (cs, _) ->
              let* ss = map_r (column schema) cs in
              Ok (Rules.Sorts ss)
        in
        Ok { Rules.rel_name = name; cols; rel_pos = dp }
  | _ ->
      Reader.err_at d
        "malformed relation declaration: (relation NAME ARITY) or (relation \
         NAME (T1 … Tn))"

let decode_rule (id : Rules.rule_id) (d : Reader.t) :
    (Rules.rule, Errors.t) result =
  match d with
  | Reader.List (Reader.Atom ("rule", _) :: head :: body, dp) when body <> []
    -> (
      match head with
      | Reader.List (Reader.Atom (h, hp) :: hargs, _) when hargs <> [] ->
          (* Extension §5: a rule never adds a situation, an edge or a cell, so
             it may not define what the model itself supplies. *)
          if is_builtin h || List.mem h guard_words then
            Errors.err ~pos:hp
              ("`" ^ h ^ "` is built in and a rule cannot define it")
          else
            let* head_args = map_r term hargs in
            let* body = map_r literal body in
            Ok { Rules.id; head = h; head_args; body; rule_pos = dp }
      | _ ->
          Reader.err_at head
            "a rule head is a relation applied to terms: (rule (R T…) LITERAL…)"
      )
  | _ -> Reader.err_at d "malformed rule: (rule (R T…) LITERAL…)"

(* What a .rules file says, before anything has been inferred about it. The
   engine's [Rules.program] is deliberately NOT this type: it additionally
   carries the sorts and strata that [Rules_check] computes, so a program can
   only exist once it has been checked. *)
type t = { relations : Rules.relation list; rules : Rules.rule list }

let parse (schema : Schema.t) (datums : Reader.t list) : (t, Errors.t) result =
  let rec go rels rules next = function
    | [] -> Ok { relations = List.rev rels; rules = List.rev rules }
    | d :: rest -> (
        match d with
        | Reader.List (Reader.Atom ("relation", _) :: _, _) ->
            let* r = decode_relation schema d in
            go (r :: rels) rules next rest
        | Reader.List (Reader.Atom ("rule", _) :: _, _) ->
            let* r = decode_rule next d in
            go rels (r :: rules) (next + 1) rest
        | Reader.List (Reader.Atom ("schema", _) :: _, _)
        | Reader.List (Reader.Atom ("instance", _) :: _, _) ->
            (* declarations a loaded library brought in — not questions *)
            go rels rules next rest
        | other -> Reader.err_at other "unknown rules declaration")
  in
  go [] [] 0 datums
