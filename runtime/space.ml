(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* BFS enumeration of the state category. Objects are reachable states; a
   [`To] edge is a fired transition, a [`Gap] edge an exit with no successor.
   BFS distances make every witness a shortest move sequence. *)

type step = [ `To of State.t | `Gap of string ]
type edge = { src : State.t; via : string; dst : step }

type t = {
  ctx : State.ctx;
  states : State.t array;
  index : int State.M.t;
  edges : edge list;
  initial : State.t;
  dist : int State.M.t;
  (* The BFS tree: the state each state was first reached from, and the move.
     Recorded during the search so [shortest_path] need not scan edges. *)
  parent : (State.t * string) State.M.t;
  transitions : Model.transition list;
}

let cap = 200_000

(* Why a bounded search stopped short: how far it got, and, per mutable cell,
   how many distinct values it had seen, most first, the cells driving the
   growth. *)
type cutoff = {
  reason : [ `Cap of int | `Timeout of float ];
  explored : int;
  edges_seen : int;
  spread : (string * int * int) list; (* cell, values seen, domain size *)
}

(* The most situations the mutable cells allow: the product of their domains.
   A float, since it overflows an int long before it is interesting. *)
let bound (lay : State.layout) : float =
  Array.fold_left
    (fun acc d -> acc *. float_of_int (max 1 (Array.length d)))
    1.0 lay.State.domains

let show_bound f =
  if f < 1e9 then Printf.sprintf "%.0f" f else Printf.sprintf "%.2g" f

let spread_of (ctx : State.ctx) (states : State.t list) =
  let lay = ctx.State.layout in
  let n = Array.length lay.State.cells in
  let seen = Array.init n (fun _ -> Hashtbl.create 8) in
  List.iter
    (fun (s : State.t) ->
      Array.iteri (fun i v -> Hashtbl.replace seen.(i) v ()) s)
    states;
  List.init n (fun i ->
      let cr = lay.State.cells.(i) in
      ( cr.Instance.src ^ "." ^ cr.Instance.arrow,
        Hashtbl.length seen.(i),
        Array.length lay.State.domains.(i) ))
  |> List.stable_sort (fun (_, a, _) (_, b, _) -> compare b a)

