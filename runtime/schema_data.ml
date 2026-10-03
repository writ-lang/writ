(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* [writ schema] — a model's schema as a re-parseable instance of the stdlib's
   [olog] schema (kernel §17). Types become [ob], arrows [hom], laws [eqn] by
   name only: the structural §16.4 checks read just [dom] and [cod]. *)

(* Arrow names are scoped to their dom (§7), but entity names share one
   namespace. So each arrow becomes [dom-arrow], with [_] appended until it
   clashes with no type, law or other arrow name, as in [Control]. No dot:
   a dotted atom is a chain (§5.2). *)
let hom_names (s : Schema.t) : (Schema.arrow * string) list =
  let type_names =
    List.map (fun (t : Schema.ty) -> t.Schema.name) s.Schema.types
  in
  let eq_names =
    List.map (fun (e : Schema.equation) -> e.Schema.name) s.Schema.equations
  in
  let taken = ref (s.Schema.name :: (type_names @ eq_names)) in
  let rec fresh cand =
    if List.mem cand !taken then fresh (cand ^ "_") else cand
  in
  List.map
    (fun (a : Schema.arrow) ->
      let n = fresh (a.Schema.dom ^ "-" ^ a.Schema.name) in
      taken := n :: !taken;
      (a, n))
    s.Schema.arrows

let olog (name : string) (s : Schema.t) : string =
  let homs = hom_names s in
  let buf = Buffer.create 512 in
  let add = Buffer.add_string buf in
  (* The [load] makes the output self-contained, so [(of olog)] resolves on
     re-parse. *)
  add "(load \"stdlib.writ\")\n\n";
  add ("(instance " ^ name ^ "-schema olog\n");
  let joined f xs = String.concat "" (List.map f xs) in
  add
    ("  (ob"
    ^ joined (fun (t : Schema.ty) -> " " ^ t.Schema.name) s.Schema.types
    ^ ")\n");
  if s.Schema.equations <> [] then
    add
      ("  (eqn"
      ^ joined
          (fun (e : Schema.equation) -> " " ^ e.Schema.name)
          s.Schema.equations
      ^ ")\n");
  add
    (String.concat "\n"
       (List.map
          (fun ((a : Schema.arrow), n) ->
            "  (hom " ^ n ^ " (dom " ^ a.Schema.dom ^ ") (cod " ^ a.Schema.cod
            ^ "))")
          homs));
  add ")\n";
  Buffer.contents buf
