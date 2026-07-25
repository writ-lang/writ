(* The state representation (kernel §2): the model is split once into an
   immutable context and a compact mutable state vector. The context holds the
   schema, the fixed rosters, the fixed-arrow valuation, and a layout — the
   canonical ordered array of mutable cells, each with its finite legal-fill
   domain. A state is just the [Value.cell array] aligned to that layout, so it
   is small, structurally comparable, and keys a [Map]. *)

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

(* Total order on states — the array of cells, compared cell-wise (Value). *)
let compare (a : t) (b : t) : int = Value.compare_cells a b

module M = Map.Make (struct
  type nonrec t = t

  let compare = compare
end)

(* The source entities of a type: an enumerated type's own values, or an open
   type's roster. These are the entities an arrow out of that type applies to. *)
let sources (schema : Schema.t) (inst : Instance.t) (ty : string) : string list
    =
  match Schema.type_of schema ty with
  | Some { flavor = Enumerated vs; _ } -> vs
  | Some { flavor = Open; _ } -> Instance.entities_of_type inst ty
  | None -> []

(* A mutable cell's finite domain: the legal fills for the arrow's codomain
   (enumerated values, or the roster of an open cod), plus [Vacant] iff the
   arrow is vacatable. *)
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

(* Validate the instance against the schema and split the model into an
   immutable [ctx] and the initial state vector (kernel §2, §4). Fixed arrows
   are hoisted into [ctx.fixed]; mutable arrows form the layout. Every fixed
   cell must be set; an unset mutable cell defaults to [Vacant] iff vacatable,
   else it is an error; a value outside the cell's domain is an error. *)
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
  (* [mutables] accumulates (cellref, domain, initial) reversed; [fixeds] the
     (cellref, cell) pairs hoisted into [ctx.fixed]. *)
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
      let fixed_list = !fixeds in
      let fixed cr =
        match List.assoc_opt cr fixed_list with
        | Some v -> v
        | None -> Value.Vacant
      in
      Ok ({ schema; layout; fixed; rosters = inst.Instance.rosters }, init)

(* The index of a mutable cell in the layout (hence in the state vector), or
   [None] for a fixed/unknown cell. The single home for the cellref→index scan
   that both [get] and the engine's writes rely on. *)
let index_of (ctx : ctx) (cr : Instance.cellref) : int option =
  let cells = ctx.layout.cells in
  let n = Array.length cells in
  let rec go i =
    if i >= n then None else if cells.(i) = cr then Some i else go (i + 1)
  in
  go 0

(* Read a cell by reference: a mutable cell from the state vector, a fixed cell
   from the hoisted valuation. *)
let get (ctx : ctx) (st : t) (cr : Instance.cellref) : Value.cell =
  match index_of ctx cr with Some i -> st.(i) | None -> ctx.fixed cr

(* Functional update: the new state shares nothing mutable with the old. *)
let set (st : t) (i : int) (v : Value.cell) : t =
  let st' = Array.copy st in
  st'.(i) <- v;
  st'
