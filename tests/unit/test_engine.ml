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
let ind a = path "case" [ a; "independence" ] (* total: strict = Kleene *)
let set e a v = Model.Set (path e [ a ], Model.Lit v)

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

(* --- inevitable: the gap between "can still" and "cannot avoid" ------------- *)

(* A cycle does not refute [inevitable] by existing — only one that stays off
   the goal does. The toggle loops forever between two situations, and `up` is
   one of them, so every run reaches it: [inevitable] HOLDS over a cyclic space,
   which is the case a "reject anything with a loop" implementation gets
   wrong. *)
let () =
  let sp = build_ok toggle in
  check "inevitable holds: every run of the toggle passes through up"
    (Checker.check sp (prop "i" (Inevitable []) (is "s" "pos" "up"))
    = Checker.Holds [])

(* The pair the whole modality exists for, at three situations. `wander` and
   `back` are a loop that never touches `home`, and `arrive` leaves it for
   `home`, which is where the model stops. So `home` is always still reachable
   — [live] holds — and a run can decline to take it forever — [inevitable]
   fails. This is two-phase commit with a retransmitting network, reduced until
   it can be counted by hand: three situations, three edges.

   The counterexample is the INITIAL situation, and its route is therefore
   empty: the run that avoids `home` is available from the start, and a
   shortest witness to that is no moves at all. *)
let detour =
  mk
    [
      flip "wander" "home-able" "away";
      flip "back" "away" "home-able";
      flip "arrive" "home-able" "home";
    ]
    "home-able"
    [ "home-able"; "away"; "home" ]

let () =
  let sp = build_ok detour in
  check "detour: three situations" (Array.length sp.Space.states = 3);
  check "live holds: home stays reachable from everywhere"
    (Checker.check sp (prop "l" Live (is "s" "pos" "home")) = Checker.Holds []);
  match Checker.check sp (prop "i" (Inevitable []) (is "s" "pos" "home")) with
  | Checker.Fails { route = []; stuck = Some s } ->
      check "inevitable fails: the loop is a run that never arrives"
        (State.get sp.Space.ctx s (cr "pos" "s") = Value.Filled "home-able")
  | _ ->
      check "inevitable fails: expected the initial situation, no moves" false

(* Stopping refutes as well as looping: a run that ends where the model ends,
   without the goal, has avoided it. capture is one-way into a dead end, so a
   run that takes it never comes back to `safe` — and [inevitable] reports the
   same route [live] does, since here the trap and the escape are one move. *)
let () =
  let sp = build_ok capture_model in
  match Checker.check sp (prop "i" (Inevitable []) (is "s" "pos" "safe")) with
  | Checker.Fails { route = [ "capture" ]; stuck = Some _ } ->
      check "inevitable fails at a dead end that is not the goal" true
  | _ -> check "inevitable fails: expected witness [capture]" false

(* [inevitable] implies [live], because a state has at least one run and a run
   that reaches F witnesses that F is reachable. So of the four combinations
   only three can occur, and this asserts the missing one is missing across
   every model and goal this file builds — the property is about the pair, so
   testing it on one fixture would prove nothing. *)
let () =
  let goals = [ "up"; "down"; "safe"; "captured"; "home"; "away"; "home-able" ] in
  let holds = function Checker.Holds _ -> true | _ -> false in
  let bad =
    List.concat_map
      (fun m ->
        let sp = build_ok m in
        List.filter
          (fun g ->
            let q md = Checker.check sp (prop "q" md (is "s" "pos" g)) in
            holds (q (Inevitable [])) && not (holds (q Live)))
          goals)
      [ toggle; capture_model; detour ]
  in
  check "no goal is inevitable without being live" (bad = [])

(* --- fairness: which runs the question is about ----------------------------- *)

