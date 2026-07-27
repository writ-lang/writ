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

(* [Set] carries the same [rhs] a guard's [Is] does: a literal, or a CHAIN read
   in the situation the move started from (§10.3). The symmetry is the point —
   a reader who has learnt [(is a.x b.y)] writes [(set a.x b.y)] and is not
   refused — and it is what lets a value be MOVED rather than only assigned by
   name, so a ladder no longer needs one transition per destination. *)
type effect = Set of Value.path * rhs | Vacate of Value.path | Gap of string
type transition = { name : string option; when_ : guard; effects : effect list }

type t = {
  schema : Schema.t;
  initial : Instance.t;
  transitions : transition list;
}
