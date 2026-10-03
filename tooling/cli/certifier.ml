(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Runs writ-cert on a certificate `writ check` just wrote. The checker is
   looked up in $WRIT_CERT, beside this executable, then on the PATH; a missing
   one is reported as a verdict, not an error. *)

open Cli_io

let checker () : string =
  match Sys.getenv_opt "WRIT_CERT" with
  | Some p when p <> "" -> p
  | _ ->
      let beside =
        Filename.concat (Filename.dirname Sys.executable_name) "writ-cert"
      in
      if Sys.file_exists beside then beside else "writ-cert"

let run (file : string) : Certify_json.verdict =
  let out = Filename.temp_file "writ-cert-" ".txt" in
  let code =
    Sys.command
      (Filename.quote (checker ())
      ^ " " ^ Filename.quote file ^ " > " ^ Filename.quote out ^ " 2>&1")
  in
  let output =
    match read_file out with
    | Ok s -> String.split_on_char '\n' s
    | Error _ -> []
  in
  (try Sys.remove out with Sys_error _ -> ());
  Certify_json.verdict_of_run ~code ~output
