(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Open documents, keyed by URI: the current text. *)

type doc = { text : string }
type t = { tbl : (string, doc) Hashtbl.t }

let create () = { tbl = Hashtbl.create 16 }
let set store uri text = Hashtbl.replace store.tbl uri { text }
let get store uri = Hashtbl.find_opt store.tbl uri
let remove store uri = Hashtbl.remove store.tbl uri
