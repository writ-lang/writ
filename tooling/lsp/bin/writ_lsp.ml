(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The language server process: the only module in [lsp/] that does I/O.
   Binary mode is set first, since one translated byte breaks every later
   Content-Length. Only protocol frames may go to stdout. *)

open Writ_data
open Writ_lsp
open Writ_loadpath

let read_file path =
  match open_in_bin path with
  | exception Sys_error _ -> None
  | ic ->
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      Some s

let percent_decode s =
  let n = String.length s in
  let buf = Buffer.create n in
  let hex c =
    match c with
    | '0' .. '9' -> Char.code c - Char.code '0'
    | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
    | 'A' .. 'F' -> Char.code c - Char.code 'A' + 10
    | _ -> -1
  in
  let rec go i =
    if i >= n then ()
    else if s.[i] = '%' && i + 2 < n && hex s.[i + 1] >= 0 && hex s.[i + 2] >= 0
    then (
      Buffer.add_char buf (Char.chr ((hex s.[i + 1] * 16) + hex s.[i + 2]));
      go (i + 3))
    else (
      Buffer.add_char buf s.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents buf

let path_of_uri uri =
  let p = "file://" in
  if
    String.length uri >= String.length p
    && String.sub uri 0 (String.length p) = p
  then
    percent_decode
      (String.sub uri (String.length p) (String.length uri - String.length p))
  else uri

(* The [Load_path] search order (design D3), shared with the CLI so both agree
   on where a library lives. *)
let resolve uri name : (string, Errors.t) result =
  let rec try_ = function
    | [] -> Error (Load_path.not_found name)
    | p :: rest -> (
        match read_file p with Some s -> Ok s | None -> try_ rest)
  in
  try_ (Load_path.candidates ~base:(path_of_uri uri) name)

(* Header lines up to the blank one, terminators stripped. [None] at end of
   input: the client closed the pipe. *)
let read_headers () =
  let chomp s =
    let n = String.length s in
    if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s
  in
  let rec go acc =
    match input_line stdin with
    | exception End_of_file -> if acc = [] then None else Some (List.rev acc)
    | line ->
        let line = chomp line in
        if String.equal line "" then Some (List.rev acc) else go (line :: acc)
  in
  go []

let write (v : Json.t) =
  output_string stdout (Rpc.encode v);
  flush stdout

(* Refuse an absurd Content-Length rather than try to allocate it. *)
let max_body = 32 * 1024 * 1024

let rec loop st =
  match read_headers () with
  | None -> ()
  | Some headers -> (
      match Rpc.header_len headers with
      | Error m -> write (Server.malformed m)
      | Ok len when len > max_body ->
          write (Server.malformed "Content-Length too large")
      | Ok len -> (
          match really_input_string stdin len with
          | exception End_of_file -> ()
          | body ->
              let out, quit =
                match Json_parse.parse body with
                | Error m -> ([ Server.malformed m ], false)
                | Ok msg -> (Server.handle st msg, Server.is_exit msg)
              in
              List.iter write out;
              if not quit then loop st))

let () =
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  loop (Server.create ~resolve)
