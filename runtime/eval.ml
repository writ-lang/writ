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

(* Write the cell named by a path's last step. The one-shorter prefix must be
   defined (yielding the source entity); the cell is then updated in place in the
   state vector. A step off an undefined prefix, or a target outside the layout
   (a fixed or unknown cell), leaves the state unchanged — guards are expected to
   have ensured applicability. *)
let write_cell (ctx : State.ctx) (st : State.t) (p : Value.path)
    (cell : Value.cell) : State.t =
  match List.rev p.steps with
  | [] -> st
  | last :: rev_prefix -> (
      let prefix = { p with steps = List.rev rev_prefix } in
      match eval_path ctx st [] prefix with
      | Some (Value.Filled src) -> (
          let cr = { Instance.arrow = last; src } in
          match State.index_of ctx cr with
          | Some i -> State.set st i cell
          | None -> st)
      | _ -> st)

(* Applying a move, in two phases, which is what §10.3's chain-valued [set]
   forced and what §10.1 now states outright.

   PHASE 1 reads every right-hand side in the situation the move STARTED from.
   That makes a [do] block a simultaneous assignment: [(do (set a.x b.y) (set
   b.y a.x))] is a swap, and the order of effects within one move stays
   unobservable — which it must, since §10.1 says no situation exists between
   two effects of one move, and nothing in the language can name that order.
   Threading the state through the writes one at a time, as this used to, is
   precisely the sequential reading that would break both.

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
  (* Phase 1: every right-hand side, against the starting situation. *)
  let rec resolve acc = function
    | [] -> Ok (List.rev acc)
    | Model.Set (p, r) :: rest -> (
        match read r with
        | Some v -> resolve (`Set (p, v) :: acc) rest
        | None -> Error `Blocked)
    | Model.Vacate p :: rest -> resolve (`Vacate p :: acc) rest
    | Model.Gap msg :: rest -> resolve (`Gap msg :: acc) rest
  in
  match resolve [] effects with
  | Error `Blocked -> `Blocked
  | Ok resolved -> (
      match List.find_opt (function `Gap _ -> true | _ -> false) resolved with
      | Some (`Gap msg) -> `Gap msg
      | _ ->
          (* Phase 2: the writes, on values already read. *)
          `Next
            (List.fold_left
               (fun st -> function
                 | `Set (p, v) -> write_cell ctx st p (Value.Filled v)
                 | `Vacate p -> write_cell ctx st p Value.Vacant
                 | `Gap _ -> st)
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
