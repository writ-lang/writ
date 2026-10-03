(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* States (kernel §2): an immutable context holds everything fixed, and a
   state is just the mutable cells, as an array aligned to [layout]. *)

type layout = {
  cells : Instance.cellref array;
  domains : Value.cell array array;
}

type ctx = {
  schema : Schema.t;
  layout : layout;
  fixed : Instance.cellref -> Value.cell;
  rosters : Instance.roster list;
}

type t = Value.cell array

let compare (a : t) (b : t) : int = Value.compare_cells a b

module M = Map.Make (struct
  type nonrec t = t

  let compare = compare
end)

(* The entities an arrow out of [ty] applies to: its values or its roster. *)
let sources (schema : Schema.t) (inst : Instance.t) (ty : string) : string list
    =
  match Schema.type_of schema ty with
  | Some { flavor = Enumerated vs; _ } -> vs
  | Some { flavor = Open; _ } -> Instance.entities_of_type inst ty
  | None -> []

(* A mutable cell's legal fills, plus [Vacant] iff the arrow is vacatable. *)
let cell_domain (schema : Schema.t) (inst : Instance.t) (a : Schema.arrow) :
    Value.cell array =
  let base =
    match Schema.type_of schema a.cod with
    | Some { flavor = Enumerated vs; _ } ->
        List.map (fun v -> Value.Filled v) vs
    | Some { flavor = Open; _ } ->
        List.map
          (fun e -> Value.Filled e)
          (Instance.entities_of_type inst a.cod)
    | None -> []
  in
  Array.of_list (if a.vacatable then base @ [ Value.Vacant ] else base)

(* Validate the instance and split it into [ctx] and the initial state (§2,
   §4). Unset cells are [Vacant] if vacatable, else an error. *)
let build_ctx (schema : Schema.t) (inst : Instance.t) : (ctx * t, string) result
    =
  let val_of (cr : Instance.cellref) : Value.cell option =
    let rec go = function
      | [] -> None
      | (c, v) :: rest -> if c = cr then Some v else go rest
    in
    go inst.Instance.valuation
  in
  let error = ref None in
  let mutables = ref [] in
  let fixeds = ref [] in
  let fail msg = if !error = None then error := Some msg in
  List.iter
    (fun (a : Schema.arrow) ->
      List.iter
        (fun src ->
          if !error = None then begin
            let cr = { Instance.arrow = a.name; src } in
            let where = a.dom ^ "." ^ a.name ^ " for " ^ src in
            if a.fixed then
              match val_of cr with
              | Some v -> fixeds := (cr, v) :: !fixeds
              | None -> fail ("fixed cell " ^ where ^ " unset")
            else begin
              let dom = cell_domain schema inst a in
              match val_of cr with
              | None ->
                  if a.vacatable then
                    mutables := (cr, dom, Value.Vacant) :: !mutables
                  else
                    fail
                      ("mutable cell " ^ where
                     ^ " is not vacatable and has no value")
              | Some v ->
                  if Array.exists (Value.equal_cell v) dom then
                    mutables := (cr, dom, v) :: !mutables
                  else fail ("value out of domain for cell " ^ where)
            end
          end)
        (sources schema inst a.dom))
    schema.Schema.arrows;
  match !error with
  | Some e -> Error e
  | None ->
      let cells = List.rev !mutables in
      let layout =
        {
          cells = Array.of_list (List.map (fun (cr, _, _) -> cr) cells);
          domains = Array.of_list (List.map (fun (_, d, _) -> d) cells);
        }
      in
      let init = Array.of_list (List.map (fun (_, _, v) -> v) cells) in
      (* Hashed: every step through a fixed arrow, in every guard and
         situation, reads this. *)
      let fixed_tbl = Hashtbl.create (List.length !fixeds * 2) in
      List.iter (fun (cr, v) -> Hashtbl.replace fixed_tbl cr v) !fixeds;
      let fixed cr =
        match Hashtbl.find_opt fixed_tbl cr with
        | Some v -> v
        | None -> Value.Vacant
      in
      Ok ({ schema; layout; fixed; rosters = inst.Instance.rosters }, init)

(* A mutable cell's index in the state vector; [None] for a fixed or unknown
   cell. *)
let index_of (ctx : ctx) (cr : Instance.cellref) : int option =
  let cells = ctx.layout.cells in
  let n = Array.length cells in
  let rec go i =
    if i >= n then None else if cells.(i) = cr then Some i else go (i + 1)
  in
  go 0

let get (ctx : ctx) (st : t) (cr : Instance.cellref) : Value.cell =
  match index_of ctx cr with Some i -> st.(i) | None -> ctx.fixed cr

(* Copies: states are shared as map keys and must not be mutated. *)
let set (st : t) (i : int) (v : Value.cell) : t =
  let st' = Array.copy st in
  st'.(i) <- v;
  st'