(* The detour's loop is a run that never arrives, and `arrive` is on offer at
   every turn of it and never taken. Assuming that move is not starved for ever
   deletes the loop, and there is nothing else to escape by — so the same model
   and the same goal answer differently to the two questions, which is the whole
   reason the assumption belongs to the question. *)
let () =
  let sp = build_ok detour in
  let goal ms = prop "i" (Inevitable ms) (is "s" "pos" "home") in
  let holds = function Checker.Holds _ -> true | _ -> false in
  check "unfair: a run can decline to arrive for ever"
    (not (holds (Checker.check sp (goal []))));
  check "fair: assuming arrive is not starved, every run arrives"
    (holds (Checker.check sp (goal [ "arrive" ])));
  (* A move the cycle DOES take is not starved by it, so assuming it fair
     changes nothing — the loop takes `wander` every time round. *)
  check "a move the loop takes is already fair to it"
    (not (holds (Checker.check sp (goal [ "wander" ]))));
  (* Naming a move the model does not have is neither a pass nor a failure, the
     same treatment a formula naming a missing arrow gets. *)
  (match Checker.check sp (goal [ "sprint" ]) with
  | Checker.Not_applicable _ -> check "n/a: an unknown move is n/a" true
  | _ -> check "n/a: an unknown move must be n/a" false);
  (* The assumption is printed with the verdict, both ways: a verdict that could
     be quoted without it would be a different claim from the one checked. *)
  let s = Report.outcome sp (goal [ "arrive" ]) (Checker.check sp (goal [ "arrive" ])) in
  check "report: a holding inevitable names what it assumed"
    (contains ~sub:"holds  i" s && contains ~sub:"assuming fair: arrive" s)

(* No assumption about scheduling rescues a model that stops. capture is
   one-way into a dead end, and a run that takes it is FINITE — nothing is on
   offer for ever in it, so there is no starvation to rule out. *)
let () =
  let sp = build_ok capture_model in
  let goal ms = prop "i" (Inevitable ms) (is "s" "pos" "safe") in
  let fails = function Checker.Fails _ -> true | _ -> false in
  check "fairness does not rescue a dead end"
    (fails (Checker.check sp (goal []))
    && fails (Checker.check sp (goal [ "capture" ])))

(* The fairness clause, through the real reader and the real claims parser, so
   the spelling in the spec is the spelling that decodes. *)
let () =
  let sch = sw_schema [ "down"; "up" ] and inst = sw_instance "down" in
  let parse src =
    match Pol_syntax.Reader.read_string src with
    | Error e -> Error e
    | Ok ds -> Pol_syntax.Claims_parser.parse sch inst ds
  in
  (match
     parse "(property p \"d\" (inevitable (is s.pos up) (fair raise lower)))"
   with
  | Ok { Claims.props = [ { modality = Inevitable [ "raise"; "lower" ]; _ } ]; _ }
    ->
      check "claims: (fair MOVE…) decodes into the modality, in order" true
  | _ -> check "claims: (fair MOVE…) must decode into the modality" false);
  (match parse "(property p \"d\" (inevitable (is s.pos up)))" with
  | Ok { Claims.props = [ { modality = Inevitable []; _ } ]; _ } ->
      check "claims: no clause is the plain reading, over every run" true
  | _ -> check "claims: a bare inevitable must carry no assumption" false);
  let rejected name src =
    match parse src with
    | Error e -> check (name ^ " is positioned") (e.Pol_data.Errors.pos <> None)
    | Ok _ ->
        check (name ^ ": expected a rejection") false;
        exit 1
  in
  rejected "claims: fairness on live"
    "(property p \"d\" (live (is s.pos up) (fair raise)))";
  rejected "claims: an empty fairness clause"
    "(property p \"d\" (inevitable (is s.pos up) (fair)))";
  rejected "claims: a guard where a move name belongs"
    "(property p \"d\" (inevitable (is s.pos up) (fair (is s.pos up))))"

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
          body = Guard.Is (ind "investigator", Guard.Chain (ind "prosecutor"));
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
