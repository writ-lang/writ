open Pol_data

(* [pol control] — render a model's move list as a re-parseable instance of the
   standard library's [quiver] schema (kernel §17, design D6): one [edge] entity
   per transition, every [src]/[tgt] a self-loop on a single [node] (§12.3).
   Re-parsing the emitted string against the [quiver] schema validates it.

   Engine layer: this is a pure string builder — no I/O and no front end. The
   printing lives in [tooling/cli/cmd_control.ml]; here we only consume the core
   [Model]. *)

(* Edge-entity names, one per transition in order: a named transition keeps its
   name; an UNNAMED transition at 1-based position [i] becomes [move-<i>].

   §7 — entities share one namespace, so the synthesised names must not collide
   with any explicit transition name or with each other. We append [_] to a
   [move-<i>] candidate until it is fresh w.r.t. every explicit name and every
   name already assigned, so a real transition literally named [move-1] never
   shadows a synthesised one. *)
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

(* The single node's name, made fresh w.r.t. every edge name the same way (a
   transition literally named [n0] must not break the round-trip). *)
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
  (* The leading [(load "stdlib.pol")] makes the output a self-contained
     library, so [(of quiver)] resolves when the string is re-parsed. *)
  add "(load \"stdlib.pol\")\n\n";
  add ("(instance " ^ name ^ "-control (of quiver)\n");
  add ("  (node " ^ node ^ ")\n");
  let joined f = String.concat "" (List.map f edges) in
  add ("  (edge" ^ joined (fun e -> " " ^ e) ^ ")\n");
  let loop e = " (" ^ e ^ " " ^ node ^ ")" in
  add ("  (src" ^ joined loop ^ ")\n");
  add ("  (tgt" ^ joined loop ^ "))\n");
  Buffer.contents buf
