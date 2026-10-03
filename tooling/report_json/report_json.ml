(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data
open Writ_runtime

(* Every answer the tool prints, as one JSON value (docs/json.md is the
   schema). The prose in [Report] is a separate rendering of the same engine
   values, so the JSON is never a parse of the prose.

   A route step carries the situation it lands in ([to]), so a witness can be
   followed with `writ show --at N`; a vacant cell is [null], not "∅". *)

let str s = Json.String s
let int i = Json.Int i
let strs l = Json.List (List.map str l)
let opt f = function None -> Json.Null | Some x -> f x
let index_of (sp : Space.t) (s : State.t) = State.M.find_opt s sp.Space.index

let cell_value = function
  | Value.Filled v -> Json.String v
  | Value.Vacant -> Json.Null

(* A situation's mutable cells, keyed [SRC.ARROW] as the prose spells them. *)
let cells (sp : Space.t) (s : State.t) : Json.t =
  let cs = sp.Space.ctx.State.layout.State.cells in
  Json.Assoc
    (Array.to_list
       (Array.mapi
          (fun i (cr : Instance.cellref) ->
            (cr.Instance.src ^ "." ^ cr.Instance.arrow, cell_value s.(i)))
          cs))

(* [[{move, to}…]]: a route and where each step lands. *)
let route (sp : Space.t) (moves : string list) : Json.t =
  let tos = Route.walk sp moves in
  Json.List
    (List.mapi
       (fun i m ->
         Json.Assoc
           [
             ("move", str m);
             ("to", opt int (List.nth_opt tos i));
             ("origin", opt str (Report.move_origin sp m));
           ])
       moves)

(* --- §15 build report ------------------------------------------------------ *)

let gaps (sp : Space.t) : Json.t =
  Json.List
    (List.map
       (fun (via, msg, d) ->
         Json.Assoc
           [ ("move", str via); ("message", str msg); ("min_moves", int d) ])
       (Space.reachable_gaps sp))

let dead_ends (sp : Space.t) : Json.t =
  Json.List
    (List.map
       (fun (s, r) ->
         Json.Assoc
           [ ("state", opt int (index_of sp s)); ("route", route sp r) ])
       (Space.dead_ends sp))

let laws (sp : Space.t) : Json.t =
  Json.List
    (List.map
       (fun (l : Observe.law) ->
         Json.Assoc
           [
             ("name", str l.Observe.name);
             ("origin", opt str (Report.law_origin sp l.Observe.name));
             ("breakers", strs l.Observe.breakers);
             ( "violated",
               match l.Observe.violation with
               | None -> Json.Null
               | Some (n, r) ->
                   Json.Assoc [ ("count", int n); ("witness", route sp r) ] );
           ])
       (Observe.laws sp))

(* --- §16 claims ------------------------------------------------------------ *)

let modality = function
  | Claims.Never -> "never"
  | Claims.Possible -> "possible"
  | Claims.Live -> "live"
  | Claims.Inevitable _ -> "inevitable"

let fair = function Claims.Inevitable ms -> ms | _ -> []

let query_rows (q : Claims.query) (idx : int)
    (rows : (string * string) list list) : Json.t =
  Json.Assoc
    [
      ("name", str q.Claims.name);
      ("at", int idx);
      ( "rows",
        Json.List
          (List.map
             (fun r -> Json.Assoc (List.map (fun (k, v) -> (k, str v)) r))
             rows) );
    ]

let property ?(queries : Claims.query list = []) (sp : Space.t)
    (p : Claims.property) (oc : Checker.outcome) : Json.t =
  let head =
    [
      ("name", str p.Claims.name);
      ("description", str p.Claims.text);
      ("modality", str (modality p.Claims.modality));
      ("fair", strs (fair p.Claims.modality));
    ]
  in
  let tail =
    match oc with
    | Checker.Holds r ->
        [
          ("verdict", str "holds");
          ("witness", route sp r);
          ("stuck_at", Json.Null);
        ]
    | Checker.Not_applicable why ->
        [
          ("verdict", str "n/a");
          ("reason", str why);
          ("witness", Json.List []);
          ("stuck_at", Json.Null);
        ]
    | Checker.Fails { route = r; stuck } ->
        [
          ("verdict", str "fails");
          ("witness", route sp r);
          ("stuck_at", opt int (Option.bind stuck (index_of sp)));
        ]
  in
  let shown =
    Json.List
      (List.map
         (fun (q, idx, rows) -> query_rows q idx rows)
         (Report.shown_rows ~queries sp p oc))
  in
  Json.Assoc (head @ tail @ [ ("show", shown) ])

(* The §17 fibers of a property, each a verdict with its witness. *)
let fibers (sp : Space.t) (fs : (Fiber.fiber * Checker.outcome) list) : Json.t =
  Json.List
    (List.map
       (fun ((f : Fiber.fiber), oc) ->
         let verdict, witness, stuck =
           match oc with
           | Checker.Holds r -> ("holds", route sp r, Json.Null)
           | Checker.Not_applicable _ -> ("n/a", Json.List [], Json.Null)
           | Checker.Fails { route = r; stuck } ->
               ("fails", route sp r, opt int (Option.bind stuck (index_of sp)))
         in
         Json.Assoc
           [
             ( "cells",
               Json.Assoc
                 (List.map2
                    (fun (n, _) v -> (n, str v))
                    f.Fiber.cells f.Fiber.values) );
             ("verdict", str verdict);
             ("witness", witness);
             ("stuck_at", stuck);
           ])
       fs)

let ack (tr, eq) = Json.Assoc [ ("move", str tr); ("law", str eq) ]

(* The whole of `writ check`, in prose order. [exit] is included for consumers
   reading a pipe. *)
let check ~(queries : Claims.query list) ~(sp : Space.t)
    ~(unadmitted : (string * string) list) ~(stale : (string * string) list)
    ~(props : (Claims.property * Checker.outcome) list)
    ~(answered : (Claims.query * int * (string * string) list list) list)
    ~(exit : int) : Json.t =
  let defined = queries in
  Json.Assoc
    [
      ("states", int (Array.length sp.Space.states));
      ("edges", int (List.length sp.Space.edges));
      ( "regime",
        let k = Space.recurrent_count sp in
        Json.Assoc
          [
            ("kind", str (if k = 0 then "committing" else "reversible"));
            ("recurrent", int k);
          ] );
      ("gaps", gaps sp);
      ("dead_ends", dead_ends sp);
      ("equations", laws sp);
      ("unadmitted", Json.List (List.map ack unadmitted));
      ("stale", Json.List (List.map ack stale));
      ( "properties",
        Json.List
          (List.map (fun (p, o) -> property ~queries:defined sp p o) props) );
      ( "queries",
        Json.List (List.map (fun (q, i, rows) -> query_rows q i rows) answered)
      );
      ("exit", int exit);
    ]

(* --- §17 compare ----------------------------------------------------------- *)

(* A LOST property's witness is a route through the NEW model, so that is the
   space its steps are indexed in. *)
let compare ~(new_sp : Space.t) ~(equations : Compare.row list)
    ~(properties : Compare.row list) ~(exit : int) : Json.t =
  let row (r : Compare.row) =
    Json.Assoc
      [
        ("name", str r.Compare.name);
        ("status", str r.Compare.status);
        ( "witness",
          match r.Compare.witness with
          | None -> Json.List []
          | Some w -> route new_sp w );
      ]
  in
  Json.Assoc
    [
      ("equations", Json.List (List.map row equations));
      ("properties", Json.List (List.map row properties));
      ("exit", int exit);
    ]

(* --- one situation --------------------------------------------------------- *)

let situation (sp : Space.t) (i : int) : Json.t =
  let s = sp.Space.states.(i) in
  let moves =
    List.filter_map
      (fun (e : Space.edge) ->
        if not (Space.same e.Space.src s) then None
        else
          match e.Space.dst with
          | `To d ->
              Some
                (Json.Assoc
                   [
                     ("move", str e.Space.via); ("to", opt int (index_of sp d));
                   ])
          | `Gap msg ->
              Some (Json.Assoc [ ("move", str e.Space.via); ("gap", str msg) ]))
      sp.Space.edges
  in
  Json.Assoc
    [
      ("index", int i);
      ("initial", Json.Bool (Space.same s sp.Space.initial));
      ("cells", cells sp s);
      ("route", route sp (Space.shortest_path sp s));
      ("moves", Json.List moves);
    ]

let show (sp : Space.t) (idxs : int list) : Json.t =
  Json.Assoc [ ("situations", Json.List (List.map (situation sp) idxs)) ]

(* --- graph ----------------------------------------------------------------- *)

let graph (g : Graph.t) : Json.t =
  let node (n : Graph.node) =
    Json.Assoc
      [
        ("id", int n.Graph.id);
        ("size", int n.Graph.size);
        ("initial", Json.Bool n.Graph.initial);
        ("final", Json.Bool n.Graph.final);
        ("gaps", strs n.Graph.gaps);
        ("lit", Json.Bool (List.mem n.Graph.id g.Graph.lit_nodes));
      ]
  in
  let edge (e : Graph.edge) =
    Json.Assoc
      [
        ("from", int e.Graph.src);
        ("to", int e.Graph.dst);
        ("moves", strs e.Graph.moves);
        ( "lit",
          Json.Bool (List.mem (e.Graph.src, e.Graph.dst) g.Graph.lit_edges) );
      ]
  in
  Json.Assoc
    [
      ("by", str (if g.Graph.by_phase then "phase" else "situation"));
      ("nodes", Json.List (List.map node g.Graph.nodes));
      ("edges", Json.List (List.map edge g.Graph.edges));
    ]

(* --- derive ---------------------------------------------------------------- *)

let sort_name = function
  | Rules.Situation -> "situation"
  | Rules.Edge -> "edge"
  | Rules.Entity t -> t

let derive_rows (t : Derive_table.t) (rel : string) (tuples : int array list) :
    Json.t =
  let columns =
    match Derive_answers.sorts_of t rel with
    | Some ss -> strs (List.map sort_name ss)
    | None -> Json.List []
  in
  Json.Assoc
    [
      ("relation", str rel);
      ("columns", columns);
      ( "rows",
        Json.List
          (List.map (fun tup -> strs (Derive_answers.row t rel tup)) tuples) );
    ]

(* A derivation tree with [Report_derive]'s three leaf kinds: a fact, a ground
   guard, and a completed-stratum absence. *)
let rec why_node (t : Derive_table.t) (id : Rules.fact_id) : Json.t =
  let fact =
    match Derive_answers.fact t id with
    | Some f ->
        strs (f.Rules.rel :: Derive_answers.row t f.Rules.rel f.Rules.args)
    | None -> Json.List []
  in
  let premises =
    match Derive_answers.derivation t id with
    | None -> Json.List []
    | Some d -> Json.List (List.map (why_premise t) d.Rules.premises)
  in
  Json.Assoc [ ("fact", fact); ("premises", premises) ]

and why_premise (t : Derive_table.t) (p : Rules.premise) : Json.t =
  match p with
  | Rules.Premise_fact id -> why_node t id
  | Rules.Premise_guard g ->
      Json.Assoc [ ("guard", str (Report_derive.guard g)) ]
  | Rules.Premise_absent (rel, args) ->
      Json.Assoc [ ("absent", strs (rel :: Derive_answers.row t rel args)) ]

let derive_why (t : Derive_table.t) (rel : string) (args : string list) : Json.t
    =
  match Derive_answers.fact_id t rel args with
  | None ->
      Json.Assoc [ ("fact", strs (rel :: args)); ("derived", Json.Bool false) ]
  | Some id -> (
      match why_node t id with
      | Json.Assoc kvs -> Json.Assoc (kvs @ [ ("derived", Json.Bool true) ])
      | j -> j)
