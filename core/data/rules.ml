(* The rules engine's data (extension §1, §2): relation declarations, rules,
   facts, derivations, and a positioned mirror of the kernel's guards.

   This is only data plus the one substitution that turns a source guard into a
   kernel guard. Reading, checking and solving live above it: what reaches the
   engine is a [program] that has already been sorted, stratified and proved
   range-restricted, because the .rules parser is its only constructor. The
   engine does no checking and cannot. *)

(* ── Terms ───────────────────────────────────────────────────────────────── *)

(* An atom position: a rule variable or a constant, carrying the position of the
   atom it was read from. The position is the whole point — extension §1 asks
   for "an error at the variable", and nothing downstream of the reader can
   supply a [line:col] that was not kept here. *)
type gterm = Var of string * Errors.pos | Const of string * Errors.pos

(* A guard's terms and a literal's terms are ONE type, not two: the free
   variables of a guard ARE the rule's variables (extension §4), bound by the
   same body and substituted by the same [lower]. *)
type term = gterm

(* ── The positioned guard mirror ─────────────────────────────────────────── *)

(* [Model.guard] and [Value.path] carry no source positions, deliberately (see
   [Schema.check_path], which has to hand the blame back to its caller for
   exactly this reason). That is right for the kernel and wrong for a rule body,
   where an unsortable or unbound variable must be blamed where it is written.
   So the .rules front end decodes guard datums into this positioned mirror and
   [lower] converts one to the kernel guard once its variables are bound.

   It is not a fork of [Model.guard]. It is the source form that lowers into it,
   the same relation [Reader.t] already has to the parsed model — one guard
   semantics, the kernel's, evaluated by the kernel's own evaluator. *)

type gpath = {
  root : gterm;
  steps : (string * Errors.pos) list;
  pos : Errors.pos;
}

type gexp =
  | Is of gpath * gterm
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

(* Substitute an environment through a source guard to get the kernel guard the
   evaluator runs. Pure and total: a variable with no binding lowers to its own
   name, which is precisely what the kernel would then compare against, since
   [Model.Is] can hold a chain, but a lowered rule guard always yields
   [Model.Lit]: a rule variable substitutes to a NAME, and the evaluator
   compares it literally. So the
   worst an unbound variable can do is fail to hold — never raise. Range
   restriction (extension §4) is what guarantees the case does not arise; this
   function does not re-check it, and must not, because it runs per candidate.

   A [Some_] binder is a KERNEL variable, not a rule variable, and is left
   alone: its name cannot collide with [env] because an ALL-CAPS binder name is
   rejected at read time, and Pol has no shadowing (kernel §7). *)
let rec lower (g : gexp) (env : env) : Model.guard =
  match g with
  | Is (p, v) -> Model.Is (lower_path env p, Model.Lit (subst env v))
  | Defined p -> Model.Defined (lower_path env p)
  | And gs -> Model.And (List.map (fun g -> lower g env) gs)
  | Or gs -> Model.Or (List.map (fun g -> lower g env) gs)
  | Not (g, _) -> Model.Not (lower g env)
  | Some_ (x, ty, g, _) -> Model.Some_ (x, ty, lower g env)

(* ── Sorts ───────────────────────────────────────────────────────────────── *)

(* What a column ranges over. Sorts, not types: the two capitalised words are
   the entire sort vocabulary and anything else in a column position names a
   schema type, which is why [Entity] carries that name instead of standing
   beside a flat list of words. The distinction has to be structural — the
   stdlib's quiver declares a lowercase [(type edge …)], so "edge" the schema
   type and [Edge] the sort are live neighbours, not a hypothetical.

   There is no [Guard] sort. The second argument of [(holds S G)] is not a term
   (see [builtin] below), so nothing ever sorts it. *)
type sort = Situation | Edge | Entity of string

(* ── Relation declarations ───────────────────────────────────────────────── *)

