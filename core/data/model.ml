(* The parsed model: a schema, an initial instance, and the transitions. A
   transition is one edge of the dynamics functor — a guard (its domain of
   definition) and the effects (the mapping). *)

(* The right-hand side of [is]: a literal element or entity name, or a second
   chain. Which one is meant is decided LEXICALLY, by the reader's own rule —
   an atom containing a dot is a chain (§5.2 splits it already), anything else
   is a literal. Two consequences worth stating where the type is:

   - every guard written before this existed reads exactly as it did, because a
     literal has no dot;
   - a bare [some]-binder on the right stays uncomparable, since it has no dot
     either. That is the price of deciding lexically instead of inventing a
     sigil, and it is the cheap half of the trade: the chains that motivate
     comparison at all — [c.approver] against [c.preparer] — are dotted. *)
type rhs = Lit of string | Chain of Value.path

type guard =
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
