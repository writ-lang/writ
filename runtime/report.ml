(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* The §15/§16 report, as pure strings; the CLI prints them. Spacing is pinned
   by the spec: the [—] in a gap line is U+2014, the [∅] in a vacant cell
   U+2205. Formatting only — nothing is computed here. *)

(* --- §15 build report ------------------------------------------------------ *)

let size (sp : Space.t) : string =
  "states: "
  ^ string_of_int (Array.length sp.Space.states)
  ^ "   edges: "
  ^ string_of_int (List.length sp.Space.edges)

(* Committing when no situation can return to itself, reversible otherwise
   (docs/tractability.md §6). *)
let regime (sp : Space.t) : string =
  match Space.recurrent_count sp with
  | 0 -> "regime: committing — no move can be undone"
  | k ->
      "regime: reversible — " ^ string_of_int k ^ " of "
      ^ string_of_int (Array.length sp.Space.states)
      ^ " situations lie on cycles"

let gaps (sp : Space.t) : string =
  match Space.reachable_gaps sp with
  | [] -> "gaps: none"
  | gs ->
      let head = "gaps: " ^ string_of_int (List.length gs) in
      let line (via, msg, d) =
        "  " ^ via ^ " — \"" ^ msg ^ "\" (min " ^ string_of_int d ^ " moves)"
      in
      String.concat "\n" (head :: List.map line gs)

let dead_ends (sp : Space.t) : string =
  match Space.dead_ends sp with
  | [] -> "dead ends: none"
  | des ->
      let head = "dead ends: " ^ string_of_int (List.length des) in
      let line (_, route) =
        "  reached by: "
        ^ match route with [] -> "(initial)" | r -> String.concat ", " r
      in
      String.concat "\n" (head :: List.map line des)

(* Inline numbered route: [1. m1 2. m2 …] on one line. *)
let inline_route (route : string list) : string =
  String.concat " "
    (List.mapi (fun i m -> string_of_int (i + 1) ^ ". " ^ m) route)

(* A tool's note of where a move or law came from (docs/bridges.md); absent
   for anything written by hand. *)
let origin_tag = function Some o -> "   [" ^ o ^ "]" | None -> ""

let move_origin (sp : Space.t) (mv : string) : string option =
  List.find_map
    (fun (t : Model.transition) ->
      if t.Model.name = Some mv then t.Model.origin else None)
    sp.Space.transitions

let law_origin (sp : Space.t) (name : string) : string option =
  List.find_map
    (fun (e : Schema.equation) ->
      if e.Schema.name = name then e.Schema.origin else None)
    sp.Space.ctx.State.schema.Schema.equations

let laws (sp : Space.t) : string =
  let one (l : Observe.law) =
    let lines =
      ref [ "equation " ^ l.name ^ origin_tag (law_origin sp l.name) ]
    in
    (match l.breakers with
    | [] -> ()
    | bs ->
        lines :=
          ("  can be broken by: " ^ String.concat ", " bs
         ^ "   (acknowledge in claims)")
          :: !lines);
    (match l.violation with
    | None -> ()
    | Some (n, route) ->
        let landing =
          match List.rev (Route.walk sp route) with
          | k :: _ -> " → #" ^ string_of_int k
          | [] -> ""
        in
        lines :=
          ("  violated in " ^ string_of_int n
         ^ " reachable situations   witness: " ^ inline_route route ^ landing)
          :: !lines);
    String.concat "\n" (List.rev !lines)
  in
  String.concat "\n" (List.map one (Observe.laws sp))

let build (sp : Space.t) : string =
  let parts = [ size sp; regime sp; gaps sp; dead_ends sp ] in
  let lw = laws sp in
  String.concat "\n" (if lw = "" then parts else parts @ [ lw ])

(* --- §16.1 properties ------------------------------------------------------ *)

(* A situation's mutable cells in layout order, [SRC.ARROW=VALUE], [∅] for
   vacant. Shared by a failing property and `writ show`. *)
let cells_line (sp : Space.t) (s : State.t) : string =
  let cells = sp.Space.ctx.State.layout.cells in
  let cell i (cr : Instance.cellref) =
    let v = match s.(i) with Value.Filled x -> x | Value.Vacant -> "∅" in
    cr.Instance.src ^ "." ^ cr.Instance.arrow ^ "=" ^ v
  in
  "(" ^ String.concat " " (Array.to_list (Array.mapi cell cells)) ^ ")"

