(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [writ schema] unit tests: a model's map survives the trip out to data and
   back. *)

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

let arrow name dom cod : Schema.arrow =
  { name; dom; cod; fixed = false; vacatable = false }

let ty name arrows : Schema.ty = { name; flavor = Schema.Open; arrows }

(* §7 catches two arrows collapsing onto one hom entity name. *)
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
            origin = None;
          };
        ];
    }
  in
  let out = Schema_data.olog "m" s in
  check "every type becomes an ob"
    (contains ~sub:"(ob indep-status bureau case)" out);
  check "an arrow's hom entity is named dom-arrow"
    (contains ~sub:"bureau-independence" out);
  (* Entity-major: an arrow's endpoints sit beside its name in one clause. *)
  check "dom and cod carry the arrow's endpoints"
    (contains ~sub:"(hom bureau-independence (dom bureau) (cod indep-status))"
       out);
  check "a law appears by name" (contains ~sub:"(eqn same-agency)" out);
  check "a law's body is not encoded" (not (contains ~sub:"Chain" out));
  check "the emitted library re-parses through §7"
    (reparses_with_fresh_names out)

(* Two types may each own a `status` (§7); the emitter must keep them apart. *)
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

(* A type already called `bureau-status` must not be shadowed by the arrow
   `bureau.status`. *)
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

(* olog describes itself: the schema of schemas is a schema. *)
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
    (contains ~sub:"(hom hom-dom (dom hom) (cod ob))" out
    && contains ~sub:"(hom hom-cod (dom hom) (cod ob))" out);
  check "self-description re-parses through §7" (reparses_with_fresh_names out)

let () =
  print_string
    ("schema-data tests: " ^ string_of_int !passed ^ " checks passed\n")
