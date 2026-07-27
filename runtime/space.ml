open Pol_data

(* BFS enumeration of the state category. Objects are reachable states; a real
   edge is a fired transition ([`To]); a [`Gap] edge is an exit with no
   successor. The build records the index and BFS distance of every state, so a
   witness is a shortest move sequence. *)

type step = [ `To of State.t | `Gap of string ]
type edge = { src : State.t; via : string; dst : step }

type t = {
  ctx : State.ctx;
  states : State.t array;
  index : int State.M.t;
  edges : edge list;
  initial : State.t;
  dist : int State.M.t;
  (* The BFS tree: the state a state was first reached FROM, and the move that
     did it. Recorded during the search because that is when it is known for
     free — the alternative is [shortest_path] rediscovering it afterwards by
     scanning every edge for a predecessor at distance d-1, which is
     O(edges) per step of every route and was, measured, the dominant cost of
     `pol check` on a large space. *)
  parent : (State.t * string) State.M.t;
  transitions : Model.transition list;
}

let cap = 200_000

(* Enumerate the reachable state category by breadth-first search from the
   initial state. Each enabled transition (its guard holds) fires: a [`Next]
   yields a real edge and, if new, a fresh state at distance +1; a [`Gap] yields
   a terminal gap edge with no successor. Unnamed transitions get a positional
   label. Overflowing the cap is an error. *)
let build (m : Model.t) : (t, string) result =
  match State.build_ctx m.schema m.initial with
  | Error e -> Error e
  | Ok (ctx, init) ->
      let index = ref State.M.empty in
      let dist = ref State.M.empty in
      let states = ref [] in
      let edges = ref [] in
      let count = ref 0 in
      let overflow = ref false in
      let queue = Queue.create () in
      let parent = ref State.M.empty in
      let add_state ?from s d =
        (match from with
        | Some (src, via) -> parent := State.M.add s (src, via) !parent
        | None -> ());
        index := State.M.add s !count !index;
        dist := State.M.add s d !dist;
        states := s :: !states;
        incr count;
        Queue.add s queue
      in
      add_state init 0;
      while (not (Queue.is_empty queue)) && not !overflow do
        let s = Queue.pop queue in
        let d = State.M.find s !dist in
        List.iteri
          (fun i (tr : Model.transition) ->
            if Eval.guard_holds ctx s [] tr.when_ then begin
              let via =
                match tr.name with Some n -> n | None -> "#" ^ string_of_int i
              in
              match Eval.apply ctx s tr.effects with
              (* A move whose chain-valued [set] has no answer here is NOT
                 available (§10.3). No edge of any kind — an edge to this same
                 situation would be a self-loop, and [dead_ends] below would
                 then never report the situation as stuck. *)
              | `Blocked -> ()
              | `Gap msg -> edges := { src = s; via; dst = `Gap msg } :: !edges
              | `Next s' ->
                  edges := { src = s; via; dst = `To s' } :: !edges;
                  if not (State.M.mem s' !index) then
                    if !count >= cap then overflow := true
                    else add_state ~from:(s, via) s' (d + 1)
            end)
          m.transitions
      done;
      if !overflow then Error "state space exceeds cap (200000)"
      else
        Ok
          {
            ctx;
            states = Array.of_list (List.rev !states);
            index = !index;
            edges = List.rev !edges;
            initial = init;
            dist = !dist;
            parent = !parent;
            transitions = m.transitions;
          }

let same (a : State.t) (b : State.t) : bool = Value.compare_cells a b = 0

(* A fewest-moves path from the initial state to [target], as [via] labels.
   The BFS tree is already the answer: every state records the state it was
   first reached from, and BFS reaches a state first at its shortest distance,
   so walking parents up to the initial state IS the shortest route. Linear in
   the route's length, and independent of the number of edges. *)
let shortest_path (t : t) (target : State.t) : string list =
  let rec go cur acc =
    match State.M.find_opt cur t.parent with
    | None -> acc (* the initial state has no parent — the walk is done *)
    | Some (src, via) -> go src (via :: acc)
  in
  go target []

(* The states that can reach an F-state over REAL edges (gap edges lead nowhere).
   Reverse BFS from the F-states along real-edge predecessors. The result is
   aligned to [t.states] by index. *)
let bwd_reach (t : t) (sat : State.t -> bool) : bool array =
  let n = Array.length t.states in
  let can = Array.make n false in
  let preds = Array.make n [] in
  List.iter
    (fun e ->
      match e.dst with
      | `To s' -> (
          match
            (State.M.find_opt e.src t.index, State.M.find_opt s' t.index)
          with
          | Some si, Some di -> preds.(di) <- si :: preds.(di)
          | _ -> ())
      | `Gap _ -> ())
    t.edges;
  let queue = Queue.create () in
  Array.iteri
    (fun i s ->
      if sat s then begin
        can.(i) <- true;
        Queue.add i queue
      end)
    t.states;
  while not (Queue.is_empty queue) do
    let i = Queue.pop queue in
    List.iter
      (fun p ->
        if not can.(p) then begin
          can.(p) <- true;
          Queue.add p queue
        end)
      preds.(i)
  done;
  can

(* The enabled moves out of a state: exactly the edges whose source is it (an
   edge is recorded only for an enabled transition). Gap edges are INCLUDED — a
   gap edge is recorded with [src = s], so a gap-firing state has a non-empty
   [enabled_of] and is therefore NOT a dead end (kernel §15: a gap is a declared
   boundary, listed separately, not an unannounced dead end). *)
let enabled_of (t : t) (s : State.t) : edge list =
  List.filter (fun e -> same e.src s) t.edges

(* The dead ends: reachable situations with NO enabled transition at all
   ([enabled_of s = []] — no real move AND no gap edge). Each is paired with its
   shortest route in (empty for the initial situation). BFS order. *)
let dead_ends (t : t) : (State.t * string list) list =
  (* ONE pass over the edges marks every state that has an outgoing one; a dead
     end is a state the pass never marked. The obvious spelling — [enabled_of]
     per state — rescans the whole edge list for each, which is O(states ×
     edges) and measured as 28 of the 31 seconds `pol check` spent on a
     16 870-state space. The search that built that space took 2. *)
  let has_out =
    List.fold_left
      (fun acc e -> State.M.add e.src true acc)
      State.M.empty t.edges
  in
  Array.to_list t.states
  |> List.filter (fun s -> not (State.M.mem s has_out))
  |> List.map (fun s -> (s, shortest_path t s))

(* The reachable gaps, DEDUPED by gap site — a site being the identity of the
   firing transition ([via]) plus the message (kernel §8: "the reachable gap
   list, with the fewest moves to reach each"). The same gap edge can issue from
   many reachable source states; each distinct site is reported once, with the
   fewest moves to reach ANY state that fires it. Result: (via, message,
   min-distance) per site, sorted by distance then message. Every gap edge's
   source is reachable (edges issue only from popped states). *)
let reachable_gaps (t : t) : (string * string * int) list =
  let raw =
    List.filter_map
      (fun e ->
        match e.dst with
        | `Gap msg -> (
            match State.M.find_opt e.src t.dist with
            | Some d -> Some ((e.via, msg), d)
            | None -> None)
        | `To _ -> None)
      t.edges
  in
  (* Fold to one entry per (via, msg) site, keeping the least distance. *)
  let sites =
    List.fold_left
      (fun acc (key, d) ->
        match List.assoc_opt key acc with
        | Some d0 ->
            if d < d0 then (key, d) :: List.remove_assoc key acc else acc
        | None -> (key, d) :: acc)
      [] raw
  in
  List.sort
    (fun ((_, m1), a) ((_, m2), b) ->
      match Int.compare a b with 0 -> String.compare m1 m2 | c -> c)
    sites
  |> List.map (fun ((via, msg), d) -> (via, msg, d))
