(* The guard language (§10.2), in its own module because TWO things hold one:
   a transition's [when], and — since laws became guards — a [Schema.equation].
   It cannot live in [Model] any more, which is where it used to be: [Model]
   depends on [Schema], so a schema referring to [Model.guard] would close a
   cycle. It depends on nothing but [Value], which is why it can sit this low.

   There is no [Guard] keyword and never will be. This module names a shape the
   language already had; the kernel's word count is unchanged by where a type
   lives. *)

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

type t =
  | And of t list
  | Or of t list
  | Not of t
  | Is of Value.path * rhs
  | Defined of Value.path
  | Some_ of string * string * t

(* Every chain a guard mentions, [some]-binders and all. Callers that care
   about scope use [free_roots]; this one is for "which arrows does this touch",
   which is scope-blind by nature. *)
let rec paths (g : t) : Value.path list =
  match g with
  | And gs | Or gs -> List.concat_map paths gs
  | Not g -> paths g
  | Some_ (_, _, g) -> paths g
  | Defined p -> [ p ]
  | Is (p, Lit _) -> [ p ]
  | Is (p, Chain q) -> [ p; q ]

(* The arrow names a guard reads. [Observe] asks this to decide whether a move
   can break a law: an effect that writes an arrow no chain of the law walks
   cannot change the law's answer. *)
let arrows (g : t) : string list =
  List.concat_map (fun (p : Value.path) -> p.Value.steps) (paths g)

(* The roots a guard mentions that no enclosing [some] bound — its free
   variables, in first-mention order and deduplicated.

   This is what makes a law's implicit quantification statable. §8.6 writes an
   equation's chains from the TYPE ("case.investigator… means for every case"),
   so in a law the free roots ARE the subject, and the single-root rule is the
   demand that there be exactly one of them. A binder is excluded because
   [some] already says what it ranges over. *)
let free_roots (g : t) : string list =
  let seen = ref [] in
  let note bound (p : Value.path) =
    let r = p.Value.root in
    if (not (List.mem r bound)) && not (List.mem r !seen) then
      seen := r :: !seen
  in
  let rec go bound g =
    match g with
    | And gs | Or gs -> List.iter (go bound) gs
    | Not g -> go bound g
    | Some_ (x, _, g) -> go (x :: bound) g
    | Defined p -> note bound p
    | Is (p, Lit _) -> note bound p
    | Is (p, Chain q) ->
        note bound p;
        note bound q
  in
  go [] g;
  List.rev !seen

(* Structural equality. Explicit, not polymorphic [=], for the reason
   [Value.compare_cell] gives: the ordering must not depend on constructor
   runtime tags. [Compare] asks this to decide whether a law survived a version
   change, so a wrong answer here is a wrong "preserved". *)
let rec equal (a : t) (b : t) : bool =
  match (a, b) with
  | And xs, And ys | Or xs, Or ys ->
      List.length xs = List.length ys && List.for_all2 equal xs ys
  | Not x, Not y -> equal x y
  | Defined p, Defined q -> Value.compare_path p q = 0
  | Is (p, r), Is (q, s) -> Value.compare_path p q = 0 && equal_rhs r s
  | Some_ (x, tx, gx), Some_ (y, ty, gy) ->
      String.equal x y && String.equal tx ty && equal gx gy
  | _ -> false

and equal_rhs (a : rhs) (b : rhs) : bool =
  match (a, b) with
  | Lit x, Lit y -> String.equal x y
  | Chain p, Chain q -> Value.compare_path p q = 0
  | _ -> false
