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

(* The successor lists of the real-edge graph, aligned to [t.states] by index.
   Gap edges are excluded, for [bwd_reach]'s reason: a gap has no successor
   situation, so it is an exit from the model rather than a move within it. *)
let succs (t : t) : int list array =
  let n = Array.length t.states in
  let out = Array.make n [] in
  List.iter
    (fun e ->
      match e.dst with
      | `To s' -> (
          match
            (State.M.find_opt e.src t.index, State.M.find_opt s' t.index)
          with
          | Some si, Some di -> out.(si) <- di :: out.(si)
          | _ -> ())
      | `Gap _ -> ())
    t.edges;
  out

(* The PHASES: the strongly connected components of the real-edge graph, and the
   edges of the quotient. A phase is what ct.rules calls an isomorphism class —
   inside one, every situation reaches every other, so nothing has been spent
   and every arrangement is recoverable from every other. Between two, the move
   is one-way: the quotient is acyclic by construction.

   Returns [comp], mapping each situation to its phase's REPRESENTATIVE — the
   least-indexed situation in it, so the name is the earliest arrangement of the
   class the search found — and the distinct quotient edges, [(P, Q)] with
   P ≠ Q, deduplicated.

   WHY IT IS HERE rather than derived in a .rules file. Every phase question a
   rules file can ask today has to route through the transitive closure
   [reach], whose ANSWER is quadratic in the situation count: at 1 938
   situations the closure does not finish in 100 seconds, while the space it
   closes over is built in 30 milliseconds, and the kernel's conformance floor
   is 200 000 (§14). Tarjan is linear in situations and edges, and the
   relations that rest on it — final phases, one-way moves, recurrence — become
   linear with it. What stays quadratic is [reach] and [before] themselves,
   whose answers ARE sets of pairs; that cost is the answer's, not the
   algorithm's, and no built-in can remove it.

   Iterative rather than recursive, and that is not a style preference: the
   depth of this walk is the depth of the situation space, which §14 permits to
   be 200 000, and a native stack does not hold that many frames.

   [tarjan] takes the successor array rather than reading [t] because the SAME
   pass answers a second question on a RESTRICTED graph — see [avoids_forever],
   which needs the components of the subgraph a guard fails in, and cannot get
   them from a partition of the whole. A node with no edges either way is a
   component of one, which is exactly what a restriction should leave behind. *)
let tarjan (n : int) (succ : int list array) : int array =
  let visit = Array.make n (-1) (* preorder number, -1 = unvisited *) in
  let low = Array.make n 0 in
  let on = Array.make n false in
  let comp = Array.make n (-1) in
  let stack = ref [] in
  let clock = ref 0 in
  let open_ v =
    visit.(v) <- !clock;
    low.(v) <- !clock;
    incr clock;
    stack := v :: !stack;
    on.(v) <- true
  in
  (* Pop this phase off the tentative stack, down to and including its root, and
     name every member after the least index among them. *)
  let close v =
    let members = ref [] in
    let rec pop () =
      match !stack with
      | w :: ws ->
          stack := ws;
          on.(w) <- false;
          members := w :: !members;
          if w <> v then pop ()
      | [] -> ()
    in
    pop ();
    let rep = List.fold_left min v !members in
    List.iter (fun w -> comp.(w) <- rep) !members
  in
  for root = 0 to n - 1 do
    if visit.(root) < 0 then begin
      open_ root;
      (* The explicit DFS stack: each frame is a situation and the successors of
         it still to try. *)
      let work = ref [ (root, succ.(root)) ] in
      while !work <> [] do
        match !work with
        | [] -> ()
        | (v, todo) :: rest -> (
            match todo with
            | w :: more ->
                work := (v, more) :: rest;
                if visit.(w) < 0 then begin
                  open_ w;
                  work := (w, succ.(w)) :: !work
                end
                else if on.(w) && visit.(w) < low.(v) then low.(v) <- visit.(w)
            | [] ->
                (* v is finished: hand its low-link up to its parent, which is
                   the frame beneath it, and close the phase if v roots one. *)
                work := rest;
                (match rest with
                | (p, _) :: _ -> if low.(v) < low.(p) then low.(p) <- low.(v)
                | [] -> ());
                if low.(v) = visit.(v) then close v)
      done
    end
  done;
  comp

let phases (t : t) : int array * (int * int) list =
  let comp = tarjan (Array.length t.states) (succs t) in
  let steps =
    List.sort_uniq compare
      (List.filter_map
         (fun (e : edge) ->
           match e.dst with
           | `To s' -> (
               match (State.M.find_opt e.src t.index, State.M.find_opt s' t.index)
               with
               | Some si, Some di when comp.(si) <> comp.(di) ->
                   Some (comp.(si), comp.(di))
               | _ -> None)
           | `Gap _ -> None)
         t.edges)
  in
  (comp, steps)

(* The moves each situation has available, by name, INCLUDING the ones that end
   at a gap: a gap edge is a transition firing, so a rule about a move not being
   starved has something to say about it. *)
let enabled_names (t : t) : string list array =
  let n = Array.length t.states in
  let out = Array.make n [] in
  List.iter
    (fun e ->
      match State.M.find_opt e.src t.index with
      | Some si -> if not (List.mem e.via out.(si)) then out.(si) <- e.via :: out.(si)
      | None -> ())
    t.edges;
  out

