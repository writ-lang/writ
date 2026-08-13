(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The functor to Par(FinSet): the rosters (a finite set per type) and the
   valuation (the cell each mutable arrow takes at each source entity). *)

type roster = { ty : string; entities : string list }
type cellref = { arrow : string; src : string }

type t = {
  name : string;
  schema : string;
  rosters : roster list;
  valuation : (cellref * Value.cell) list;
}

(* Every entity belongs to exactly one type (kernel §4); return that type. *)
let type_of_entity (i : t) (e : string) : string option =
  let rec go = function
    | [] -> None
    | (r : roster) :: rest ->
        if List.mem e r.entities then Some r.ty else go rest
  in
  go i.rosters

(* The roster of an open type — flattened across any rosters naming it. *)
let entities_of_type (i : t) (ty : string) : string list =
  List.concat_map
    (fun (r : roster) -> if r.ty = ty then r.entities else [])
    i.rosters
