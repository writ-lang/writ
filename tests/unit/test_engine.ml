(* Engine unit tests (TD). Stdlib only, no framework: each [check] counts a pass
   or aborts. Models are built directly as [Model.t] values, exercising BFS
   enumeration, shortest paths, the three modalities with witnesses,
   gap-vs-deadlock, equation observation, and query rows. *)

open Pol_data
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

(* --- construction helpers --------------------------------------------------- *)

let arrow name dom cod ~fixed ~vacatable : Schema.arrow =
  { name; dom; cod; fixed; vacatable }

let ty name flavor arrows : Schema.ty = { name; flavor; arrows }
let path root steps : Value.path = { root; steps }
let is e a v = Model.Is (path e [ a ], Model.Lit v)
let set e a v = Model.Set (path e [ a ], v)

let tr name g effs : Model.transition =
  { name = Some name; when_ = g; effects = effs }

let cr a s : Instance.cellref = { arrow = a; src = s }
let fill a s v = (cr a s, Value.Filled v)

let prop name modality formula : Claims.property =
  { name; text = ""; modality; formula }

let build_ok m =
  match Space.build m with Ok sp -> sp | Error e -> failwith ("build: " ^ e)

(* The first reachable state whose cell [arrow@src] is [Filled v]. *)
let find_state sp arrow src v : State.t =
  let r = ref None in
  Array.iter
    (fun s ->
      if !r = None && State.get sp.Space.ctx s (cr arrow src) = Value.Filled v
      then r := Some s)
    sp.Space.states;
  match !r with Some s -> s | None -> failwith ("no " ^ arrow ^ "=" ^ v)

(* A one-switch world: an open type [sw] with a mutable enumerated arrow [pos]. *)
let pos_arrow = arrow "pos" "sw" "pos-t" ~fixed:false ~vacatable:false

let sw_schema vals : Schema.t =
  {
    name = "toggle";
    types = [ ty "pos-t" (Enumerated vals) []; ty "sw" Open [ pos_arrow ] ];
    arrows = [ pos_arrow ];
    equations = [];
  }

let sw_instance init : Instance.t =
  {
    name = "i";
    schema = "toggle";
    rosters = [ { ty = "sw"; entities = [ "s" ] } ];
    valuation = [ fill "pos" "s" init ];
  }

let mk trs init vals : Model.t =
  { schema = sw_schema vals; initial = sw_instance init; transitions = trs }

let flip name from_ to_ = tr name (is "s" "pos" from_) [ set "s" "pos" to_ ]

(* --- toggle: BFS counts, dist, shortest_path -------------------------------- *)

let toggle =
  mk
    [ flip "raise" "down" "up"; flip "lower" "up" "down" ]
    "down" [ "down"; "up" ]

let () =
  let sp = build_ok toggle in
  check "toggle: 2 states" (Array.length sp.Space.states = 2);
  check "toggle: 2 edges" (List.length sp.Space.edges = 2);
  let up = find_state sp "pos" "s" "up" in
  check "toggle: up is one move from initial" (State.M.find up sp.Space.dist = 1);
  check "toggle: initial has distance 0"
    (State.M.find sp.Space.initial sp.Space.dist = 0);
  check "toggle: shortest_path to up is [raise]"
    (Space.shortest_path sp up = [ "raise" ]);
  check "toggle: build report has the size token (three-space gutter)"
    (contains ~sub:"states: 2   edges: 2" (Report.build sp))

(* --- gap vs deadlock (the gate distinction) --------------------------------- *)

(* [blow] fires from BOTH b and c with the same message — two gap edges the
   report dedups to ONE site, at the fewest moves; a gap-firing state has an
   enabled (gap) edge, so it is NOT a dead end (M1). *)
