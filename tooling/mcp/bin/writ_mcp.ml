(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The MCP server as a process: the only module in [mcp/] that touches a file
   descriptor, and the only one allowed to.

   FRAMING IS NOT THE LSP'S. MCP's stdio transport is newline-delimited JSON —
   one message per line, and a message may not contain an embedded newline.
   There is no [Content-Length] header. Getting this wrong is not a subtle bug:
   the client reads a header that never arrives and the session hangs with no
   message on either side. [Json.to_string] emits no newlines, so one write per
   message is one line.

   NOTHING BUT PROTOCOL LINES IS EVER WRITTEN TO STDOUT. A stray line of
   debugging is a message the client cannot parse. Diagnostics, if there were
   any, would go to stderr — which is why every module below this one returns
   values and this file has no reporting in it.

   The [resolve] callback is built HERE, over the same [Writ_loadpath] search
   order (design D3) the `writ` command line and the language server share: a
   model that passes on the command line must not fail here because a library
   was looked for somewhere else. *)

open Writ_loadpath

let read_file path =
  match open_in_bin path with
  | exception Sys_error _ -> None
  | ic ->
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      Some s

(* A resolver for one including file: the search order, read from disk. *)
let resolve_for (base : string) : Writ_syntax.Loader.resolve =
 fun name ->
  let rec first = function
    | [] -> Error (Load_path.not_found name)
    | p :: rest -> (
        match read_file p with Some s -> Ok s | None -> first rest)
  in
  first (Load_path.candidates ~base name)

(* One line in, at most one line out. A line that is not JSON gets a JSON-RPC
   parse error rather than silence: a client that sent something malformed is
   entitled to be told, and a server that answers nothing looks hung. *)
let respond line =
  match Json_parse.parse line with
  | Error e ->
      Some
        (Json.Assoc
           [
             ("jsonrpc", Json.String "2.0");
             ("id", Json.Null);
             ( "error",
               Json.Assoc
                 [
                   ("code", Json.Int (-32700));
                   ("message", Json.String ("parse error: " ^ e));
                 ] );
           ])
  | Ok msg ->
      Writ_mcp.Server.handle ~resolve:resolve_for ~version:Writ_mcp.Version.v msg

let () =
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  let rec loop () =
    match input_line stdin with
    | exception End_of_file -> ()
    | "" -> loop () (* a blank line is not a message; clients send them *)
    | line ->
        (match respond line with
        | None -> ()
        | Some out ->
            print_string (Json.to_string out);
            print_newline ();
            flush stdout);
        loop ()
  in
  loop ()
