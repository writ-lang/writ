(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* [writ control] — a model's move list as a re-parseable instance of the
   stdlib's [quiver] schema (kernel §17, design D6): one [edge] entity per
   transition, each a self-loop on a single [node] (§12.3). A pure string
   builder; the CLI prints it. *)

(* One edge name per transition: its own name, or [move-<i>] (1-based) if it
   has none. Entities share one namespace (§7), so a synthesised name gets [_]
   appended until it collides with no explicit or already assigned name. *)
let edge_names (m : Model.t) : string list =
  let explicit =
    List.filter_map (fun (t : Model.transition) -> t.name) m.Model.transitions
  in
  let rec fresh cand assigned =
    if List.mem cand explicit || List.mem cand assigned then
      fresh (cand ^ "_") assigned
    else cand
  in
  let rec go i assigned = function
    | [] -> List.rev assigned
    | (t : Model.transition) :: rest ->
        let nm =
          match t.Model.name with
          | Some n -> n
          | None -> fresh ("move-" ^ string_of_int i) assigned
        in
        go (i + 1) (nm :: assigned) rest
  in
  go 1 [] m.Model.transitions

(* The node's name, made fresh against the edge names the same way. *)
let node_name (edges : string list) : string =
  let rec fresh cand =
    if List.mem cand edges then fresh (cand ^ "_") else cand
  in
  fresh "n0"

let quiver (name : string) (m : Model.t) : string =
  let edges = edge_names m in
  let node = node_name edges in
  let buf = Buffer.create 256 in
  let add = Buffer.add_string buf in
  (* The [load] makes the output self-contained, so [quiver] resolves on
     re-parse. *)
  add "(load \"stdlib.writ\")\n\n";
  add ("(instance " ^ name ^ "-control quiver\n");
  add ("  (node " ^ node ^ ")\n");
  add
    (String.concat "\n"
       (List.map
          (fun e -> "  (edge " ^ e ^ " (src " ^ node ^ ") (tgt " ^ node ^ "))")
          edges));
  add ")\n";
  Buffer.contents buf
