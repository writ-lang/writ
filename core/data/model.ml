(* The parsed model: a schema, an initial instance, and the transitions. A
   transition is one edge of the dynamics functor — a guard (its domain of
   definition) and the effects (the mapping). *)

type guard =
  | And of guard list
  | Or of guard list
  | Not of guard
  | Is of Value.path * string
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
