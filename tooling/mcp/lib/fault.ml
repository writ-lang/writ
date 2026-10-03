(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Why a tool call produced no answer. Kept as data, not a string, so the
   server can render it as prose or JSON and attach a code, a suggestion and
   a fix (Diagnose). *)

open Writ_data

type source = Model | Claims | Rules | Args

let source_name = function
  | Model -> "model"
  | Claims -> "claims"
  | Rules -> "rules"
  | Args -> "arguments"

(* [code] is set where the tool knows it; otherwise Diagnose classifies the
   engine's message. [meant] is (found, legal alternatives) when the tool
   knows them; otherwise Diagnose reads the sources for them. *)
type t = {
  source : source;
  code : string option;
  err : Errors.t;
  meant : (string * string list) option;
}

(* A search stopped by a limit: not wrong, only unfinished. *)
type limit = {
  cutoff : Writ_runtime.Space.cutoff;
  undecided : string list;  (** properties the claims ask, none decided *)
}

(* [Bad] holds one error per file at most: each front end stops at its first. *)
type failure = Bad of t list | Limit of limit

let bad ?code ?meant source err = Bad [ { source; code; err; meant } ]

let arg code msg =
  Bad
    [
      {
        source = Args;
        code = Some code;
        err = { pos = None; msg };
        meant = None;
      };
    ]
