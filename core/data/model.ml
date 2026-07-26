(* The parsed model: a schema, an initial instance, and the transitions. A
   transition is one edge of the dynamics functor — a guard (its domain of
   definition) and the effects (the mapping). *)

(* [guard] and [rhs] live in [Guard] now, because [Schema.equation] holds one
   too and [Schema] is below this module. Re-exported here with their
   constructors so [Model.Is], [Model.And] and the rest keep meaning what they
   did — the type moved, the vocabulary did not. *)
type rhs = Guard.rhs = Lit of string | Chain of Value.path

type guard = Guard.t =
  | And of guard list
  | Or of guard list
  | Not of guard
  | Is of Value.path * rhs
  | Defined of Value.path
  | Some_ of string * string * guard

type effect =
  | Set of Value.path * string
  | Vacate of Value.path
  | Gap of string

type transition = { name : string option; when_ : guard; effects : effect list }

type t = {
  schema : Schema.t;
  initial : Instance.t;
  transitions : transition list;
}
