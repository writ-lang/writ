(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The parsed model: a schema, an initial instance, and the transitions. A
   transition is one edge of the dynamics functor — a guard (its domain of
   definition) and the effects (the mapping). *)

(* Re-exported from [Guard] (which sits below [Schema]) so [Model.Is] and the
   other constructors resolve here. *)
type rhs = Guard.rhs = Lit of string | Chain of Value.path

type guard = Guard.t =
  | And of guard list
  | Or of guard list
  | Not of guard
  | Is of Value.path * rhs
  | Defined of Value.path
  | Some_ of string * string * guard

(* [Set] takes the same [rhs] as [Is]; a chain is read in the situation the
   move started from (§10.3). *)
type effect = Set of Value.path * rhs | Vacate of Value.path | Gap of string

(* [origin]: a `; writ:origin …` pragma's text (docs/bridges.md), echoed in
   reports and otherwise meaningless. *)
type transition = {
  name : string option;
  when_ : guard;
  effects : effect list;
  origin : string option;
}

type t = {
  schema : Schema.t;
  initial : Instance.t;
  transitions : transition list;
}