(* The situations at which a run stops short of F, or starts going round without
   it — the counterexample set of [inevitable F], aligned to [t.states] by index.

   A run is maximal: it goes on forever, or it stops where the model does. So a
   run avoids F in exactly two ways, and both are read off the subgraph of NON-F
   situations, since a run that touches an F situation has not avoided it:

   - it goes round for ever — a cycle in that subgraph;
   - it stops — a non-F situation with no real move out. That covers a dead end
     and, deliberately, a situation whose only move is a GAP. A gap is the model
     saying its rules run out here (§10.4), and "F is inevitable" claimed past
     the point a model admits it has stopped speaking would be a claim the model
     does not make. `live` already treats a gap exit as a non-F terminal; this
     is the same reading.

   [fair] names moves the question assumes are not starved: a run in which such
   a move is available again and again, for ever, and never taken, is not a run
   the question is about. Only cycles are affected. A run that STOPS is finite,
   and nothing is available for ever in it, so a stop is a counterexample under
   every fairness assumption there is — which is the right answer: no assumption
   about scheduling rescues a protocol that deadlocks.

   The test on a cycle is per named move: the cycle is unfair if some situation
   on it has the move available and no step of it takes the move. Removing those
   situations can break the cycle into smaller ones that are fair, so the
   deletion repeats until nothing more is removed (Emerson–Lei). With [fair]
   empty the loop runs once and deletes nothing, which is the same walk as
   before at the same cost.

   ONE SET, NOT TWO, and it is worth saying why the obvious extra step is
   absent. Every situation that can reach one of these without leaving the
   subgraph also has a run avoiding F, so the counterexample set is really the
   backward closure of this one. Closing it changes no verdict — the closure is
   empty exactly when this set is — and it makes the report worse: the closure
   almost always contains the INITIAL situation, so the shortest witness becomes
   the empty route, which says only that an escape exists somewhere. The route
   to the escape ITSELF is the answer to "where", and that is this set.

   Note the degenerate case falls out: where F holds the situation is not in the
   subgraph at all, so it is never a counterexample — a run that starts at its
   goal has reached it. *)
let escapes_f ?(fair = []) (t : t) (sat : State.t -> bool) : bool array =
  let n = Array.length t.states in
  let f = Array.init n (fun i -> sat t.states.(i)) in
  let all = succs t in
  let avail = enabled_names t in
  (* The labelled edges inside the non-F region, which is where a fair cycle's
     steps have to come from. *)
  let labelled =
    List.filter_map
      (fun e ->
        match e.dst with
        | `To s' -> (
            match (State.M.find_opt e.src t.index, State.M.find_opt s' t.index) with
            | Some si, Some di when (not f.(si)) && not f.(di) ->
                Some (e.via, si, di)
            | _ -> None)
        | `Gap _ -> None)
      t.edges
  in
  (* [alive] is the non-F region minus what the fairness deletions have removed;
     it shrinks, and the cycles are recomputed over what is left. *)
  let alive = Array.init n (fun i -> not f.(i)) in
  let comp = ref [||] in
  let changed = ref true in
  while !changed do
    changed := false;
    let sub = Array.make n [] in
    Array.iteri
      (fun i outs ->
        if alive.(i) then
          List.iter (fun j -> if alive.(j) then sub.(i) <- j :: sub.(i)) outs)
      all;
    comp := tarjan n sub;
    let c = !comp in
    let size = Array.make n 0 in
    Array.iteri (fun i k -> if alive.(i) && k >= 0 then size.(k) <- size.(k) + 1) c;
    let cyclic i = alive.(i) && (size.(c.(i)) > 1 || List.mem i sub.(i)) in
    List.iter
      (fun mv ->
        (* Which cycles take this move, and which merely have it on offer. *)
        let takes = Hashtbl.create 16 in
        List.iter
          (fun (via, si, di) ->
            if String.equal via mv && cyclic si && c.(si) = c.(di) then
              Hashtbl.replace takes c.(si) ())
          labelled;
        let offers = Hashtbl.create 16 in
        for i = 0 to n - 1 do
          if cyclic i && List.mem mv avail.(i) then Hashtbl.replace offers c.(i) ()
        done;
        Hashtbl.iter
          (fun k () ->
            if not (Hashtbl.mem takes k) then
              for i = 0 to n - 1 do
                if cyclic i && c.(i) = k && List.mem mv avail.(i) then begin
                  alive.(i) <- false;
                  changed := true
                end
              done)
          offers)
      fair
  done;
  (* One last partition over what survived, to say which situations are still on
     a cycle. *)
  let sub = Array.make n [] in
  Array.iteri
    (fun i outs ->
      if alive.(i) then
        List.iter (fun j -> if alive.(j) then sub.(i) <- j :: sub.(i)) outs)
    all;
  let c = tarjan n sub in
  let size = Array.make n 0 in
  Array.iteri (fun i k -> if alive.(i) && k >= 0 then size.(k) <- size.(k) + 1) c;
  Array.init n (fun i ->
      (not f.(i))
      && ((* stopped: no real move out of the model at all *)
          all.(i) = []
          || (alive.(i) && (size.(c.(i)) > 1 || List.mem i sub.(i)))))

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
