(* [pol schema] unit tests, the sibling of test_control.ml one level up: where
   that asserts a model's DYNAMICS survive the trip out to data and back, this
   asserts its MAP does. Same discipline — the §7 fresh-name rule, and an
   emitted library that re-parses through the front end rather than merely
   balancing its parentheses. *)

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

let arrow name dom cod : Schema.arrow =
  { name; dom; cod; fixed = false; vacatable = false }

let ty name arrows : Schema.ty = { name; flavor = Schema.Open; arrows }

(* Reading alone only proves the parentheses balance. §7 is what catches the
   failure this export can actually have: two arrows collapsing onto one hom
   entity name, which reads fine and is then refused by the front end. *)
let reparses_with_fresh_names s =
  match Reader.read_string s with
  | Error _ -> false
  | Ok ds -> Result.is_ok (Names.check ds)

(* --- the shape: types are ob, arrows are hom, laws are eqn by name --------- *)

let () =
  let independence = arrow "independence" "bureau" "indep-status" in
  let investigator = arrow "investigator" "case" "bureau" in
  let s : Schema.t =
    {
      name = "oversight";
      types =
        [
          ty "indep-status" [];
          ty "bureau" [ independence ];
          ty "case" [ investigator ];
        ];
      arrows = [ independence; investigator ];
      equations =
        [
          {
            Schema.name = "same-agency";
            body =
              Guard.Is
                ( { Value.root = "case"; steps = [ "investigator" ] },
                  Guard.Chain
                    { Value.root = "case"; steps = [ "investigator" ] } );
          };
        ];
    }
  in
  let out = Schema_data.olog "m" s in
  check "every type becomes an ob"
    (contains ~sub:"(ob indep-status bureau case)" out);
  check "an arrow's hom entity is named dom-arrow"
    (contains ~sub:"bureau-independence" out);
  check "dom and cod carry the arrow's endpoints"
    (contains ~sub:"(bureau-independence bureau)" out
    && contains ~sub:"(bureau-independence indep-status)" out);
  check "a law appears by name" (contains ~sub:"(eqn same-agency)" out);
  (* Its BODY does not: since §8.6 a law holds a guard, and the checks this
     export exists to collapse read only dom and cod. *)
  check "a law's body is not encoded" (not (contains ~sub:"Chain" out));
  check "the emitted library re-parses through §7"
    (reparses_with_fresh_names out)

(* §7: arrow names are scoped to their dom, so two types may each own a
   `status`, and the emitter must not let the two collapse onto one entity. *)
let () =
  let a = arrow "status" "bureau" "flag" and b = arrow "status" "case" "flag" in
  let s : Schema.t =
    {
      name = "m";
      types = [ ty "flag" []; ty "bureau" [ a ]; ty "case" [ b ] ];
      arrows = [ a; b ];
      equations = [];
    }
  in
  let out = Schema_data.olog "m" s in
  check "two arrows sharing a name get distinct hom entities"
    (contains ~sub:"bureau-status" out && contains ~sub:"case-status" out);
  check "same-named arrows still re-parse through §7"
    (reparses_with_fresh_names out)

(* And the collision the natural spelling invites: a TYPE already called
   `bureau-status` must not be shadowed by the arrow `bureau.status`. *)
let () =
  let a = arrow "status" "bureau" "flag" in
  let s : Schema.t =
    {
      name = "m";
      types = [ ty "flag" []; ty "bureau-status" []; ty "bureau" [ a ] ];
      arrows = [ a ];
      equations = [];
    }
  in
  let out = Schema_data.olog "m" s in
  check "a hom name colliding with a type name is freshened"
    (contains ~sub:"bureau-status_" out);
  check "the freshened export re-parses through §7"
    (reparses_with_fresh_names out)

(* THE ROUND TRIP THAT MATTERS: olog describing itself, emitted rather than
   hand-written. The encoding CLOSES — a schema can describe the schema of
   schemas — and this is that claim as a test rather than an assertion. *)
let () =
  let dom = arrow "dom" "hom" "ob" and cod = arrow "cod" "hom" "ob" in
  let olog : Schema.t =
    {
      name = "olog";
      types = [ ty "ob" []; ty "hom" [ dom; cod ]; ty "eqn" [] ];
      arrows = [ dom; cod ];
      equations = [];
    }
  in
  let out = Schema_data.olog "self" olog in
  check "olog's own types are ob, hom, eqn"
    (contains ~sub:"(ob ob hom eqn)" out);
  check "olog's own arrows are dom and cod"
    (contains ~sub:"(hom hom-dom hom-cod)" out);
  check "self-description re-parses through §7" (reparses_with_fresh_names out)

let () =
  print_string
    ("schema-data tests: " ^ string_of_int !passed ^ " checks passed\n")
