(* [pol control] unit tests (TD). Stdlib only: [Control.quiver] on small in-code
   [Model.t] values, asserting the §17 quiver shape (one edge per transition,
   self-loops on one node), the §7 fresh-name discipline, and that the emitted
   library re-parses through the real reader. *)

open Pol_data
open Pol_syntax
open Pol_runtime

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
let is e a v = Model.Is (path e [ a ], v)
let set e a v = Model.Set (path e [ a ], v)

let named n g effs : Model.transition =
  { name = Some n; when_ = g; effects = effs }

let anon g effs : Model.transition = { name = None; when_ = g; effects = effs }
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
  check "control: emits (of quiver)" (contains ~sub:"(of quiver)" out);
  check "control: self-contained via (load \"stdlib.pol\")"
    (contains ~sub:"(load \"stdlib.pol\")" out);
  check "control: instance is NAME-control"
    (contains ~sub:"(instance ctrlfix-control " out);
  (* one edge entity per transition: two named + [move-3] for the unnamed one *)
  check "control: one edge per transition, unnamed -> move-3"
    (contains ~sub:"(edge raise lower move-3)" out);
  check "control: every src is a self-loop on the single node"
    (contains ~sub:"(src (raise n0) (lower n0) (move-3 n0))" out);
  check "control: every tgt is a self-loop on the single node"
    (contains ~sub:"(tgt (raise n0) (lower n0) (move-3 n0))" out);
  check "control: the emitted library re-parses" (reparses out)

(* --- fresh names (§7): entities share one namespace ------------------------- *)

let () =
  (* A transition literally named [n0] forces the node off it to [n0_]. *)
  let m = mk [ flip "n0" "down" "up"; anon (is "s" "pos" "up") [] ] in
  let out = Control.quiver "fresh" m in
  check "control: node dodges a transition named n0"
    (contains ~sub:"(node n0_)" out && contains ~sub:"(n0 n0_)" out);
  (* A real [move-2] forces the synthesised name for the unnamed 2nd move off
     it, so no two edge entities collide. *)
  let m2 =
    mk [ named "move-2" (is "s" "pos" "down") []; anon (is "s" "pos" "up") [] ]
  in
  let out2 = Control.quiver "fresh2" m2 in
  check "control: synthesised move name dodges a real move-2"
    (contains ~sub:"(edge move-2 move-2_)" out2 && reparses out2)

(* --- zero transitions: a valid quiver instance with no edges ---------------- *)

let () =
  let out = Control.quiver "empty" (mk []) in
  check "control: zero transitions emits an empty edge roster"
    (contains ~sub:"(edge)" out && contains ~sub:"(src)" out
   && contains ~sub:"(tgt))" out && reparses out)

let () =
  print_string ("control tests: " ^ string_of_int !passed ^ " checks passed\n")
