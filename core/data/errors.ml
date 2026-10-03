(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* A diagnostic, positioned when there is a datum to blame. The file is part
   of the position because [Loader] splices libraries into the loading file;
   [None] means unnamed text. *)

type pos = { file : string option; line : int; col : int }
type t = { pos : pos option; msg : string }

let to_string d =
  match d.pos with
  | None -> d.msg
  | Some p ->
      let where = string_of_int p.line ^ ":" ^ string_of_int p.col in
      (match p.file with Some f -> f ^ ":" ^ where | None -> where)
      ^ ": " ^ d.msg

(* A failed [result] carrying a diagnostic. *)
let err ?pos msg : ('a, t) result = Error { pos; msg }
