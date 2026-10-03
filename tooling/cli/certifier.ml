(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Certifier] — the second opinion `writ check` asks for after every answer.

   A certificate nobody checks protects nobody, so `writ check` does not leave
   checking to a separate step a user would have to remember: having written
   MODEL.cert.json, it hands it to `writ-cert` (lean/: a checker proved sound
   against the kernel semantics) and ends its report with what came back.

   writ still NEEDS nothing. The checker is found, not required — $WRIT_CERT,
   then beside this executable, then the PATH — and its absence is said out
   loud rather than passed over, because a silent skip is indistinguishable
   from a pass. Stdlib only ([Sys.command] + a temp file), as [Cmd_compare]'s
   git call is: no [unix] dependency for one child process. *)

open Cli_io

type verdict =
  | Certified
  | Disagrees of string list  (** writ-cert refuted writ: a bug in writ *)
  | Partial of string list  (** some answers could not be certified *)
  | Absent  (** no writ-cert to ask *)
  | Failed of string  (** writ-cert ran and could not read the certificate *)

(* Where the checker is: an explicit override, then the release layout (it
   ships beside writ), then whatever the PATH finds. *)
let checker () : string =
  match Sys.getenv_opt "WRIT_CERT" with
  | Some p when p <> "" -> p
  | _ ->
      let beside =
        Filename.concat (Filename.dirname Sys.executable_name) "writ-cert"
      in
      if Sys.file_exists beside then beside else "writ-cert"

let starts_with p s =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

let run (file : string) : verdict =
  let out = Filename.temp_file "writ-cert-" ".txt" in
  let cmd =
    Filename.quote (checker ())
    ^ " " ^ Filename.quote file ^ " > " ^ Filename.quote out ^ " 2>&1"
  in
  let code = Sys.command cmd in
  let lines =
    match read_file out with
    | Ok s -> String.split_on_char '\n' s
    | Error _ -> []
  in
  (try Sys.remove out with Sys_error _ -> ());
  let tagged p = List.filter (starts_with p) lines in
  match code with
  | 0 -> Certified
  | 1 -> Disagrees (tagged "DISAGREES")
  | 3 -> Partial (tagged "uncertified")
  (* 127: the shell found no such command; 126: found, not runnable *)
  | 126 | 127 -> Absent
  | _ -> Failed (String.concat " " (List.filter (( <> ) "") lines))

(* The closing line of the prose report. *)
let line : verdict -> string = function
  | Certified -> "certified: every answer re-derived from the model (writ-cert)"
  | Disagrees ls ->
      String.concat "\n"
        ("NOT CERTIFIED: writ-cert refutes this report — a bug in writ:"
        :: List.map (fun l -> "  " ^ l) ls)
  | Partial ls ->
      String.concat "\n"
        ("partly certified: writ-cert could not certify:"
        :: List.map (fun l -> "  " ^ l) ls)
  | Absent -> "not certified: writ-cert is not installed (docs/certificates.md)"
  | Failed e -> "not certified: writ-cert failed: " ^ e

let json : verdict -> Json.t =
  let obj status ls =
    Json.Assoc
      [
        ("status", Json.String status);
        ("lines", Json.List (List.map (fun l -> Json.String l) ls));
      ]
  in
  function
  | Certified -> obj "certified" []
  | Disagrees ls -> obj "disagrees" ls
  | Partial ls -> obj "partial" ls
  | Absent -> obj "absent" []
  | Failed e -> obj "failed" [ e ]
