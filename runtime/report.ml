(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Pol_data

(* The §15/§16 report tokens, as pure strings (fold F7: no [Printf]/[Format]/
   [print_*] — the CLI does the printing). Spacing is literal and pinned by the
   spec: the [—] in a gap line is U+2014, the [∅] in a stuck cell is U+2205.
   A formatting module only: it computes nothing the space/checker/observe do
   not. *)

(* --- §15 build report ------------------------------------------------------ *)

let size (sp : Space.t) : string =
  "states: "
  ^ string_of_int (Array.length sp.Space.states)
  ^ "   edges: "
  ^ string_of_int (List.length sp.Space.edges)

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

let laws (sp : Space.t) : string =
  let one (l : Observe.law) =
    let lines = ref [ "equation " ^ l.name ] in
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
        lines :=
          ("  violated in " ^ string_of_int n
         ^ " reachable situations   witness: " ^ inline_route route)
          :: !lines);
    String.concat "\n" (List.rev !lines)
  in
  String.concat "\n" (List.map one (Observe.laws sp))

let build (sp : Space.t) : string =
  let parts = [ size sp; gaps sp; dead_ends sp ] in
  let lw = laws sp in
  String.concat "\n" (if lw = "" then parts else parts @ [ lw ])

(* --- §16.1 properties ------------------------------------------------------ *)

(* A situation's mutable cells in layout order, [SRC.ARROW=VALUE] with [∅]
   (U+2205) for a vacant cell. Named apart from [stuck_line] because it is what
   a situation IS, and two things want to print it: a failing property, and
   `pol show` answering "what is situation 17" for a caller holding a row from
   `pol derive`. One layout, so the two cannot drift. *)
let cells_line (sp : Space.t) (s : State.t) : string =
  let cells = sp.Space.ctx.State.layout.cells in
  let cell i (cr : Instance.cellref) =
    let v = match s.(i) with Value.Filled x -> x | Value.Vacant -> "∅" in
    cr.Instance.src ^ "." ^ cr.Instance.arrow ^ "=" ^ v
  in
  "(" ^ String.concat " " (Array.to_list (Array.mapi cell cells)) ^ ")"

let stuck_line (sp : Space.t) (s : State.t) : string =
  "  stuck at: " ^ cells_line sp s

(* [  witness:  1. m1] then moves 2..n indented under the first move. *)
let witness_block (route : string list) : string =
  match route with
  | [] -> ""
  | first :: rest ->
      let indent = String.make (String.length "  witness:  ") ' ' in
      String.concat "\n"
        (("  witness:  1. " ^ first)
        :: List.mapi (fun i m -> indent ^ string_of_int (i + 2) ^ ". " ^ m) rest
        )

let outcome (sp : Space.t) (prop : Claims.property) (oc : Checker.outcome) :
    string =
  (* A fairness assumption is printed with the verdict, both ways, so that a
     verdict cannot be quoted without it. "This protocol always terminates" and
     "this protocol always terminates unless the network refuses to deliver for
     ever" are different claims, and only one of them was checked. *)
  let assumed =
    match prop.modality with
    | Claims.Inevitable (_ :: _ as ms) ->
        [ "  assuming fair: " ^ String.concat ", " ms ]
    | _ -> []
  in
  match oc with
  | Checker.Holds route ->
      (* A holding [possible] carries its solution path; show it as the witness
         (spec Appendix C). The other three hold with no route. *)
      String.concat "\n"
        ((("holds  " ^ prop.name) :: assumed)
        @ match route with [] -> [] | _ -> [ witness_block route ])
  | Checker.Not_applicable _ -> "n/a  " ^ prop.name
  | Checker.Fails { route; stuck } ->
      let parts = ref (List.rev (("fails  " ^ prop.name) :: assumed)) in
      (match stuck with
      | Some s -> parts := stuck_line sp s :: !parts
      | None -> ());
      (match route with
      | [] -> ()
      | _ -> parts := witness_block route :: !parts);
      String.concat "\n" (List.rev !parts)

(* --- §16.3 acknowledgments ------------------------------------------------- *)

let acks (unadmitted : (string * string) list) (stale : (string * string) list)
    : string =
  let u (tr, eq) = "unadmitted  " ^ tr ^ " may break " ^ eq in
  let s (tr, eq) = "stale  " ^ tr ^ " cannot break " ^ eq in
  String.concat "\n" (List.map u unadmitted @ List.map s stale)

(* --- §16.2 queries --------------------------------------------------------- *)

let query_rows (q : Claims.query) (idx : int)
    (rows : (string * string) list list) : string =
  let header = q.Claims.name ^ "  (at state " ^ string_of_int idx ^ ")" in
  let row r =
    "  " ^ String.concat ", " (List.map (fun (k, v) -> k ^ " = " ^ v) r)
  in
  String.concat "\n" (header :: List.map row rows)

(* --- one situation, addressed by index ------------------------------------- *)

(* What `pol derive` answers with is a state index, and an index is not an
   answer a reader can act on. This renders one: its cells, the fewest moves to
   it, and where it can go. The numbering is the space's own, so it is the same
   17 that `pol query --at` addresses and that a rules row printed.

   The three lines are chosen to close the loop a derivation opens. A `blocked`
   row wants the cells (what the situation is), the route (how it got there) and
   the moves out (whether it really is stuck) — and a reader who had to run
   three more commands to get those had been given a number rather than an
   answer. *)
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
  (* Every edge out, gap edges included and marked: a situation whose only exit
     is a gap is NOT a dead end (§15), and a reader looking at one should be
     able to see the difference rather than infer it. *)
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
