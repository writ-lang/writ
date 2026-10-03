(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Reading answers out of a [Derive_table.t]: a relation's columns, the rows
   matching a bound query, and one ground fact's identity. No I/O; printing is
   [Report_derive]'s, exit codes the CLI's. *)

open Writ_data

(* ── Answers ─────────────────────────────────────────────────────────────── *)

let sorts_of t rel : Rules.sort list option =
  Option.map
    (fun st -> Array.to_list st.Derive_table.col)
    (Hashtbl.find_opt t.Derive_table.rels rel)

let relations t : string list =
  List.sort compare
    (Hashtbl.fold (fun k _ acc -> k :: acc) t.Derive_table.rels [])

(* A bound query through the join's own [probe], sorted. [Error (i, sort)]
   when constant [i] can never appear in its column: a mis-asked question,
   distinct from an empty answer (exit 0, §4). *)
let query t rel (args : string option list) :
    (int array list, int * Rules.sort) result option =
  match Hashtbl.find_opt t.Derive_table.rels rel with
  | None -> None
  | Some st ->
      if List.length args <> st.Derive_table.arity then None
      else begin
        let want = Array.make st.Derive_table.arity None in
        let bad = ref None in
        List.iteri
          (fun i a ->
            match a with
            | None -> ()
            | Some s -> (
                match Derive_table.code t st.Derive_table.col.(i) s with
                | Some c -> want.(i) <- Some c
                | None ->
                    if !bad = None then bad := Some (i, st.Derive_table.col.(i))
                ))
          args;
        Some
          (match !bad with
          | Some e -> Error e
          | None ->
              Ok (List.sort compare (Derive_table.probe st ~delta:false want)))
      end

let row t rel (tup : int array) : string list =
  match Hashtbl.find_opt t.Derive_table.rels rel with
  | None -> []
  | Some st ->
      Array.to_list
        (Array.mapi
           (fun i c -> Derive_table.decode t st.Derive_table.col.(i) c)
           tup)

let fact_id t rel (args : string list) : Rules.fact_id option =
  match Hashtbl.find_opt t.Derive_table.rels rel with
  | None -> None
  | Some st ->
      if List.length args <> st.Derive_table.arity then None
      else begin
        let tup = Array.make st.Derive_table.arity 0 in
        let live = ref true in
        List.iteri
          (fun i s ->
            match Derive_table.code t st.Derive_table.col.(i) s with
            | Some c -> tup.(i) <- c
            | None -> live := false)
          args;
        if !live then Hashtbl.find_opt st.Derive_table.ids tup else None
      end

let fact t (id : Rules.fact_id) : Rules.fact option =
  Hashtbl.find_opt t.Derive_table.by_id id

(* [None] is a leaf (§7): an extensional fact has no tree beneath it. *)
let derivation t (id : Rules.fact_id) : Rules.derivation option =
  Hashtbl.find_opt t.Derive_table.derivs id
