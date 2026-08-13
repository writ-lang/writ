(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Open documents, keyed by URI: the current text.

   The last-good parse that couples the store to the engine is reintroduced in
   T9, when the server is rewritten to drive [Loader] through an injected
   [resolve]. For now the store simply holds text so the reusable harness
   library ([wire] + [doc]) compiles standalone, with no reference to the engine
   front end. *)

type doc = { text : string }
type t = { tbl : (string, doc) Hashtbl.t }

let create () = { tbl = Hashtbl.create 16 }
let set store uri text = Hashtbl.replace store.tbl uri { text }
let get store uri = Hashtbl.find_opt store.tbl uri
let remove store uri = Hashtbl.remove store.tbl uri
