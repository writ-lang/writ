(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Query bindings: the rows of the binders' rosters for which the guard holds
   at the addressed state (default: the initial one), each row in binder
   order. Witnesses belong to [Checker]. *)
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