(* §1's [(relation NAME ARITY)] carries arity only and is sort-transparent: it
   propagates a sort, it never supplies one. [(relation NAME (T1 … Tn))]
   declares a sort per column and seeds the inference directly. The typed form
   is not a convenience: no built-in supplies an [Entity] sort, and an arrow
   name owned by two types seeds nothing (river.pol gives [at] to both
   [traveler] and [cargo]), so without it some models admit no rules at all. It
   is also where §3's "unsorted column" diagnostic already points. Arity is the
   list's length. *)
type columns = Arity of int | Sorts of sort list
type relation = { rel_name : string; cols : columns; rel_pos : Errors.pos }

(* ── Literals ────────────────────────────────────────────────────────────── *)

(* The built-in relations of extension §2, with their argument positions spelled
   out rather than carried as a name and a term list: their per-position sorts
   are fixed, and [holds] cannot honestly be written as a term list at all. The
   trailing underscores follow [Model.Some_] — those two names are the sort
   words above. *)
type builtin =
  | Situation_ of term
  | Init of term
  | Edge_ of term * term * term
  | Gap_edge of term * term
  (* [(holds S G)]: G is a guard DATUM, never a term. It is the one argument
     position in the language that holds no term — never a variable, never
     sorted, never unified, and skipped by the fixpoint. Modelling it as a term
     would make a variable written there silently joinable instead of rejected
     at the atom. Its CONTENTS are compiled separately and may bind rule
     variables; that is extension §2's business, not this type's. *)
  | Holds of term * gexp

type literal =
  | Pos_rel of string * term list * Errors.pos
  | Neg_rel of string * term list * Errors.pos
  | Built_in of builtin * Errors.pos
  (* A bare guard, with no situation: every path step must name a [fixed] arrow,
     so the situation is unobservable and the initial one serves. *)
  | Guard of gexp * Errors.pos

(* ── Rules and programs ──────────────────────────────────────────────────── *)

(* A rule's identity is its index in [program.rules]. A derivation names the
   rule that fired, and every fact stores one, so it has to be this small. *)
type rule_id = int

type rule = {
  id : rule_id;
  head : string;
  head_args : term list;
  (* Joined in WRITTEN order (extension §4) — the order is semantic, because it
     is the order range restriction simulates when it decides what is bound. *)
  body : literal list;
  rule_pos : Errors.pos;
}

(* What crosses into the engine. [sorts] is the inference fixpoint's answer for
   every column, [vars] its answer for every variable, and [strata] the stratum
   each relation is evaluated in; all three are settled before the engine sees
   them.

   [vars] is here because extension §2 makes an unbound path root enumerate ITS
   SORT'S domain, and the sort of a variable is not recoverable from [sorts]: a
   variable seeded by an arrow's dom and occurring in no relation column has no
   column to read it off. Recomputing it in the engine would be a second
   inference that could disagree with the one that issued the diagnostics, which
   is exactly what "the parser is the only constructor" exists to prevent. Keyed
   by rule, because a rule's variables are scoped to it. *)
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

(* Why a fact holds. Extension §7's correction matters here: two of the three
   kinds of leaf are not facts, so a premise cannot be a bare [fact_id].

   - [Premise_fact] is an interior node when the derivation table has an entry
     for that id, and a LEAF when it does not — an extensional fact read off the
     space, such as [edge cross-goat-LR 0 3], which is derived from nothing.
   - [Premise_guard] is a ground guard checked straight against the model, like
     [is nabu.reports-to mid]. It is not a fact, has no id, and is a leaf
     because there is nothing beneath it to print.
   - [Premise_absent] is a completed-stratum negation. An absence has no tree;
     its justification is that the relation was complete before this stratum
     began, which is exactly what stratification buys. *)
type premise =
  | Premise_fact of fact_id
  | Premise_guard of Model.guard
  | Premise_absent of string * int array

(* Only the FIRST derivation of a fact is kept: memory stays linear in the fact
   count and [--why] is a walk rather than a search. The fixpoint's
   round-boundary buffering is what keeps that walk from cycling — every premise
   predates the round its conclusion was found in. *)
type derivation = { by : rule_id; premises : premise list }

(* A term is a VARIABLE iff it is ALL-CAPS, matching extension §1's notation.

   Deliberately an independent definition and NOT a call to [Forms.is_blank],
   which tests the same spelling for a different concept (a form's blank).
   core/data is the leaf layer and cannot see core/syntax, but the move to
   resist is the reverse one: hoisting [is_blank] down here would make the
   KERNEL's form expander depend on this OPTIONAL extension, which a conforming
   processor need not implement (docs/interrogator.md §0). Two concepts that
   share a convention, kept apart on purpose. *)
let is_var s =
  s <> ""
  && String.exists (fun c -> c >= 'A' && c <= 'Z') s
  && not (String.exists (fun c -> c >= 'a' && c <= 'z') s)
