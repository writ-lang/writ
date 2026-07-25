(* The language server as a process: the only module in [lsp/] that touches a
   file descriptor, and the only one allowed to.

   Binary mode is set FIRST. On a platform where text mode differs, the runtime
   would translate '\n' on the way out and '\r' on the way in; [Content-Length]
   counts the bytes of the body as encoded, so one translated byte leaves the
   reader permanently one short and every later frame is misaligned.

   Nothing but protocol frames is ever written to stdout. A stray line of
   debugging is not a stray line — it is a header the client cannot parse, and
   the session dies naming neither the line nor the module. That is why every
   module below this one returns values and this file has no reporting in it.

   The [resolve] callback is built HERE (I/O lives only in the binary), over the
   search order in [Pol_loadpath] (design D3) that the `pol` command line
   shares — the editor and the CLI must agree about where a library lives, or a
   model passes on one and shows an error on the other. There is NO implicit
   prelude — only the loads a buffer actually writes are read. The document's own
   text is served by the server from the open buffer, so this reader only ever
   sees load targets. *)

open Pol_data
open Pol_lsp
open Pol_loadpath

let read_file path =
  match open_in_bin path with
  | exception Sys_error _ -> None
  | ic ->
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      Some s

(* Decode the percent-escapes in a file:// path so a URI with spaces or unicode
   resolves to the real filename the editor opened. *)
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

(* The search ORDER is [Load_path] (design D3), shared with the `pol` command
   line; only the reading is here, because I/O is. Sharing it is the point: this
   resolver used to carry its own shorter list, so a model whose library sat in
   [core/stdlib] passed `pol check` and showed a red squiggle in the buffer. *)
let resolve uri name : (string, Errors.t) result =
  let rec try_ = function
    | [] -> Error (Load_path.not_found name)
    | p :: rest -> (
        match read_file p with Some s -> Ok s | None -> try_ rest)
  in
  try_ (Load_path.candidates ~base:(path_of_uri uri) name)

(* Header lines up to the blank one, each stripped of its terminator. [None] at
   end of input: the client closed the pipe, which is how a killed editor says
   goodbye. *)
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

(* Exactly one frame, nothing between frames. *)
let write (v : Json.t) =
  output_string stdout (Rpc.encode v);
  flush stdout

(* An absurd Content-Length would try to allocate the world; refuse it rather
   than let the process fall over. *)
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
