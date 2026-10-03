(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The rules engine's data (extension §1, §2): relations, rules, facts,
   derivations, and a positioned mirror of the kernel's guards. The .rules
   parser is the only constructor of a [program], so the engine receives it
   already sorted, stratified and range-restricted, and does no checking. *)

(* ── Terms ───────────────────────────────────────────────────────────────── *)

(* A rule variable or constant, with the position of its atom so errors can
   point at the variable (extension §1). *)
type gterm = Var of string * Errors.pos | Const of string * Errors.pos

(* Guard terms and literal terms are one type: a guard's free variables are the
   rule's variables (extension §1). *)
type term = gterm

(* ── The positioned guard mirror ─────────────────────────────────────────── *)

(* A positioned source form of [Model.guard], so rule errors can point at a
   variable; [lower] yields the kernel guard once variables are bound. *)

type gpath = {
  root : gterm;
  steps : (string * Errors.pos) list;
  pos : Errors.pos;
}

type gexp =
  | Is of gpath * gterm
  (* [(is P Q)] with a path on both sides: the kernel's chain-against-chain
     test (§10.2). It only tests, never binds: both roots must already be
     bound, like a guard under [not]. *)
  | Is_path of gpath * gpath
  | Defined of gpath
  | And of gexp list
  | Or of gexp list
  | Not of gexp * Errors.pos
  | Some_ of string * string * gexp * Errors.pos

(* What the fixpoint has bound each rule variable to. *)
type env = (string * string) list

let subst (env : env) (t : gterm) : string =
  match t with
  | Const (c, _) -> c
  | Var (x, _) -> ( match List.assoc_opt x env with Some v -> v | None -> x)

let lower_path (env : env) (p : gpath) : Value.path =
  { Value.root = subst env p.root; steps = List.map fst p.steps }

(* Substitute [env] through a source guard. Total: an unbound variable (ruled
   out by range restriction, §4) lowers to its name and merely fails to hold.
   [Some_] binders are lower case, so never in [env]. *)
let rec lower (g : gexp) (env : env) : Model.guard =
  match g with
  | Is (p, v) -> Model.Is (lower_path env p, Model.Lit (subst env v))
  | Is_path (p, q) -> Model.Is (lower_path env p, Model.Chain (lower_path env q))
  | Defined p -> Model.Defined (lower_path env p)
  | And gs -> Model.And (List.map (fun g -> lower g env) gs)
  | Or gs -> Model.Or (List.map (fun g -> lower g env) gs)
  | Not (g, _) -> Model.Not (lower g env)
  | Some_ (x, ty, g, _) -> Model.Some_ (x, ty, lower g env)

(* ── Sorts ───────────────────────────────────────────────────────────────── *)

(* What a column ranges over: a situation, an edge, or entities of a schema
   type. [Entity] carries the type name because a schema may have a lowercase
   type [edge] next to the sort [Edge] (the stdlib's quiver does). *)
type sort = Situation | Edge | Entity of string

(* ── Relation declarations ───────────────────────────────────────────────── *)

(* [(relation NAME ARITY)] only propagates sorts; [(relation NAME (T…))]
   declares them, which some models need to sort at all. *)
type columns = Arity of int | Sorts of sort list
type relation = { rel_name : string; cols : columns; rel_pos : Errors.pos }

(* ── Literals ────────────────────────────────────────────────────────────── *)

(* The built-in relations of extension §2, with fixed per-position sorts. The
   trailing underscores avoid the sort constructors above. *)
type builtin =
  | Situation_ of term
  | Init of term
  | Edge_ of term * term * term
  | Gap_edge of term * term
  (* Phases (mutual-reachability classes, named by their least situation) and
     the step between distinct phases, which rules cannot express. *)
  | Phase of term * term
  | Phase_step of term * term
  (* [(holds S G)]: G is a guard datum, never a term — never sorted, unified or
     joined, so a variable written there is rejected rather than silently
     joined. Its contents may bind rule variables (extension §2). *)
  | Holds of term * gexp

type literal =
  | Pos_rel of string * term list * Errors.pos
  | Neg_rel of string * term list * Errors.pos
  | Built_in of builtin * Errors.pos
  (* A bare guard, with no situation: every path step must name a [fixed] arrow,
     so the situation is unobservable and the initial one serves. *)
  | Guard of gexp * Errors.pos

(* ── Rules and programs ──────────────────────────────────────────────────── *)

(* A rule's index in [program.rules]; every fact's derivation stores one. *)
type rule_id = int

type rule = {
  id : rule_id;
  head : string;
  head_args : term list;
  (* Joined in written order (extension §1); range restriction depends on it. *)
  body : literal list;
  rule_pos : Errors.pos;
}

(* What the engine receives: sorts of columns and of (rule-scoped) variables,
   and strata. [vars] is needed because an unbound path root enumerates its
   sort (§2), and it may occur in no column. *)
type program = {
  relations : relation list;
  rules : rule list;
  sorts : ((string * int) * sort) list;
  vars : ((rule_id * string) * sort) list;
  strata : (string * int) list;
}

(* ── Facts and derivations ───────────────────────────────────────────────── *)

(* Atoms are interned to ints — a situation to its space index — so a tuple is
   an int array and membership is a hash of it. *)
type fact = { rel : string; args : int array }
type fact_id = int

(* Why a fact holds (extension §4, `--why`). A [Premise_fact] is interior if derived,
   else a leaf read off the space; guards and completed-stratum absences are
   leaves. *)
type premise =
  | Premise_fact of fact_id
  | Premise_guard of Model.guard
  | Premise_absent of string * int array

(* Only the first derivation of a fact is kept, so memory is linear and [--why]
   is a walk. Round-boundary buffering in the fixpoint keeps the walk acyclic:
   every premise predates its conclusion's round. *)
type derivation = { by : rule_id; premises : premise list }

(* A term is a variable iff ALL-CAPS (extension §1). Separate from
   [Forms.is_blank] so the kernel never depends on this optional extension. *)
let is_var s =
  s <> ""
  && String.exists (fun c -> c >= 'A' && c <= 'Z') s
  && not (String.exists (fun c -> c >= 'a' && c <= 'z') s)