(* Breadth-first search from the initial state, firing every enabled
   transition. Unnamed transitions get a positional label [#i]. The search
   stops at [max] situations or after [timeout] seconds of CPU time. *)
let explore ?(max = cap) ?timeout (m : Model.t) :
    (t, [ `Model of string | `Cutoff of cutoff ]) result =
  match State.build_ctx m.schema m.initial with
  | Error e -> Error (`Model e)
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
      let started = Sys.time () in
      let timed_out = ref None in
      (* The clock is read every 256 situations expanded, not added: adding
         can stall while the queue drains. *)
      let popped = ref 0 in
      add_state init 0;
      while
        (not (Queue.is_empty queue)) && (not !overflow) && !timed_out = None
      do
        incr popped;
        (match timeout with
        | Some t when !popped land 255 = 0 && Sys.time () -. started > t ->
            timed_out := Some t
        | _ -> ());
        let s = Queue.pop queue in
        let d = State.M.find s !dist in
        List.iteri
          (fun i (tr : Model.transition) ->
            if Eval.guard_holds ctx s [] tr.when_ then begin
              let via =
                match tr.name with Some n -> n | None -> "#" ^ string_of_int i
              in
              match Eval.apply ctx s tr.effects with
              (* A chain-valued [set] with no answer: the move is not
                 available (§10.3). No edge at all — a self-loop would hide a
                 dead end. *)
              | `Blocked -> ()
              | `Gap msg -> edges := { src = s; via; dst = `Gap msg } :: !edges
              | `Next s' ->
                  edges := { src = s; via; dst = `To s' } :: !edges;
                  if not (State.M.mem s' !index) then
                    if !count >= max then overflow := true
                    else add_state ~from:(s, via) s' (d + 1)
            end)
          m.transitions
      done;
      let cutoff reason =
        Error
          (`Cutoff
             {
               reason;
               explored = !count;
               edges_seen = List.length !edges;
               spread = spread_of ctx !states;
             })
      in
      if !overflow then cutoff (`Cap max)
      else if !timed_out <> None then cutoff (`Timeout (Option.get !timed_out))
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

(* The unbounded-by-choice search the CLI uses: [cap] situations, no clock. *)
let build (m : Model.t) : (t, string) result =
  match explore m with
  | Ok t -> Ok t
  | Error (`Model e) -> Error e
  | Error (`Cutoff _) ->
      Error ("state space exceeds cap (" ^ string_of_int cap ^ ")")

let same (a : State.t) (b : State.t) : bool = Value.compare_cells a b = 0

(* A fewest-moves path from the initial state to [target], as [via] labels:
   BFS reaches each state first at its shortest distance, so walking the
   parents is the shortest route. *)
let shortest_path (t : t) (target : State.t) : string list =
  let rec go cur acc =
    match State.M.find_opt cur t.parent with
    | None -> acc (* the initial state has no parent — the walk is done *)
    | Some (src, via) -> go src (via :: acc)
  in
  go target []

(* The states that can reach an F-state over real edges, aligned to
   [t.states]. Reverse BFS. *)
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

(* Real-edge successor lists, aligned to [t.states]. A gap has no successor
   situation, so it is not a move within the model. *)
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

(* Tarjan's strongly connected components — the phases — mapping each
   situation to the least index in its phase. Iterative, since the walk can be
   as deep as the space (§14 allows 200 000). Takes [succ] so [escapes_f] can
   run it on a subgraph. *)
let tarjan (n : int) (succ : int list array) : int array =
  let visit =
    Array.make n (-1)
    (* preorder number, -1 = unvisited *)
  in
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
  (* Pop the phase down to its root and name every member after the least
     index. *)
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
      (* Explicit DFS stack: a situation and its successors still to try. *)
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
                (* v is finished: pass its low-link to the parent frame, and
                   close the phase if v roots one. *)
                work := rest;
                (match rest with
                | (p, _) :: _ -> if low.(v) < low.(p) then low.(p) <- low.(v)
                | [] -> ());
                if low.(v) = visit.(v) then close v)
      done
    end
  done;
  comp

(* How many situations lie on a cycle (a phase of more than one, or a
   self-loop). Zero is the committing regime, where no move can be undone;
   anything else is reversible. See docs/tractability.md §6. *)
let recurrent_count (t : t) : int =
  let comp = tarjan (Array.length t.states) (succs t) in
  let n = Array.length t.states in
  let size = Array.make n 0 in
  Array.iter (fun r -> size.(r) <- size.(r) + 1) comp;
  let self_loop = Array.make n false in
  List.iter
    (fun (e : edge) ->
      match e.dst with
      | `To d -> (
          match
            (State.M.find_opt e.src t.index, State.M.find_opt d t.index)
          with
          | Some s, Some d when s = d -> self_loop.(s) <- true
          | _ -> ())
      | `Gap _ -> ())
    t.edges;
  let c = ref 0 in
  for i = 0 to n - 1 do
    if size.(comp.(i)) > 1 || self_loop.(i) then incr c
  done;
  !c

let phases (t : t) : int array * (int * int) list =
  let comp = tarjan (Array.length t.states) (succs t) in
  let steps =
    List.sort_uniq compare
      (List.filter_map
         (fun (e : edge) ->
           match e.dst with
           | `To s' -> (
               match
                 (State.M.find_opt e.src t.index, State.M.find_opt s' t.index)
               with
               | Some si, Some di when comp.(si) <> comp.(di) ->
                   Some (comp.(si), comp.(di))
               | _ -> None)
           | `Gap _ -> None)
         t.edges)
  in
  (comp, steps)

(* The moves available at each situation, by name, including those that end
   at a gap — fairness has something to say about them too. *)
let enabled_names (t : t) : string list array =
  let n = Array.length t.states in
  let out = Array.make n [] in
  List.iter
    (fun e ->
      match State.M.find_opt e.src t.index with
      | Some si ->
          if not (List.mem e.via out.(si)) then out.(si) <- e.via :: out.(si)
      | None -> ())
    t.edges;
  out

(* The counterexample set of [inevitable F]: non-F situations where a run
   stops (no real move out — a gap counts as a stop, §10.4) or that lie on a
   cycle avoiding F.

   [fair] moves are assumed not starved: a cycle that offers one and never
   takes it is removed, repeatedly (Emerson–Lei). Stops are unaffected.
   Not closed backward: the closure gives the same verdict but its shortest
   witness would usually be the empty route. *)
let escapes_f ?(fair = []) (t : t) (sat : State.t -> bool) : bool array =
  let n = Array.length t.states in
  let f = Array.init n (fun i -> sat t.states.(i)) in
  let all = succs t in
  let avail = enabled_names t in
  (* Labelled edges inside the non-F region, where a fair cycle's steps come
     from. *)
  let labelled =
    List.filter_map
      (fun e ->
        match e.dst with
        | `To s' -> (
            match
              (State.M.find_opt e.src t.index, State.M.find_opt s' t.index)
            with
            | Some si, Some di when (not f.(si)) && not f.(di) ->
                Some (e.via, si, di)
            | _ -> None)
        | `Gap _ -> None)
      t.edges
  in
  (* The non-F region minus what the fairness deletions removed. *)
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
    Array.iteri
      (fun i k -> if alive.(i) && k >= 0 then size.(k) <- size.(k) + 1)
      c;
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
          if cyclic i && List.mem mv avail.(i) then
            Hashtbl.replace offers c.(i) ()
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
  (* A last partition over the survivors: which are still on a cycle. *)
  let sub = Array.make n [] in
  Array.iteri
    (fun i outs ->
      if alive.(i) then
        List.iter (fun j -> if alive.(j) then sub.(i) <- j :: sub.(i)) outs)
    all;
  let c = tarjan n sub in
  let size = Array.make n 0 in
  Array.iteri
    (fun i k -> if alive.(i) && k >= 0 then size.(k) <- size.(k) + 1)
    c;
  Array.init n (fun i ->
      (not f.(i))
      && ((* stopped: no real move out of the model at all *)
          all.(i) = []
         || (alive.(i) && (size.(c.(i)) > 1 || List.mem i sub.(i)))))

(* The edges out of a state, gap edges included — so a gap-firing state is not
   a dead end (§15: a gap is a declared boundary, listed separately). *)
let enabled_of (t : t) (s : State.t) : edge list =
  List.filter (fun e -> same e.src s) t.edges

(* Reachable situations with no move at all — no real edge and no gap edge
   (a gap is a declared stop, reported separately) — each with its shortest
   route in, in BFS order. *)
let dead_ends (t : t) : (State.t * string list) list =
  (* One pass marks every state with an outgoing edge. *)
  let has_out =
    List.fold_left
      (fun acc e -> State.M.add e.src true acc)
      State.M.empty t.edges
  in
  Array.to_list t.states
  |> List.filter (fun s -> not (State.M.mem s has_out))
  |> List.map (fun s -> (s, shortest_path t s))

(* The reachable gaps, one per site (transition plus message), each with the
   fewest moves to reach any state that fires it (§8). Sorted by distance,
   then message. *)
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
