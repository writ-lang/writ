(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* JSON-RPC 2.0 framing, without I/O. A frame is [Content-Length: N\r\n\r\n]
   then the body, where N is the body's byte length, not its code points. *)

(* The body length from the header lines; the name is case-insensitive and
   other headers are ignored. *)
let header_len (headers : string list) : (int, string) result =
  let lower = String.lowercase_ascii in
  let found = ref None in
  List.iter
    (fun line ->
      match String.index_opt line ':' with
      | None -> ()
      | Some i ->
          let name = lower (String.trim (String.sub line 0 i)) in
          if String.equal name "content-length" then
            let value =
              String.trim (String.sub line (i + 1) (String.length line - i - 1))
            in
            found := Some value)
    headers;
  match !found with
  | None -> Error "no Content-Length header"
  | Some value -> (
      match int_of_string_opt value with
      | Some len when len >= 0 -> Ok len
      | _ -> Error ("unparsable Content-Length: " ^ value))

let encode (j : Json.t) : string =
  let body = Json.to_string j in
  "Content-Length: " ^ string_of_int (String.length body) ^ "\r\n\r\n" ^ body

let response ~id result =
  Json.Assoc [ ("jsonrpc", Json.String "2.0"); ("id", id); ("result", result) ]

let error ~id ~code msg =
  Json.Assoc
    [
      ("jsonrpc", Json.String "2.0");
      ("id", id);
      ( "error",
        Json.Assoc [ ("code", Json.Int code); ("message", Json.String msg) ] );
    ]

let notification meth params =
  Json.Assoc
    [
      ("jsonrpc", Json.String "2.0");
      ("method", Json.String meth);
      ("params", params);
    ]
