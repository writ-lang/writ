(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The role a buffer plays, decided from its path and top-level datums: a .writ
   file is a model when it declares a (use …) and a library otherwise (kernel
   §6.1); a .claims (§16) or .rules (relational §1) file is asked of a sibling
   model. *)

open Writ_syntax

type t =
  | Claims of string  (** the sibling model file this .claims is asked of *)
  | Rules of string  (** the sibling model file this .rules is derived over *)
  | Model
  | Library

(* any_model.claims -> any_model.writ *)
let sibling_model (path : string) : string =
  Filename.remove_extension (Filename.basename path) ^ ".writ"

let declares_use (ds : Reader.t list) : bool =
  List.exists
    (function
      | Reader.List (Reader.Atom ("use", _) :: _, _) -> true | _ -> false)
    ds

let of_path (path : string) (ds : Reader.t list) : t =
  if Filename.check_suffix path ".claims" then Claims (sibling_model path)
  else if Filename.check_suffix path ".rules" then Rules (sibling_model path)
  else if declares_use ds then Model
  else Library
