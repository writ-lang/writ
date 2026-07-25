(* Core data-layer unit tests. Stdlib only, no framework: each [check] counts a
   pass or aborts the run with a located message. A green run prints a summary.

   Coverage: a small schema (enumerated + open types, fixed + vacatable arrows,
   one equation); Schema.check_path on a good and a bad chain; State.build_ctx
   totality rules (layout, domains, initial vector, missing-fixed, unset
   vacatable, out-of-domain); State.M state identity; Value's total order. *)

open Pol_data

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

(* --- a small schema mirroring the kernel-spec running example --------------- *)

let arrow name dom cod ~fixed ~vacatable : Schema.arrow =
  { name; dom; cod; fixed; vacatable }

let employer = arrow "employer" "person" "bureau" ~fixed:true ~vacatable:false

let independence =
  arrow "independence" "bureau" "indep-status" ~fixed:false ~vacatable:false

let stage = arrow "stage" "case" "stage-t" ~fixed:false ~vacatable:false

let investigator =
  arrow "investigator" "case" "bureau" ~fixed:true ~vacatable:false

let judge = arrow "judge" "case" "person" ~fixed:false ~vacatable:true
let ty name flavor arrows : Schema.ty = { name; flavor; arrows }
let path root steps : Value.path = { root; steps }

let schema : Schema.t =
  {
    name = "oversight";
    types =
      [
        ty "indep-status" (Enumerated [ "independent"; "captured" ]) [];
        ty "stage-t" (Enumerated [ "open"; "concluded" ]) [];
        ty "person" Open [ employer ];
        ty "bureau" Open [ independence ];
        ty "case" Open [ stage; investigator; judge ];
      ];
    arrows = [ employer; independence; stage; investigator; judge ];
    equations =
      [
        {
          name = "same-agency";
          lhs = path "case" [ "investigator"; "independence" ];
          rhs = path "case" [ "investigator"; "independence" ];
        };
      ];
  }

let cell arrow src : Instance.cellref = { arrow; src }

(* [day_one], optionally with an override list of extra/omitted valuation. *)
let base_valuation =
  [
    (cell "employer" "alice", Value.Filled "watchdog");
    (cell "investigator" "docket", Value.Filled "watchdog");
    (cell "independence" "watchdog", Value.Filled "independent");
    (cell "independence" "prosecutions", Value.Filled "independent");
    (cell "stage" "docket", Value.Filled "open");
    (cell "judge" "docket", Value.Vacant);
  ]

let instance_with valuation : Instance.t =
  {
    name = "day-one";
    schema = "oversight";
    rosters =
      [
        { ty = "bureau"; entities = [ "watchdog"; "prosecutions" ] };
        { ty = "person"; entities = [ "alice" ] };
        { ty = "case"; entities = [ "docket" ] };
      ];
    valuation;
  }

let day_one = instance_with base_valuation

(* index of a mutable cellref in the layout, or -1 *)
let idx_of (ctx : State.ctx) cr =
  Option.value ~default:(-1) (State.index_of ctx cr)

let contains_sub ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

(* --- Schema.check_path ------------------------------------------------------ *)

let () =
  let env = [ ("docket", "case") ] in
  (match
     Schema.check_path schema env
       (path "docket" [ "investigator"; "independence" ])
   with
  | Ok arrows ->
      check "check_path: valid chain returns its arrows" (List.length arrows = 2);
      let last = List.nth arrows 1 in
      check "check_path: chain ends at indep-status"
        (last.Schema.cod = "indep-status")
  | Error e ->
      check ("check_path unexpectedly rejected: " ^ Errors.to_string e) false);
  (match
     Schema.check_path schema env (path "docket" [ "stage"; "independence" ])
   with
  | Ok _ -> check "check_path: bad step must be rejected" false
  | Error e ->
      check "check_path: bad step is unlocated (parser adds pos)"
        (e.Errors.pos = None);
      check "check_path: error names the offending arrow"
        (contains_sub ~sub:"independence" e.Errors.msg);
      check "check_path: error names the type lacking it"
        (contains_sub ~sub:"stage-t" e.Errors.msg));
  match Schema.check_path schema [] (path "ghost" [ "stage" ]) with
  | Ok _ -> check "check_path: unbound root must be rejected" false
  | Error _ -> check "check_path: unbound root rejected" true

(* --- State.build_ctx -------------------------------------------------------- *)

let () =
  match State.build_ctx schema day_one with
  | Error e -> check ("build_ctx unexpectedly failed: " ^ e) false
  | Ok (ctx, st) ->
      check "build_ctx: 4 mutable cells in the layout"
        (Array.length ctx.layout.cells = 4);
      check "build_ctx: state vector aligns to the layout"
        (Array.length st = Array.length ctx.layout.cells);
      (* a mutable enumerated cell's domain *)
      let i_ind = idx_of ctx (cell "independence" "watchdog") in
      check "build_ctx: independence cell is in the layout" (i_ind >= 0);
      let dom_ind = ctx.layout.domains.(i_ind) in
      check "build_ctx: enumerated domain has both values"
        (Array.length dom_ind = 2);
      check "build_ctx: domain includes independent"
        (Array.exists (Value.equal_cell (Value.Filled "independent")) dom_ind);
      check "build_ctx: domain includes captured"
        (Array.exists (Value.equal_cell (Value.Filled "captured")) dom_ind);
      (* a vacatable open cell's domain includes Vacant + the roster *)
      let i_judge = idx_of ctx (cell "judge" "docket") in
      let dom_judge = ctx.layout.domains.(i_judge) in
      check "build_ctx: vacatable domain includes Vacant"
        (Array.exists (Value.equal_cell Value.Vacant) dom_judge);
      check "build_ctx: vacatable open domain includes the roster entity"
        (Array.exists (Value.equal_cell (Value.Filled "alice")) dom_judge);
      (* the initial vector via get, fixed and mutable *)
      check "build_ctx: initial independence@watchdog = independent"
        (Value.equal_cell
           (State.get ctx st (cell "independence" "watchdog"))
           (Value.Filled "independent"));
      check "build_ctx: initial stage@docket = open"
        (Value.equal_cell
           (State.get ctx st (cell "stage" "docket"))
           (Value.Filled "open"));
      check "build_ctx: explicit judge@docket = vacant"
        (Value.equal_cell
           (State.get ctx st (cell "judge" "docket"))
           Value.Vacant);
      check "build_ctx: fixed investigator@docket read from ctx = watchdog"
        (Value.equal_cell
           (State.get ctx st (cell "investigator" "docket"))
           (Value.Filled "watchdog"))

(* missing fixed cell → error *)
let () =
  let val' =
    List.filter (fun (c, _) -> c <> cell "investigator" "docket") base_valuation
  in
  match State.build_ctx schema (instance_with val') with
  | Ok _ -> check "build_ctx: missing fixed cell must error" false
  | Error msg ->
      check "build_ctx: missing fixed cell errors naming the cell"
        (contains_sub ~sub:"investigator" msg)

(* unset vacatable mutable cell defaults to Vacant *)
let () =
  let val' =
    List.filter (fun (c, _) -> c <> cell "judge" "docket") base_valuation
  in
  match State.build_ctx schema (instance_with val') with
  | Error e ->
      check ("build_ctx: unset vacatable should default, got: " ^ e) false
  | Ok (ctx, st) ->
      check "build_ctx: unset vacatable cell defaults to Vacant"
        (Value.equal_cell
           (State.get ctx st (cell "judge" "docket"))
           Value.Vacant)

(* a value outside the cell's domain → error *)
let () =
  let val' =
    List.map
      (fun (c, v) ->
        if c = cell "stage" "docket" then (c, Value.Filled "pending") else (c, v))
      base_valuation
  in
  match State.build_ctx schema (instance_with val') with
  | Ok _ -> check "build_ctx: out-of-domain value must error" false
  | Error _ -> check "build_ctx: out-of-domain value errors" true

(* --- State.M identity ------------------------------------------------------- *)

let () =
  match State.build_ctx schema day_one with
  | Error e -> check ("build_ctx failed for M test: " ^ e) false
  | Ok (ctx, st) ->
      let i_stage = idx_of ctx (cell "stage" "docket") in
      let st2 = State.set st i_stage (Value.Filled "concluded") in
      check "State: set produces a distinct state" (State.compare st st2 <> 0);
      check "State: set does not mutate the original"
        (Value.equal_cell st.(i_stage) (Value.Filled "open"));
      let st_eq = Array.copy st in
      check "State: an equal vector compares equal" (State.compare st st_eq = 0);
      let m = State.M.add st 1 (State.M.add st2 2 State.M.empty) in
      check "State.M: distinct states are distinct keys" (State.M.cardinal m = 2);
      check "State.M: equal states unify (find by a copy)"
        (State.M.find st_eq m = 1);
      let m2 = State.M.add st 9 m in
      check "State.M: re-adding an equal key overrides, not grows"
        (State.M.cardinal m2 = 2 && State.M.find st m2 = 9)

(* --- Value: total order ----------------------------------------------------- *)

let () =
  check "Value: Vacant precedes Filled"
    (Value.compare_cell Value.Vacant (Value.Filled "a") < 0);
  check "Value: Filled follows Vacant"
    (Value.compare_cell (Value.Filled "a") Value.Vacant > 0);
  check "Value: Vacant equals itself"
    (Value.compare_cell Value.Vacant Value.Vacant = 0);
  check "Value: Filled compares by string"
    (Value.compare_cell (Value.Filled "a") (Value.Filled "b") < 0);
  check "Value: antisymmetry on filled"
    (Value.compare_cell (Value.Filled "b") (Value.Filled "a") > 0);
  (* array order: shorter first, then lexicographic *)
  let a = [| Value.Filled "a" |] in
  let ab = [| Value.Filled "a"; Value.Vacant |] in
  check "Value: shorter array sorts first" (Value.compare_cells a ab < 0);
  let ax = [| Value.Filled "a"; Value.Filled "x" |] in
  let ay = [| Value.Filled "a"; Value.Filled "y" |] in
  check "Value: equal-length arrays compare lexicographically"
    (Value.compare_cells ax ay < 0);
  check "Value: identical arrays compare equal" (Value.compare_cells ax ax = 0)

let () =
  print_string ("core tests: " ^ string_of_int !passed ^ " checks passed\n")
