(* The role a buffer plays, decided from its path and its own top-level datums —
   kernel §6.1 (a .pol file is a MODEL when it declares a (use …), and a LIBRARY
   of bare declarations otherwise), §16 (a .claims file asks its questions OF a
   sibling model) and the relational extension §1 (a .rules file asks its
   relations of one too). This is a pure string-and-datum computation: it reads no
   file and names no editor coordinate, so it sits below the I/O seam with the
   rest of the library. *)

open Pol_syntax

type t =
  | Claims of string  (** the sibling model file this .claims is asked of *)
  | Rules of string  (** the sibling model file this .rules is derived over *)
  | Model
  | Library

(* The sibling model of a .claims or .rules buffer: its basename with the
   extension swapped for .pol (any_model.claims → any_model.pol). *)
let sibling_model (path : string) : string =
  Filename.remove_extension (Filename.basename path) ^ ".pol"

(* A model is exactly a .pol buffer that declares a top-level [(use …)]; without
   one the same file is a library of declarations (kernel §6.1). *)
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
