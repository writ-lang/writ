open Pol_data

(* The four modalities as hom-set questions, with witnesses. A witness is a
   morphism of the state category — a BFS shortest path — so it is computed here
   and nowhere else (never in [query] or [core]).

   - [never F]: fail if any reachable F; witness = shortest path to it.
   - [possible F]: hold if any reachable F — and [Holds] then carries the
     shortest path to a satisfying situation as EVIDENCE: for a [possible] that
     asks "can this happen", that path IS the answer, the solution shown (spec
     Appendix C: a solvable river prints the crossing). Fails with no route —
     nothing satisfies F.
   - [live F]: [AG EF F] over real edges — hold iff every reachable state can
     reach an F-state; gap exits are non-F terminals. Fail-witness = shortest
     path to a state that cannot reach F.
   - [inevitable F]: [AG AF F] — hold iff no reachable state has a whole run
     that avoids F, a run being maximal: forever round a cycle, or stopped
     where the model stops. Fail-witness = shortest path to the situation the
     run stops at or starts circling in — where it escapes, rather than where
     escaping first became possible, which is usually the initial situation and
     says nothing.

   [inevitable] is strictly stronger than [live], and the implication is worth
   knowing because it says which of the two to reach for. Every state has at
   least one run, so a state all of whose runs reach F is a state F is
   reachable from: [inevitable F] holding anywhere makes [live F] hold there
   too. The gap between them is one-directional, and it is where a model with
   independent parties lives — a protocol that retransmits can always still
   finish and need never do it, which is [live] holding while [inevitable]
   fails. Nothing passes [inevitable] and fails [live].
   [Not_applicable] when F names schema structure (a type/arrow/value) that does
   not exist — reported, but neither a pass nor a failure.

   [Holds] carries an evidence route, non-empty only for a holding [possible]
   (the solution path); empty for the other three, which have no single
   witness.
   A [Fails] carries the shortest witness route AND, for a failing [live] or
   [inevitable], the stuck [State.t] — the situation that can no longer reach
   F, or the one a run can escape from — so the
   report can render its [stuck at:] cell layout. Formatting stays in [report];
   the checker only supplies the evidence. *)

type outcome =
  | Holds of string list
  | Fails of { route : string list; stuck : State.t option }
  | Not_applicable of string

(* The type heading a path's root: a [some]-bound variable's declared type, or
   the type whose roster holds the entity. *)
let root_type (ctx : State.ctx) (env : (string * string) list) (root : string) :
    string option =
  match List.assoc_opt root env with
  | Some ty -> Some ty
  | None ->
      List.find_map
        (fun (r : Instance.roster) ->
          if List.mem root r.entities then Some r.ty else None)
        ctx.rosters

(* Structurally resolve a path against the schema, returning its final cod type,
   or [None] if any step names an arrow the schema lacks. *)
let path_cod (ctx : State.ctx) (env : (string * string) list) (p : Value.path) :
    string option =
  match root_type ctx env p.root with
  | None -> None
  | Some ty ->
      let rec walk cur = function
        | [] -> Some cur
        | step :: rest -> (
            match Schema.arrow_in ctx.schema ~dom:cur step with
            | Some a -> walk a.cod rest
            | None -> None)
      in
      walk ty p.steps

(* Whether a value names an element of a type: an enumerated value, or an entity
   of an open type's roster. *)
let value_in_type (ctx : State.ctx) (ty : string) (v : string) : bool =
  match Schema.type_of ctx.schema ty with
  | Some { flavor = Enumerated vs; _ } -> List.mem v vs
  | Some { flavor = Open; _ } ->
      List.exists
        (fun (r : Instance.roster) -> r.ty = ty && List.mem v r.entities)
        ctx.rosters
  | None -> false

(* A formula is structurally applicable iff every path resolves and every named
   type and compared value exists. Otherwise the property is n/a. *)
let rec guard_ok (ctx : State.ctx) (env : (string * string) list)
    (g : Model.guard) : bool =
  match g with
  | Model.And gs | Model.Or gs -> List.for_all (guard_ok ctx env) gs
  | Model.Not g -> guard_ok ctx env g
  | Model.Is (p, r) -> (
      match (path_cod ctx env p, r) with
      | Some ty, Model.Lit v -> value_in_type ctx ty v
      | Some ty, Model.Chain q -> path_cod ctx env q = Some ty
      | None, _ -> false)
  | Model.Defined p -> path_cod ctx env p <> None
  | Model.Some_ (x, ty, g) -> (
      match Schema.type_of ctx.schema ty with
      | None -> false
      | Some _ -> guard_ok ctx ((x, ty) :: env) g)

(* The reachable state satisfying [pred] at the least BFS distance, if any. *)
let nearest (sp : Space.t) (pred : State.t -> bool) : State.t option =
  let best = ref None in
  Array.iter
    (fun s ->
      if pred s then
        match !best with
        | None -> best := Some s
        | Some b ->
            let ds = State.M.find s sp.dist and db = State.M.find b sp.dist in
            if ds < db then best := Some s)
    sp.states;
  !best

let check (sp : Space.t) (prop : Claims.property) : outcome =
  let ctx = sp.Space.ctx in
  if not (guard_ok ctx [] prop.formula) then
    Not_applicable ("schema lacks structure named by " ^ prop.name)
  else
    let sat s = Eval.guard_holds ctx s [] prop.formula in
    match prop.modality with
    | Claims.Possible -> (
        (* Holding evidence = the shortest path to a satisfying situation: the
           solution the question asked for. *)
        match nearest sp sat with
        | Some s -> Holds (Space.shortest_path sp s)
        | None -> Fails { route = []; stuck = None })
    | Claims.Never -> (
        match nearest sp sat with
        | Some s -> Fails { route = Space.shortest_path sp s; stuck = None }
        | None -> Holds [])
    | Claims.Live -> (
        let can = Space.bwd_reach sp sat in
        let cannot s =
          match State.M.find_opt s sp.index with
          | Some i -> not can.(i)
          | None -> false
        in
        match nearest sp cannot with
        | None -> Holds []
        | Some s -> Fails { route = Space.shortest_path sp s; stuck = Some s })
    | Claims.Inevitable -> (
        let esc = Space.escapes_f sp sat in
        let escapes s =
          match State.M.find_opt s sp.index with
          | Some i -> esc.(i)
          | None -> false
        in
        match nearest sp escapes with
        | None -> Holds []
        | Some s -> Fails { route = Space.shortest_path sp s; stuck = Some s })
