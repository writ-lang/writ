(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The MCP server process: the only module in [mcp/] that does I/O.

   MCP's stdio transport is newline-delimited JSON, one message per line, with
   no [Content-Length] header (unlike LSP). [Json.to_string] emits no newlines.

   Stdout is the protocol stream: nothing else may be written to it.

   Loads use the same [Writ_loadpath] search order (D3) as the CLI and LSP. *)

open Writ_loadpath

let read_file path =
  match open_in_bin path with
  | exception Sys_error _ -> None
  | ic ->
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      Some s

(* Runs writ-cert as `writ check` does (tooling/cli/certifier.ml). Its output
   goes to a temp file, since stdout is the protocol stream. *)
let certify (cert : Json.t) : Certify_json.verdict =
  let checker =
    match Sys.getenv_opt "WRIT_CERT" with
    | Some p when p <> "" -> p
    | _ ->
        let beside =
          Filename.concat (Filename.dirname Sys.executable_name) "writ-cert"
        in
        if Sys.file_exists beside then beside else "writ-cert"
  in
  let file = Filename.temp_file "writ-mcp-" ".cert.json" in
  let out = Filename.temp_file "writ-cert-" ".txt" in
  let oc = open_out_bin file in
  output_string oc (Json.to_string cert);
  close_out oc;
  let code =
    Sys.command
      (Filename.quote checker ^ " " ^ Filename.quote file ^ " > "
     ^ Filename.quote out ^ " 2>&1 < /dev/null")
  in
  let output =
    match read_file out with
    | Some s -> String.split_on_char '\n' s
    | None -> []
  in
  List.iter (fun f -> try Sys.remove f with Sys_error _ -> ()) [ file; out ];
  Certify_json.verdict_of_run ~code ~output

(* A resolver for one including file: the search order, read from disk. *)
let resolve_for (base : string) : Writ_syntax.Loader.resolve =
 fun name ->
  let rec first = function
    | [] -> Error (Load_path.not_found name)
    | p :: rest -> (
        match read_file p with Some s -> Ok s | None -> first rest)
  in
  first (Load_path.candidates ~base name)

(* `writ-mcp [--claims-dir DIR] [--root DIR]`.

   --claims-dir: every claims file is read from DIR by basename, whatever path
   a tool call names, so the agent editing the model cannot also edit its
   questions.

   --root (or $WRIT_MCP_ROOT): the directory relative paths resolve against.
   A client may start the server anywhere — Claude Desktop through WSL starts
   it in C:\Windows\System32 — so the server moves there before it reads a
   line. Paths given on the command line are taken relative to where it was
   started. *)
let usage () =
  prerr_endline "usage: writ-mcp [--claims-dir DIR] [--root DIR]";
  exit 2

let absolute d =
  if Filename.is_relative d then Filename.concat (Sys.getcwd ()) d else d

let pinned, root =
  let rec go pinned root = function
    | [] -> (pinned, root)
    | "--claims-dir" :: d :: rest -> go (Some (absolute d)) root rest
    | "--root" :: d :: rest -> go pinned (Some (absolute d)) rest
    | _ -> usage ()
  in
  let pinned, root = go None None (List.tl (Array.to_list Sys.argv)) in
  let root =
    match root with
    | Some _ -> root
    | None -> (
        match Sys.getenv_opt "WRIT_MCP_ROOT" with
        | Some d when d <> "" -> Some (absolute d)
        | _ -> None)
  in
  (pinned, root)

let () =
  Option.iter
    (fun d ->
      try Sys.chdir d
      with Sys_error e ->
        prerr_endline ("writ-mcp: --root: " ^ e);
        exit 2)
    root

(* One line in, at most one line out; a line that is not JSON gets a JSON-RPC
   parse error rather than silence. *)
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
      Writ_mcp.Server.handle ~resolve:resolve_for ~pinned ~certify
        ~version:Writ_mcp.Version.v msg

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