let is_gap (e : Space.edge) = match e.dst with `Gap _ -> true | _ -> false

let gap_model =
  mk
    [
      flip "raise" "a" "b";
      flip "climb" "b" "c";
      tr "blow"
        (Model.Or [ is "s" "pos" "b"; is "s" "pos" "c" ])
        [ Model.Gap "boom" ];
    ]
    "a" [ "a"; "b"; "c" ]

let () =
  let sp = build_ok gap_model in
  let b = find_state sp "pos" "s" "b" in
  check "gap: the gap source is NOT a dead end" (Space.enabled_of sp b <> []);
  check "gap: no dead ends" (Space.dead_ends sp = []);
  check "gap: two gap edges fire" (List.length (List.filter is_gap sp.edges) = 2);
  check "gap: but dedup to one site at the fewest moves"
    (Space.reachable_gaps sp = [ ("blow", "boom", 1) ]);
  let r = Report.build sp in
  check "gap: build report counts one gap with the em-dash line"
    (contains ~sub:"gaps: 1" r
    && contains ~sub:"dead ends: none" r
    && contains ~sub:"  blow — \"boom\" (min 1 moves)" r)

let deadlock_model = mk [ flip "raise" "down" "up" ] "down" [ "down"; "up" ]

let () =
  let sp = build_ok deadlock_model in
  let up = find_state sp "pos" "s" "up" in
  check "deadlock: the stuck state has no enabled move"
    (Space.enabled_of sp up = []);
  check "deadlock: exactly one dead end" (List.length (Space.dead_ends sp) = 1);
  check "deadlock: zero reachable gaps" (Space.reachable_gaps sp = []);
  let r = Report.build sp in
  check "deadlock: build report says dead ends: 1"
    (contains ~sub:"dead ends: 1" r);
  check "deadlock: build report says gaps: none" (contains ~sub:"gaps: none" r)

(* --- never / possible / live ------------------------------------------------ *)

let capture_model =
  mk [ flip "capture" "safe" "captured" ] "safe" [ "safe"; "captured" ]

let () =
  let sp = build_ok toggle in
  check "live holds: up is always reachable (no single route)"
    (Checker.check sp (prop "acc" Live (is "s" "pos" "up")) = Checker.Holds []);
  (match Checker.check sp (prop "na" Live (is "s" "pos" "green")) with
  | Checker.Not_applicable _ -> check "n/a: unknown value is n/a" true
  | _ -> check "n/a: unknown value must be n/a" false);
  match
    Checker.check sp (prop "na2" Never (Model.Defined (path "s" [ "gone" ])))
  with
  | Checker.Not_applicable _ -> check "n/a: unknown arrow is n/a" true
  | _ -> check "n/a: unknown arrow must be n/a" false

let () =
  let sp = build_ok capture_model in
  (* live FAILS: capture traps; the finding carries the route AND the stuck
     state (for [stuck at:]). never FAILS with a route but no stuck state. *)
  (match Checker.check sp (prop "acc" Live (is "s" "pos" "safe")) with
  | Checker.Fails { route = [ "capture" ]; stuck = Some _ } ->
      check "live fails: witness [capture] with a stuck state" true
  | _ -> check "live fails: expected witness [capture] + stuck" false);
  (match Checker.check sp (prop "n" Never (is "s" "pos" "captured")) with
  | Checker.Fails { route = [ "capture" ]; stuck = None } ->
      check "never fails: witness is [capture]" true
  | _ -> check "never fails: expected witness [capture]" false);
  (* possible-holds carries the SOLUTION path: captured is reached via [capture]. *)
  check "possible holds: solution route to captured = [capture]"
    (Checker.check sp (prop "p" Possible (is "s" "pos" "captured"))
    = Checker.Holds [ "capture" ]);
  let oc = Checker.check sp (prop "acc" Live (is "s" "pos" "safe")) in
  let s = Report.outcome sp (prop "acc" Live (is "s" "pos" "safe")) oc in
  check "report: failing live shows fails + stuck at + witness"
    (contains ~sub:"fails  acc" s
    && contains ~sub:"stuck at:" s
    && contains ~sub:"witness:  1. capture" s)

(* --- equation observation: can_break, unadmitted, stale, violation ---------- *)

let independence =
  arrow "independence" "bureau" "indep-status" ~fixed:false ~vacatable:false

let investigator =
  arrow "investigator" "case" "bureau" ~fixed:true ~vacatable:false

let prosecutor = arrow "prosecutor" "case" "bureau" ~fixed:true ~vacatable:false
let stage = arrow "stage" "case" "stage-t" ~fixed:false ~vacatable:false

let anti_schema : Schema.t =
  {
    name = "anti";
    types =
      [
        ty "indep-status" (Enumerated [ "independent"; "captured" ]) [];
        ty "stage-t" (Enumerated [ "open"; "concluded" ]) [];
        ty "bureau" Open [ independence ];
        ty "case" Open [ investigator; prosecutor; stage ];
      ];
    arrows = [ independence; investigator; prosecutor; stage ];
    equations =
      [
        {
          name = "same-agency";
          lhs = path "case" [ "investigator"; "independence" ];
          rhs = path "case" [ "prosecutor"; "independence" ];
        };
      ];
  }

let anti_instance : Instance.t =
  {
    name = "a";
    schema = "anti";
    rosters =
      [
        { ty = "bureau"; entities = [ "w"; "p" ] };
        { ty = "case"; entities = [ "d" ] };
      ];
    valuation =
      [
        fill "investigator" "d" "w";
        fill "prosecutor" "d" "p";
        fill "independence" "w" "independent";
        fill "independence" "p" "independent";
        fill "stage" "d" "open";
      ];
  }

let capture_w =
  tr "capture-w"
    (is "w" "independence" "independent")
    [ set "w" "independence" "captured" ]

let conclude =
  tr "conclude" (is "d" "stage" "open") [ set "d" "stage" "concluded" ]

let anti_model : Model.t =
  {
    schema = anti_schema;
    initial = anti_instance;
    transitions = [ capture_w; conclude ];
  }

let same_agency = List.hd anti_schema.equations

let () =
  check "can_break: writing a footprint arrow can break the law"
    (Observe.can_break capture_w same_agency);
  check "can_break: writing an unrelated arrow cannot"
    (not (Observe.can_break conclude same_agency));
  let sp = build_ok anti_model in
  (* accept the can't-break move ⇒ stale; leave capture-w unowned ⇒ undeclared *)
  let claims : Claims.t =
    {
      props = [];
      queries = [];
      accepts = [ { tr = "conclude"; eq = "same-agency" } ];
    }
  in
  check "observe: unadmitted breakage is reported"
    (List.mem ("capture-w", "same-agency") (Observe.unadmitted sp claims));
  check "observe: a stale accept is reported"
    (List.mem ("conclude", "same-agency") (Observe.stale sp claims));
  check "observe: the reachable violation is reported (with a count)"
    (List.exists
       (fun (l : Observe.law) -> l.name = "same-agency" && l.violation <> None)
       (Observe.laws sp))

(* --- query rows over a roster ----------------------------------------------- *)
let () =
  let sp = build_ok anti_model in
  let q : Claims.query =
    {
      name = "captured-bureaus";
      binders = [ ("b", "bureau") ];
      guard = is "b" "independence" "captured";
    }
  in
  check "query: nobody is captured at the initial state" (Query.run sp q () = []);
  let captured = find_state sp "independence" "w" "captured" in
  let rows = Query.run sp q ~at:captured () in
  check "query: exactly one captured bureau after capture"
    (rows = [ [ ("b", "w") ] ]);
  let r = Report.query_rows q (State.M.find captured sp.Space.index) rows in
  check "query: rows render with the (at state N) header and a binding row"
    (contains ~sub:"captured-bureaus  (at state " r && contains ~sub:"  b = w" r)

let () =
  print_string ("engine tests: " ^ string_of_int !passed ^ " checks passed\n")
