(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ control] unit tests: the §17 quiver shape, §7 fresh names, and an
   emitted library that re-parses. *)

open Writ_data
open Writ_syntax
open Writ_runtime

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let contains ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

(* --- construction helpers (a one-switch world) ------------------------------ *)

let path root steps : Value.path = { root; steps }
let is e a v = Model.Is (path e [ a ], Model.Lit v)
let set e a v = Model.Set (path e [ a ], Model.Lit v)

let named n g effs : Model.transition =
  { name = Some n; when_ = g; effects = effs; origin = None }

let anon g effs : Model.transition =
  { name = None; when_ = g; effects = effs; origin = None }

let flip n from_ to_ = named n (is "s" "pos" from_) [ set "s" "pos" to_ ]

let pos_arrow : Schema.arrow =
  { name = "pos"; dom = "sw"; cod = "pos-t"; fixed = false; vacatable = false }

let schema : Schema.t =
  {
    name = "toggle";
    types =
      [
        { name = "pos-t"; flavor = Enumerated [ "down"; "up" ]; arrows = [] };
        { name = "sw"; flavor = Open; arrows = [ pos_arrow ] };
      ];
    arrows = [ pos_arrow ];
    equations = [];
  }

let instance : Instance.t =
  {
    name = "i";
    schema = "toggle";
    rosters = [ { ty = "sw"; entities = [ "s" ] } ];
    valuation = [ ({ arrow = "pos"; src = "s" }, Value.Filled "down") ];
  }

let mk trs : Model.t = { schema; initial = instance; transitions = trs }

let reparses s =
  match Reader.read_string s with Ok _ -> true | Error _ -> false

(* Through §7, not just the reader: a duplicate roster entry reads fine. *)
let reparses_with_fresh_names s =
  match Reader.read_string s with
  | Error _ -> false
  | Ok ds -> Result.is_ok (Names.check ds)

(* --- the quiver shape: one edge per transition, self-loops on one node ------- *)

let () =
  let m =
    mk
      [
        flip "raise" "down" "up";
        flip "lower" "up" "down";
        anon (is "s" "pos" "up") [ set "s" "pos" "down" ];
      ]
  in
  let out = Control.quiver "ctrlfix" m in
  check "control: names its schema positionally"
    (contains ~sub:"-control quiver" out);
  check "control: self-contained via (load \"stdlib.writ\")"
    (contains ~sub:"(load \"stdlib.writ\")" out);
  check "control: instance is NAME-control"
    (contains ~sub:"(instance ctrlfix-control " out);
  check "control: one edge per transition, unnamed -> move-3"
    (contains ~sub:"(edge raise " out
    && contains ~sub:"(edge lower " out
    && contains ~sub:"(edge move-3 " out);
  check "control: every edge is a self-loop on the single node"
    (contains ~sub:"(edge raise (src n0) (tgt n0))" out
    && contains ~sub:"(edge lower (src n0) (tgt n0))" out
    && contains ~sub:"(edge move-3 (src n0) (tgt n0))" out);
  check "control: the emitted library re-parses" (reparses out)

(* --- fresh names (§7): entities share one namespace ------------------------- *)

let () =
  (* A transition literally named [n0] forces the node off it to [n0_]. *)
  let m = mk [ flip "n0" "down" "up"; anon (is "s" "pos" "up") [] ] in
  let out = Control.quiver "fresh" m in
  check "control: node dodges a transition named n0"
    (contains ~sub:"(node n0_)" out
    && contains ~sub:"(edge n0 (src n0_) (tgt n0_))" out);
  (* A real [move-2] pushes the synthesised name off it. *)
  let m2 =
    mk [ named "move-2" (is "s" "pos" "down") []; anon (is "s" "pos" "up") [] ]
  in
  let out2 = Control.quiver "fresh2" m2 in
  check "control: synthesised move name dodges a real move-2"
    (contains ~sub:"(edge move-2 " out2
    && contains ~sub:"(edge move-2_ " out2
    && reparses out2)

(* --- zero transitions: a valid quiver instance with no edges ---------------- *)

let () =
  let out = Control.quiver "empty" (mk []) in
  check "control: zero transitions emits an empty edge roster"
    (contains ~sub:"(node n0)" out
    && (not (contains ~sub:"(edge " out))
    && reparses out)

(* --- the source → control → source round-trip (gap 6, §10.1 NAME fresh) ------ *)

(* Two transitions of one name broke §7 in control's output; §10.1 now refuses
   the model. Both ends are pinned. *)
let parses src =
  match Reader.read_string src with
  | Error e -> Error e
  | Ok ds -> Parser.parse_model ds

let () =
  let src names =
    "(schema tg (type pos-t (down up)) (type sw (arrow pos (to pos-t))))\n\
     (instance i tg (sw s (pos down)) )\n\
     (use tg) (initial i)\n"
    ^ String.concat "\n"
        (List.map
           (fun (n, from_, to_) ->
             "(transition " ^ n ^ " (when (is s.pos " ^ from_
             ^ ")) (do (set s.pos " ^ to_ ^ ")))")
           names)
  in
  (match parses (src [ ("raise", "down", "up"); ("lower", "up", "down") ]) with
  | Error _ -> check "control round-trip: the two-move model parses" false
  | Ok m ->
      let out = Control.quiver "roundtrip" m in
      check
        "control round-trip: the emitted quiver survives §7, not just the \
         reader"
        (reparses_with_fresh_names out));
  match parses (src [ ("dup", "down", "up"); ("dup", "up", "down") ]) with
  | Ok _ ->
      check "control round-trip: a duplicate transition name is refused" false
  | Error e ->
      check
        "control round-trip: a duplicate transition name is refused at the \
         second one"
        (e.Errors.pos = Some { Errors.file = None; line = 5; col = 13 })

let () =
  print_string ("control tests: " ^ string_of_int !passed ^ " checks passed\n")