(* The index leads so `writ show --at N` can be run on it directly. *)
let stuck_line (sp : Space.t) (s : State.t) : string =
  let idx =
    match State.M.find_opt s sp.Space.index with
    | Some i -> "#" ^ string_of_int i ^ " "
    | None -> ""
  in
  "  stuck at: " ^ idx ^ cells_line sp s

(* What one move did: [SRC.ARROW: before → after], vacant as [∅]. *)
let delta_text ((cell, before, after) : string * string option * string option)
    : string =
  let v = function None -> "∅" | Some x -> x in
  cell ^ ": " ^ v before ^ " → " ^ v after

(* Where a step lands and what it changed; empty when the route cannot be
   replayed. *)
let step_trailer (sp : Space.t) (prev : State.t) (landing : int option) : string
    =
  match landing with
  | None -> ""
  | Some k ->
      let here = sp.Space.states.(k) in
      let changes =
        match Route.deltas sp prev here with
        | [] -> ""
        | ds -> "   " ^ String.concat ", " (List.map delta_text ds)
      in
      "   → #" ^ string_of_int k ^ changes

(* [  witness:  1. m1   → #3   cell: a → b], later moves indented under the
   first. The move name stays right after its number, where scripts look. *)
let witness_block (sp : Space.t) (route : string list) : string =
  let landings = Route.walk sp route in
  let indent = String.make (String.length "  witness:  ") ' ' in
  let width = List.fold_left (fun w m -> max w (String.length m)) 0 route in
  let pad m = m ^ String.make (width - String.length m) ' ' in
  let rec lines i prev moves acc =
    match moves with
    | [] -> List.rev acc
    | m :: rest ->
        let landing = List.nth_opt landings i in
        let head =
          if i = 0 then "  witness:  1. "
          else indent ^ string_of_int (i + 1) ^ ". "
        in
        let shown = if landing = None then m else pad m in
        let line =
          head ^ shown
          ^ step_trailer sp prev landing
          ^ origin_tag (move_origin sp m)
        in
        let next =
          match landing with Some k -> sp.Space.states.(k) | None -> prev
        in
        lines (i + 1) next rest (line :: acc)
  in
  String.concat "\n" (lines 0 sp.Space.initial route [])

let description_line (prop : Claims.property) : string list =
  if prop.Claims.text = "" then [] else [ "  \"" ^ prop.Claims.text ^ "\"" ]

(* --- §16.2 queries --------------------------------------------------------- *)

let query_rows (q : Claims.query) (idx : int)
    (rows : (string * string) list list) : string =
  let header = q.Claims.name ^ "  (at state " ^ string_of_int idx ^ ")" in
  let row r =
    "  " ^ String.concat ", " (List.map (fun (k, v) -> k ^ " = " ^ v) r)
  in
  String.concat "\n" (header :: List.map row rows)

(* The situation a verdict singles out: where a failing [live]/[inevitable] is
   stuck, where a failing [never] is violated, where a holding [possible] is
   satisfied. An empty route means the initial situation. *)
let singled_out (sp : Space.t) (prop : Claims.property) (oc : Checker.outcome) :
    State.t option =
  let end_of route =
    match List.rev (Route.walk sp route) with
    | k :: _ -> Some sp.Space.states.(k)
    | [] -> Some sp.Space.initial
  in
  match (oc, prop.Claims.modality) with
  | Checker.Not_applicable _, _ -> None
  | Checker.Holds route, Claims.Possible -> end_of route
  | Checker.Holds _, _ -> None
  | Checker.Fails { stuck = Some s; _ }, _ -> Some s
  | Checker.Fails { stuck = None; _ }, Claims.Possible -> None
  | Checker.Fails { stuck = None; route }, _ -> end_of route

(* The property's [(show …)] queries, answered at that situation. Undeclared
   names were refused when the claims file was read. *)
let shown_rows ?(queries : Claims.query list = []) (sp : Space.t)
    (prop : Claims.property) (oc : Checker.outcome) :
    (Claims.query * int * (string * string) list list) list =
  match singled_out sp prop oc with
  | None -> []
  | Some st ->
      let idx = State.M.find st sp.Space.index in
      List.filter_map
        (fun name ->
          match
            List.find_opt
              (fun (q : Claims.query) -> q.Claims.name = name)
              queries
          with
          | Some q -> Some (q, idx, Query.run sp q ~at:st ())
          | None -> None)
        prop.Claims.show

let indent_block (s : string) : string =
  String.concat "\n"
    (List.map (fun l -> "  " ^ l) (String.split_on_char '\n' s))

let outcome ?(queries : Claims.query list = []) (sp : Space.t)
    (prop : Claims.property) (oc : Checker.outcome) : string =
  (* The fairness assumption is printed with the verdict so the verdict is
     never quoted without it. *)
  let assumed =
    match prop.modality with
    | Claims.Inevitable (_ :: _ as ms) ->
        [ "  assuming fair: " ^ String.concat ", " ms ]
    | _ -> []
  in
  let described = description_line prop in
  let shown =
    List.map
      (fun (q, idx, rows) -> indent_block (query_rows q idx rows))
      (shown_rows ~queries sp prop oc)
  in
  match oc with
  | Checker.Holds route ->
      (* A holding [possible] shows its solution path as the witness (spec
         Appendix C). *)
      String.concat "\n"
        ((("holds  " ^ prop.name) :: described)
        @ assumed
        @ (match route with [] -> [] | _ -> [ witness_block sp route ])
        @ shown)
  | Checker.Not_applicable _ ->
      String.concat "\n" (("n/a  " ^ prop.name) :: described)
  | Checker.Fails { route; stuck } ->
      let parts =
        ref (List.rev ((("fails  " ^ prop.name) :: described) @ assumed))
      in
      (match stuck with
      | Some s -> parts := stuck_line sp s :: !parts
      | None -> ());
      (match route with
      | [] -> ()
      | _ -> parts := witness_block sp route :: !parts);
      String.concat "\n" (List.rev !parts @ shown)

(* --- §17 fibers ------------------------------------------------------------ *)

(* One line per fiber under a property's verdict. FAILS is capitalised, like
   compare's LOST, because it is what a reader scans for. *)
let fiber_lines (sp : Space.t) (fibers : (Fiber.fiber * Checker.outcome) list) :
    string list =
  let width =
    List.fold_left
      (fun w (f, _) -> max w (String.length (Fiber.label f)))
      0 fibers
  in
  List.map
    (fun (f, oc) ->
      let lab = Fiber.label f in
      let pad = String.make (width - String.length lab) ' ' in
      let head = "  fiber " ^ lab ^ pad ^ "   " in
      match oc with
      | Checker.Holds _ -> head ^ "holds"
      | Checker.Not_applicable _ -> head ^ "n/a"
      | Checker.Fails { route = []; _ } -> head ^ "FAILS"
      | Checker.Fails { route; _ } ->
          let landing =
            match List.rev (Route.walk sp route) with
            | k :: _ -> " → #" ^ string_of_int k
            | [] -> ""
          in
          head ^ "FAILS   witness: " ^ inline_route route ^ landing)
    fibers

(* --- §16.3 acknowledgments ------------------------------------------------- *)

let acks (unadmitted : (string * string) list) (stale : (string * string) list)
    : string =
  let u (tr, eq) = "unadmitted  " ^ tr ^ " may break " ^ eq in
  let s (tr, eq) = "stale  " ^ tr ^ " cannot break " ^ eq in
  String.concat "\n" (List.map u unadmitted @ List.map s stale)

(* --- one situation, addressed by index ------------------------------------- *)

(* One situation by index (the space's own numbering, as `writ derive` and
   `writ query --at` use): its cells, the fewest moves to it, and its moves
   out. *)
let situation (sp : Space.t) (i : int) : string =
  let s = sp.Space.states.(i) in
  let head =
    "situation " ^ string_of_int i ^ " of "
    ^ string_of_int (Array.length sp.Space.states)
    ^ if Space.same s sp.Space.initial then "   (the initial one)" else ""
  in
  let route =
    match Space.shortest_path sp s with
    | [] -> "  route:   none needed — this is where the model starts"
    | first :: rest ->
        let indent = String.make (String.length "  route:   ") ' ' in
        String.concat "\n"
          (("  route:   1. " ^ first)
          :: List.mapi
               (fun k m -> indent ^ string_of_int (k + 2) ^ ". " ^ m)
               rest)
  in
  (* Gap edges are listed and marked: a situation whose only exit is a gap is
     not a dead end (§15). *)
  let out =
    List.filter_map
      (fun (e : Space.edge) ->
        if not (Space.same e.Space.src s) then None
        else
          match e.Space.dst with
          | `To d ->
              Some
                (e.Space.via ^ " → "
                ^ string_of_int (State.M.find d sp.Space.index))
          | `Gap msg -> Some (e.Space.via ^ " → gap: " ^ msg))
      sp.Space.edges
  in
  let moves =
    match out with
    | [] -> "  moves:   none — a dead end"
    | _ -> "  moves:   " ^ String.concat "   " out
  in
  String.concat "\n" [ head; "  cells:   " ^ cells_line sp s; route; moves ]
