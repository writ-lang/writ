open Pol_data

(* Query bindings: the rows of a roster tuple satisfying the guard at the
   initial state or an addressed state. No proofs are attached here — those
   belong to the checker (the [checker] module holds the state-category
   morphisms). *)

(* Enumerate the binding rows: the cartesian product of the binders' rosters,
   kept where the guard holds at the addressed state (default: the initial
   state). Each row lists the bindings in binder order. *)
let run (sp : Space.t) (q : Claims.query) ?at () : (string * string) list list =
  let ctx = sp.Space.ctx in
  let st = match at with Some s -> s | None -> sp.Space.initial in
  let rec rows binders acc =
    match binders with
    | [] ->
        if Eval.guard_holds ctx st (List.rev acc) q.guard then [ List.rev acc ]
        else []
    | (x, ty) :: rest ->
        List.concat_map
          (fun e -> rows rest ((x, e) :: acc))
          (Eval.entities_of_type ctx ty)
  in
  rows q.binders []
