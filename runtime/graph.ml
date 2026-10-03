(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* The state space, drawn: situations and the moves between them (`writ
   control` draws the move graph instead). By default it is the phase quotient
   ([Space.phases]), which is acyclic and shows which steps are one-way; the
   raw space is available under [cap]. Pure: the CLI picks formats and prints. *)

type node = {
  id : int;  (** a phase's representative situation, or a situation *)
  size : int;  (** situations in the phase; 1 in situation mode *)
  initial : bool;
  final : bool;  (** nothing leads out: a terminal phase, or a dead end *)
  gaps : string list;  (** gap messages fired from inside *)
}

type edge = { src : int; dst : int; moves : string list }

type t = {
  by_phase : bool;
  nodes : node list;
  edges : edge list;
  lit_nodes : int list;  (** a witness's path, if one was asked for *)
  lit_edges : (int * int) list;
}

let cap = 200

(* The distinct move names crossing each (src, dst) pair, first-seen order. *)
let gather (pairs : (int * int * string) list) : edge list =
  let tbl = Hashtbl.create 64 in
  let order = ref [] in
  List.iter
    (fun (s, d, m) ->
      match Hashtbl.find_opt tbl (s, d) with
      | None ->
          Hashtbl.replace tbl (s, d) [ m ];
          order := (s, d) :: !order
      | Some ms ->
          if not (List.mem m ms) then Hashtbl.replace tbl (s, d) (m :: ms))
    pairs;
  List.rev_map
    (fun (s, d) ->
      { src = s; dst = d; moves = List.rev (Hashtbl.find tbl (s, d)) })
    !order

let index (sp : Space.t) (s : State.t) : int option =
  State.M.find_opt s sp.Space.index

(* Gap messages by source situation index. *)
let gaps_at (sp : Space.t) : (int * string) list =
  List.filter_map
    (fun (e : Space.edge) ->
      match (e.Space.dst, index sp e.Space.src) with
      | `Gap msg, Some i -> Some (i, msg)
      | _ -> None)
    sp.Space.edges

let phases (sp : Space.t) : t =
  let comp, steps = Space.phases sp in
  let n = Array.length sp.Space.states in
  let size = Array.make n 0 in
  Array.iter (fun r -> size.(r) <- size.(r) + 1) comp;
  let gaps = gaps_at sp in
  let has_step = List.map fst steps in
  let nodes =
    List.filter_map
      (fun i ->
        if comp.(i) <> i then None
        else
          Some
            {
              id = i;
              size = size.(i);
              initial = comp.(0) = i;
              final = not (List.mem i has_step);
              gaps =
                List.sort_uniq compare
                  (List.filter_map
                     (fun (s, msg) -> if comp.(s) = i then Some msg else None)
                     gaps);
            })
      (List.init n (fun i -> i))
  in
  let crossings =
    List.filter_map
      (fun (e : Space.edge) ->
        match e.Space.dst with
        | `To d -> (
            match (index sp e.Space.src, index sp d) with
            | Some s, Some t when comp.(s) <> comp.(t) ->
                Some (comp.(s), comp.(t), e.Space.via)
            | _ -> None)
        | `Gap _ -> None)
      sp.Space.edges
  in
  {
    by_phase = true;
    nodes;
    edges = gather crossings;
    lit_nodes = [];
    lit_edges = [];
  }

let states (sp : Space.t) : t =
  let n = Array.length sp.Space.states in
  let succ = Space.succs sp in
  let gaps = gaps_at sp in
  let nodes =
    List.init n (fun i ->
        {
          id = i;
          size = 1;
          initial = i = 0;
          final = succ.(i) = [];
          gaps =
            List.filter_map (fun (s, m) -> if s = i then Some m else None) gaps;
        })
  in
  let moves =
    List.filter_map
      (fun (e : Space.edge) ->
        match e.Space.dst with
        | `To d -> (
            match (index sp e.Space.src, index sp d) with
            | Some s, Some t -> Some (s, t, e.Space.via)
            | _ -> None)
        | `Gap _ -> None)
      sp.Space.edges
  in
  {
    by_phase = false;
    nodes;
    edges = gather moves;
    lit_nodes = [];
    lit_edges = [];
  }

(* Light a route's nodes and edges. In the phase picture, steps inside one
   phase collapse to the node and only the crossings light. *)
let light (sp : Space.t) (g : t) (route : string list) : t =
  let landings = 0 :: Route.walk sp route in
  let node_of =
    if g.by_phase then
      let comp, _ = Space.phases sp in
      fun i -> comp.(i)
    else fun i -> i
  in
  let path = List.map node_of landings in
  let rec pairs = function
    | a :: (b :: _ as rest) -> (if a <> b then [ (a, b) ] else []) @ pairs rest
    | _ -> []
  in
  { g with lit_nodes = List.sort_uniq compare path; lit_edges = pairs path }

(* --- renderers -------------------------------------------------------------- *)

let label (n : node) : string =
  let head = "#" ^ string_of_int n.id in
  let size = if n.size > 1 then " (" ^ string_of_int n.size ^ ")" else "" in
  let start = if n.initial then "start " else "" in
  start ^ head ^ size

let d2_escape s = String.concat "\\\"" (String.split_on_char '"' s)

let to_d2 (g : t) : string =
  let node (n : node) =
    let id = "s" ^ string_of_int n.id in
    let lines = [ id ^ ": \"" ^ d2_escape (label n) ^ "\"" ] in
    let lines =
      if n.final then lines @ [ id ^ ".style.double-border: true" ] else lines
    in
    let lines =
      if n.initial then lines @ [ id ^ ".style.bold: true" ] else lines
    in
    let lines =
      if List.mem n.id g.lit_nodes then lines @ [ id ^ ".class: witness" ]
      else lines
    in
    let gaps =
      List.mapi
        (fun k msg ->
          let gid = id ^ "-gap" ^ string_of_int k in
          gid ^ ": \"" ^ d2_escape msg ^ "\"\n" ^ gid
          ^ ".style.stroke-dash: 3\n" ^ id ^ " -> " ^ gid
          ^ ": gap {style.stroke-dash: 3}")
        n.gaps
    in
    String.concat "\n" (lines @ gaps)
  in
  let edge (e : edge) =
    let line =
      "s" ^ string_of_int e.src ^ " -> s" ^ string_of_int e.dst ^ ": \""
      ^ d2_escape (String.concat ", " e.moves)
      ^ "\""
    in
    if List.mem (e.src, e.dst) g.lit_edges then line ^ " {class: witness}"
    else line
  in
  String.concat "\n"
    ([
       "vars: { d2-config: { layout-engine: elk } }";
       "direction: right";
       "classes: { witness: { style.stroke: \"#d20f39\"; style.stroke-width: 3 \
        } }";
     ]
    @ List.map node g.nodes @ List.map edge g.edges)

let dot_escape s = String.concat "\\\"" (String.split_on_char '"' s)

let to_dot (g : t) : string =
  let node (n : node) =
    let id = "s" ^ string_of_int n.id in
    let attrs = [ "label=\"" ^ dot_escape (label n) ^ "\"" ] in
    let attrs = if n.final then attrs @ [ "peripheries=2" ] else attrs in
    let attrs = if n.initial then attrs @ [ "style=bold" ] else attrs in
    let attrs =
      if List.mem n.id g.lit_nodes then
        attrs @ [ "color=\"#d20f39\""; "penwidth=3" ]
      else attrs
    in
    let line = "  " ^ id ^ " [" ^ String.concat ", " attrs ^ "];" in
    let gaps =
      List.mapi
        (fun k msg ->
          let gid = id ^ "_gap" ^ string_of_int k in
          "  " ^ gid ^ " [label=\"" ^ dot_escape msg ^ "\", style=dashed];\n  "
          ^ id ^ " -> " ^ gid ^ " [label=\"gap\", style=dashed];")
        n.gaps
    in
    String.concat "\n" (line :: gaps)
  in
  let edge (e : edge) =
    let attrs =
      [ "label=\"" ^ dot_escape (String.concat ", " e.moves) ^ "\"" ]
    in
    let attrs =
      if List.mem (e.src, e.dst) g.lit_edges then
        attrs @ [ "color=\"#d20f39\""; "penwidth=3" ]
      else attrs
    in
    "  s" ^ string_of_int e.src ^ " -> s" ^ string_of_int e.dst ^ " ["
    ^ String.concat ", " attrs ^ "];"
  in
  String.concat "\n"
    ([ "digraph writ {"; "  rankdir=LR;" ]
    @ List.map node g.nodes @ List.map edge g.edges @ [ "}" ])
