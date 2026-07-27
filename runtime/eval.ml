open Pol_data

(* Kleene evaluation over a state (kernel §3, §4). A path evaluates to a
   [Value.cell option]: [None] means undefined (a vacant cell or a step off a
   vacant/undefined prefix — partiality propagates). A guard holds by the usual
   connectives, with [some] scanning a roster. Applying effects yields the next
   state or a gap.

   No IO here (fold F7): strings are never printed from the engine. *)

type env = (string * string) list

(* The entities of a type: an enumerated type's declared values, or an open
   type's roster (flattened across any rosters naming it). *)
let entities_of_type (ctx : State.ctx) (ty : string) : string list =
  match Schema.type_of ctx.schema ty with
  | Some { flavor = Enumerated vs; _ } -> vs
  | Some { flavor = Open; _ } ->
      List.concat_map
        (fun (r : Instance.roster) -> if r.ty = ty then r.entities else [])
        ctx.rosters
  | None -> []

(* Walk a literal path over a state. The root is either a bound variable (looked
   up in [env]) or an entity used directly; each step reads the cell
   [{arrow; src}] and advances to its fill. A vacant cell (or a missing arrow,
   read as vacant) makes the whole path undefined. A path with no steps is the
   root entity itself. *)
let eval_path (ctx : State.ctx) (st : State.t) (env : env) (p : Value.path) :
    Value.cell option =
  let root =
    match List.assoc_opt p.root env with Some e -> e | None -> p.root
  in
  let rec walk cur = function
    | [] -> Some (Value.Filled cur)
    | step :: rest -> (
        match State.get ctx st { Instance.arrow = step; src = cur } with
        | Value.Vacant -> None
        | Value.Filled v -> walk v rest)
  in
  walk root p.steps

let rec guard_holds (ctx : State.ctx) (st : State.t) (env : env)
    (g : Model.guard) : bool =
  match g with
  | Model.And gs -> List.for_all (guard_holds ctx st env) gs
  | Model.Or gs -> List.exists (guard_holds ctx st env) gs
  | Model.Not g -> not (guard_holds ctx st env g)
  (* Strict on BOTH sides, which is what §10.2 already said of one: "the chain
     has an answer and it equals V". A chain with no answer on the right makes
     the comparison false, never vacuously true — that is `=`'s Kleene reading,
     and keeping the two apart is the point of having both. *)
  | Model.Is (p, r) -> (
      match eval_path ctx st env p with
      | Some (Value.Filled x) -> (
          match r with
          | Model.Lit v -> String.equal x v
          | Model.Chain q -> (
              match eval_path ctx st env q with
              | Some (Value.Filled y) -> String.equal x y
              | _ -> false))
      | _ -> false)
  | Model.Defined p -> (
      match eval_path ctx st env p with
      | Some (Value.Filled _) -> true
      | _ -> false)
  | Model.Some_ (x, ty, g) ->
      List.exists
        (fun e -> guard_holds ctx st ((x, e) :: env) g)
        (entities_of_type ctx ty)

(* WHICH cell a path names: walk the one-shorter prefix to an entity, then take
   the last step as the arrow. Returns the slot in the state vector.

   This is separate from writing it, and that separation is the whole of §10.1's
   simultaneity. A target is a path too — [(set cur.q.at S)] must walk [cur.q]
   to find the queen — so if the walk happened at write time it would see what
   an earlier effect of the same move had already written, and the order of
   effects would be observable through the LEFT side even with every right side
   read from the starting situation. That is not a hypothetical: the queens
   cursor writes [cur.q.at] and [cur.q] in one move, and swapping the two gave
   9 situations instead of 2057 until this was split out.

   [None] for a rootless path, a step off an undefined prefix, or a target
   outside the layout (a fixed or unknown cell) — the effect is then a no-op, as
   §10.3 says: guards are expected to have ensured applicability. *)
let target_index (ctx : State.ctx) (st : State.t) (p : Value.path) : int option
    =
  match List.rev p.steps with
  | [] -> None
  | last :: rev_prefix -> (
      let prefix = { p with steps = List.rev rev_prefix } in
      match eval_path ctx st [] prefix with
      | Some (Value.Filled src) ->
          State.index_of ctx { Instance.arrow = last; src }
      | _ -> None)

(* Applying a move, in two phases, which is what §10.3's chain-valued [set]
   forced and what §10.1 now states outright.

   PHASE 1 resolves every effect against the situation the move STARTED from —
   BOTH sides. The right-hand side is read there, and so is the target: a
   target is a path too, and [target_index] must walk it to find the cell. Miss
   either half and the order of effects becomes observable through the half
   that was missed. That makes a [do] block a simultaneous assignment: [(do
   (set a.x b.y) (set b.y a.x))] is a swap, and writing the two effects of the
   queens cursor in either order gives the same 2057 situations. §10.1 says no
   situation exists between two effects of one move, and nothing in the
   language can name that order — so nothing may depend on it.

   Threading the state through the effects one at a time, as this used to, is
   precisely the sequential reading that breaks all of the above.

   PHASE 1 also decides ENABLEDNESS. A chain with no answer — [(set q.at
   q.at.next)] at the top of a ladder — makes the move [`Blocked]: not a
   no-op, and not a vacated target. Vacating would write [vacant] through
   [set], which §8.3 forbids outright. A no-op would be worse than it looks: it
   is still an EDGE, from a situation to itself, and [Space.dead_ends] marks a
   state as having an out-edge on [e.src] alone — so a self-loop would quietly
   stop a stuck situation being reported as stuck, and dead ends are one of the
   answers `pol check` exists to give.

   [`Blocked] outranks [`Gap]: a move whose effects cannot be carried out is
   not available at all, so it contributes no edge of any kind. *)
let apply (ctx : State.ctx) (st : State.t) (effects : Model.effect list) :
    [ `Next of State.t | `Gap of string | `Blocked ] =
  let read = function
    | Model.Lit v -> Some v
    | Model.Chain p -> (
        match eval_path ctx st [] p with
        | Some (Value.Filled v) -> Some v
        | Some Value.Vacant | None -> None)
  in
  (* Phase 1: both sides of every effect, against the starting situation. A
     target that names no cell is a no-op (§10.3), so it drops out here. *)
  let rec resolve acc = function
    | [] -> Ok (List.rev acc)
    | Model.Set (p, r) :: rest -> (
        match read r with
        | None -> Error `Blocked
        | Some v -> (
            match target_index ctx st p with
            | Some i -> resolve (`Write (i, Value.Filled v) :: acc) rest
            | None -> resolve acc rest))
    | Model.Vacate p :: rest -> (
        match target_index ctx st p with
        | Some i -> resolve (`Write (i, Value.Vacant) :: acc) rest
        | None -> resolve acc rest)
    | Model.Gap msg :: rest -> resolve (`Gap msg :: acc) rest
  in
  match resolve [] effects with
  | Error `Blocked -> `Blocked
  | Ok resolved -> (
      match List.find_opt (function `Gap _ -> true | _ -> false) resolved with
      | Some (`Gap msg) -> `Gap msg
      | _ ->
          (* Phase 2: the writes, into slots already chosen. *)
          `Next
            (List.fold_left
               (fun st -> function
                 | `Write (i, cell) -> State.set st i cell | `Gap _ -> st)
               st resolved))

(* A law is a guard, and it ranges over its single free root — the subject
   §8.6 writes its chains from ("case.investigator… means for every case"). The
   root name is bound to each entity of that type in turn and the guard must
   hold at every one.

   Kleene-ness is no longer built in here. It used to be: an equation was two
   chains and an undefined side made it vacuously true. Now `=` is a stdlib form
   that spells that reading out of strict primitives, so a law means exactly
   what its guard says and an author who wants strictness can have it. *)
let eq_holds (ctx : State.ctx) (st : State.t) (eq : Schema.equation) : bool =
  match Guard.free_roots eq.Schema.body with
  | [ root ] ->
      List.for_all
        (fun e -> guard_holds ctx st [ (root, e) ] eq.Schema.body)
        (entities_of_type ctx root)
  (* Rejected at declaration (Decl), so unreachable; a law with no subject
     vacuously holds rather than crashing the interrogator. *)
  | _ -> true
