(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* [writ compare OLD NEW [--map M]] — every equation and property preserved,
   LOST or gained across an amendment (kernel §17, design D5). Properties come
   from OLD's claims, checked on both models, n/a counting as not-pass
   (§16.1); equations match by name and meaning, and one that holds in OLD
   but is violated in NEW is LOST, with NEW's route to the violation. The map is a literal atom
   rename, so an unmapped rename reports LOST (design M2, intended). *)

(* --- the literal atom-rename transform (map application) -------------------- *)

let rename_atom (mp : (string * string) list) (a : string) : string =
  match List.assoc_opt a mp with Some b -> b | None -> a

let rename_path (mp : (string * string) list) (p : Value.path) : Value.path =
  { root = rename_atom mp p.root; steps = List.map (rename_atom mp) p.steps }

let rec map_guard (mp : (string * string) list) (g : Model.guard) : Model.guard
    =
  match g with
  | Model.And gs -> Model.And (List.map (map_guard mp) gs)
  | Model.Or gs -> Model.Or (List.map (map_guard mp) gs)
  | Model.Not g -> Model.Not (map_guard mp g)
  | Model.Is (p, Model.Chain q) ->
      Model.Is (rename_path mp p, Model.Chain (rename_path mp q))
  | Model.Is (p, (Model.Lit _ as v)) -> Model.Is (rename_path mp p, v)
  | Model.Defined p -> Model.Defined (rename_path mp p)
  | Model.Some_ (x, ty, g) -> Model.Some_ (x, rename_atom mp ty, map_guard mp g)

(* --- classification -------------------------------------------------------- *)

(* A rendered line: name, status word, and — for a LOST property, or a law
   NEW violates — NEW's witness route. *)
type row = { name : string; status : string; witness : string list option }

let eqs_of (sp : Space.t) : Schema.equation list =
  sp.Space.ctx.State.schema.Schema.equations

let equation_rows (mp : (string * string) list) (old_sp : Space.t)
    (new_sp : Space.t) : row list =
  let old_eqs = eqs_of old_sp and new_eqs = eqs_of new_sp in
  let same_meaning (oe : Schema.equation) (ne : Schema.equation) : bool =
    Guard.equal (map_guard mp oe.Schema.body) ne.Schema.body
  in
  (* The shortest route to a reachable violation of the law named [n], if any. *)
  let violated (sp : Space.t) (n : string) : string list option =
    List.find_map
      (fun (l : Observe.law) ->
        if l.Observe.name = n then Option.map snd l.Observe.violation else None)
      (Observe.laws sp)
  in
  let preserved_or_lost (oe : Schema.equation) : row =
    match
      List.find_opt (fun (ne : Schema.equation) -> ne.name = oe.name) new_eqs
    with
    | Some ne when same_meaning oe ne -> (
        (* Declared alike is not enough: a law that no reachable situation of
           OLD breaks, and one of NEW's does, is a guarantee lost — the same
           as a property that stops holding. *)
        match (violated old_sp oe.name, violated new_sp ne.name) with
        | None, Some route ->
            let witness = if route = [] then None else Some route in
            { name = oe.name; status = "LOST"; witness }
        | _ -> { name = oe.name; status = "preserved"; witness = None })
    | _ -> { name = oe.name; status = "LOST"; witness = None }
  in
  let gained (ne : Schema.equation) : row option =
    if List.exists (fun (oe : Schema.equation) -> oe.name = ne.name) old_eqs
    then None
    else Some { name = ne.name; status = "gained"; witness = None }
  in
  List.map preserved_or_lost old_eqs @ List.filter_map gained new_eqs

let is_pass : Checker.outcome -> bool = function
  | Checker.Holds _ -> true
  | Checker.Fails _ | Checker.Not_applicable _ -> false

let property_rows (mp : (string * string) list) (old_sp : Space.t)
    (new_sp : Space.t) (claims : Claims.t) : row list =
  let classify (p : Claims.property) : row option =
    let old_oc = Checker.check old_sp p in
    let p' = { p with formula = map_guard mp p.formula } in
    let new_oc = Checker.check new_sp p' in
    match (is_pass old_oc, is_pass new_oc) with
    | true, true -> Some { name = p.name; status = "preserved"; witness = None }
    | true, false ->
        let route =
          match new_oc with Checker.Fails { route; _ } -> route | _ -> []
        in
        let witness = if route = [] then None else Some route in
        Some { name = p.name; status = "LOST"; witness }
    | false, true -> Some { name = p.name; status = "gained"; witness = None }
    | false, false -> None
  in
  List.filter_map classify claims.Claims.props

(* --- §17 rendering (design §2) --------------------------------------------- *)

let pad (s : string) (w : int) : string =
  s ^ String.make (max 0 (w - String.length s)) ' '

let inline_route (route : string list) : string =
  String.concat " "
    (List.mapi (fun i m -> string_of_int (i + 1) ^ ". " ^ m) route)

(* Labels are 11 wide plus two spaces, so items align at column 13; status
   words are padded to "preserved" so a trailing [witness:] aligns. *)
let label_w = 11
let indent = String.make (label_w + 2) ' '

let render_row (name_w : int) (r : row) : string =
  let status =
    match r.witness with
    | None -> r.status
    | Some route -> pad r.status 9 ^ " witness: " ^ inline_route route
  in
  pad r.name name_w ^ "  " ^ status

let render_section (label : string) (rows : row list) (name_w : int) : string =
  match rows with
  | [] -> label
  | first :: rest ->
      let head = pad label label_w ^ "  " ^ render_row name_w first in
      let cont = List.map (fun r -> indent ^ render_row name_w r) rest in
      String.concat "\n" (head :: cont)

let run (old_sp : Space.t) (new_sp : Space.t) (claims : Claims.t)
    (mp : (string * string) list) : string * bool =
  let eq_rows = equation_rows mp old_sp new_sp in
  let prop_rows = property_rows mp old_sp new_sp claims in
  let name_w =
    List.fold_left
      (fun w r -> max w (String.length r.name))
      0 (eq_rows @ prop_rows)
  in
  let report =
    render_section "equations:" eq_rows name_w
    ^ "\n"
    ^ render_section "properties:" prop_rows name_w
  in
  let any_lost =
    List.exists (fun r -> r.status = "LOST") (eq_rows @ prop_rows)
  in
  (report, any_lost)
