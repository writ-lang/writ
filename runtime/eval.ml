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

let apply (ctx : State.ctx) (st : State.t) (effects : Model.effect list) :
    [ `Next of State.t | `Gap of string ] =
  let rec go st = function
    | [] -> `Next st
    | eff :: rest -> (
        match eff with
        | Model.Gap msg -> `Gap msg
        | Model.Set (p, v) -> go (write_cell ctx st p (Value.Filled v)) rest
        | Model.Vacate p -> go (write_cell ctx st p Value.Vacant) rest)
  in
  go st effects

(* Kleene path equality for an equation. Its paths share a common dom type; the
   law must hold at every element of that type, so the root type name is bound to
   each entity in turn. At a given element the equation is true unless both sides
   are defined and unequal (undefined on either side ⇒ vacuously satisfied). *)
let eq_holds (ctx : State.ctx) (st : State.t) (eq : Schema.equation) : bool =
  let entities = entities_of_type ctx eq.lhs.root in
  List.for_all
    (fun e ->
      let env = [ (eq.lhs.root, e); (eq.rhs.root, e) ] in
      match (eval_path ctx st env eq.lhs, eval_path ctx st env eq.rhs) with
      | Some (Value.Filled a), Some (Value.Filled b) -> String.equal a b
      | _ -> true)
    entities
