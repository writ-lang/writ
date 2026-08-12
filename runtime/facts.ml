open Pol_data

(* Extension §2's built-in relations — the derived category as data.

   Every function here is a READ off [Space.t]. That is the whole design: the
   interrogator has already enumerated the reachable state category, so the
   built-ins are a projection of what it built, never a second traversal that
   could quietly disagree with it. It is also what makes extension §5 — "a rule
   never adds a situation, an edge or a cell" — true by construction rather than
   by discipline: there is nothing in this module that could add one.

   A situation is its [Space.index] throughout, in and out (§9): the space's own
   numbering is the only one, so no second identity has to be kept in step with
   it. *)

let index (sp : Space.t) (s : State.t) : int option =
  State.M.find_opt s sp.Space.index

let state (sp : Space.t) (i : int) : State.t option =
  if i >= 0 && i < Array.length sp.Space.states then Some sp.Space.states.(i)
  else None

(* [(situation S)] — S is a reachable situation. [Space.states] is exactly the
   reachable set, indexed in BFS order. *)
let situations (sp : Space.t) : int list =
  List.init (Array.length sp.Space.states) Fun.id

(* [(init S)] — S is the initial situation. The BFS seeds with it, so this is
   index 0; it is looked up rather than assumed, because an assumption about
   another module's internals is a lie waiting for that module to change. *)
let init (sp : Space.t) : int option = index sp sp.Space.initial

(* [(edge E S1 S2)] — transition E maps S1 to S2. Only [`To] edges: a [`Gap] has
   no successor situation and answers [gap-edge] instead. *)
let edges (sp : Space.t) : (string * int * int) list =
  List.filter_map
    (fun (e : Space.edge) ->
      match e.Space.dst with
      | `To s' -> (
          match (index sp e.Space.src, index sp s') with
          | Some a, Some b -> Some (e.Space.via, a, b)
          | _ -> None)
      | `Gap _ -> None)
    sp.Space.edges

(* [(gap-edge E S)] — transition E fires at S with no successor. Same edge list,
   opposite constructor: the two relations partition it. *)
let gap_edges (sp : Space.t) : (string * int) list =
  List.filter_map
    (fun (e : Space.edge) ->
      match e.Space.dst with
      | `Gap _ -> Option.map (fun a -> (e.Space.via, a)) (index sp e.Space.src)
      | `To _ -> None)
    sp.Space.edges

(* [(phase S P)] and [(phase-step P Q)] — the state category quotiented by
   mutual reachability, and its order. Both come from ONE [Space.phases] run:
   they are two readings of a single Tarjan pass, and computing them apart would
   let the map and its order disagree about where a component's boundary is. *)
let phases (sp : Space.t) : (int * int) list * (int * int) list =
  let comp, steps = Space.phases sp in
  (List.init (Array.length comp) (fun i -> (i, comp.(i))), steps)

(* [(holds S G)] — G is true in S, by the KERNEL's evaluator. One guard
   semantics, the kernel's: a rules engine that re-implemented [holds] would be
   able to disagree with `pol check` about the same formula. The environment is
   empty because the caller has already substituted the rule's variables
   ([Rules.lower]); what remains free is a kernel [some] binder, which [Eval]
   binds itself. *)
let holds (sp : Space.t) (i : int) (g : Model.guard) : bool =
  match state sp i with
  | None -> false
  | Some st -> Eval.guard_holds sp.Space.ctx st [] g

(* The value a path reads in a situation, or [None] if it is undefined. This is
   what makes a top-level [(is PATH V)] FUNCTIONAL (§2): the cell answers with a
   value, which either binds V or is compared with V's binding. *)
let read (sp : Space.t) (i : int) (p : Value.path) : string option =
  match state sp i with
  | None -> None
  | Some st -> (
      match Eval.eval_path sp.Space.ctx st [] p with
      | Some (Value.Filled v) -> Some v
      | Some Value.Vacant | None -> None)

(* The domain an unbound path root enumerates (§2): an enumerated type's values
   or an open type's roster. Declared rosters are the ONLY thing a rule ever
   generates over, which is what keeps §6's cost term bounded. *)
let entities (sp : Space.t) (ty : string) : string list =
  Eval.entities_of_type sp.Space.ctx ty
