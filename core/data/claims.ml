(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Claims: the questions the engine answers. Kept in core so the engine never
   depends on the front end. *)

(* [Inevitable] is AF, with the moves assumed never starved (empty: every
   run). Fairness belongs to the question, not the model. *)
type modality = Never | Possible | Live | Inevitable of string list

(* [show] names queries to evaluate at the situation a verdict singles out
   (the stuck, violating or satisfying one), saying who is affected there. *)
type property = {
  name : string;
  text : string;
  modality : modality;
  formula : Model.guard;
  show : string list;
}

type query = {
  name : string;
  binders : (string * string) list;
  guard : Model.guard;
}

type accept = { tr : string; eq : string }
type t = { props : property list; queries : query list; accepts : accept list }
