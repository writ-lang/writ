(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Reading answers out of a [Derive_table.t]: what a relation's columns are, the
   rows matching a bound query, and the identity of one ground fact. Split from
   derive_table.ml at the seam between MAINTAINING the store — interning,
   tables, insert/merge/probe — and INTERROGATING it. The two have different
   readers: the store is where the fixpoint's cost lives, this is where the
   command line's questions land. Both sides use the same [probe], which is the
   point: a bound query is not a second traversal.

   No I/O; every function returns values. How a row is printed is
   [Report_derive]'s business, and whether an answer is worth exit 2 is the
   CLI's. *)

open Writ_data

(* ── Answers ─────────────────────────────────────────────────────────────── *)

let sorts_of t rel : Rules.sort list option =
  Option.map
    (fun st -> Array.to_list st.Derive_table.col)
    (Hashtbl.find_opt t.Derive_table.rels rel)

let relations t : string list =
  List.sort compare
    (Hashtbl.fold (fun k _ acc -> k :: acc) t.Derive_table.rels [])

(* A bound query is the SAME fixpoint plus a filter, and the filter is the same
   probe the join uses — symmetric in argument position, because the per-column
   indexes are. That is what makes §2's "backward analysis is free" true rather
   than aspirational: [(reach X 2)] is not a separate backward traversal, it is
   [(reach S T)] answered through column 2's index. Rows come back in a
   deterministic order; how they are printed is the caller's business. *)
(* [Error (i, sort)] — argument [i] is a constant that column [i], of that sort,
   can never hold: an atom where a state index belongs, an entity name no roster
   has, a transition the model does not declare. Reported rather than folded
   into an empty answer, because the two mean opposite things to the asker. A
   relation with no matching rows is an answer (§4 makes it exit 0); a constant
   that cannot appear is a mis-asked question, and answering "0 rows" leaves the
   author with no way to tell which they got. The .rules file type rejects the
   same mistake at read time with a position, so a query that let it through was
   the looser of the two doors into one engine. *)
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

(* [None] is a LEAF, not a missing entry (§7): an extensional fact read off the
   space is derived from nothing and has no tree beneath it. *)
let derivation t (id : Rules.fact_id) : Rules.derivation option =
  Hashtbl.find_opt t.Derive_table.derivs id
