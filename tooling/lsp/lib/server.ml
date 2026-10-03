(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Routing and lifecycle: [handle] maps one message to the messages to send.
   The binary injects [resolve], which reads [(load …)] targets off disk.

   Nothing here raises: an exception would kill the process, so each request
   is wrapped and an exception becomes a JSON-RPC error. The URI is echoed,
   never rebuilt, or it may not match the client's and diagnostics go nowhere. *)

open Writ_data
open Writ_syntax

type state = {
  store : Store.t;
  resolve : string -> string -> (string, Errors.t) result;
}

let create ~resolve = { store = Store.create (); resolve }

(* JSON-RPC 2.0 §5.1 error codes. *)
let method_not_found = -32601
let invalid_params = -32602
let internal_error = -32603
let parse_error = -32700
let invalid_request = -32600

(* ------------------------------------------------------------ params *)

let string_field k v = Option.bind (Json.member k v) Json.to_string_opt

let uri_of params =
  Option.bind (Json.member "textDocument" params) (string_field "uri")

let position_of params =
  Option.bind (Json.member "position" params) Text.position_of_json

(* textDocumentSync is Full, so each change is a whole document; when a client
   batches several, the last is current. *)
let changed_text params =
  match Json.member "contentChanges" params with
  | Some (Json.List (_ :: _ as cs)) ->
      string_field "text" (List.nth cs (List.length cs - 1))
  | Some _ | None -> None

(* ------------------------------------------------------------ store views *)

let text_of st uri = Option.map (fun d -> d.Store.text) (Store.get st.store uri)

(* The buffer answers for its own file, so an unsaved buffer still parses. *)
let doc_resolve st uri text : Loader.resolve =
 fun name ->
  if String.equal name (Filename.basename uri) then Ok text
  else st.resolve uri name

(* ------------------------------------------------------------ responses *)

let reply id result =
  match id with None -> [] | Some id -> [ Rpc.response ~id result ]

let fail id ~code msg =
  match id with None -> [] | Some id -> [ Rpc.error ~id ~code msg ]

let published uri ds =
  Rpc.notification "textDocument/publishDiagnostics"
    (Json.Assoc [ ("uri", Json.String uri); ("diagnostics", Json.List ds) ])

let publish st uri =
  let text = Option.value (text_of st uri) ~default:"" in
  let t = Text.of_string text in
  [
    published uri
      (Diagnostics.of_text t ~resolve:(doc_resolve st uri text) ~path:uri);
  ]

(* An empty array withdraws a closed file's diagnostics. *)
let withdraw uri = [ published uri [] ]

let opened st uri text =
  Store.set st.store uri text;
  publish st uri

(* ------------------------------------------------------------ intellisense *)

(* Hover and completion; [null] when the document is gone. *)
let point st ~meth ~uri ~pos =
  match text_of st uri with
  | None -> Json.Null
  | Some text -> (
      let t = Text.of_string text in
      let resolve = doc_resolve st uri text in
      match meth with
      | "textDocument/hover" -> (
          match Lookup.hover t ~resolve pos with
          | Some h -> h
          | None -> Json.Null)
      | _ -> Json.List (Completion.at t ~resolve pos))

(* ------------------------------------------------------------- dispatch *)

(* [serverInfo] says which writ is answering; [Version.v] matches
   `writ --version`. *)
let initialize_result =
  Json.Assoc
    [
      ( "serverInfo",
        Json.Assoc
          [
            ("name", Json.String "writ-lsp"); ("version", Json.String Version.v);
          ] );
      ( "capabilities",
        Json.Assoc
          [
            ("textDocumentSync", Json.Int 1);
            ("hoverProvider", Json.Bool true);
            ("documentSymbolProvider", Json.Bool true);
            ( "completionProvider",
              Json.Assoc
                [
                  ( "triggerCharacters",
                    Json.List [ Json.String "("; Json.String " " ] );
                ] );
          ] );
    ]

let dispatch st ~id ~meth ~params =
  match meth with
  | "initialize" -> reply id initialize_result
  (* Ordering is not enforced: a didOpen before [initialized] is honoured. *)
  | "initialized" | "exit" -> []
  | "shutdown" -> reply id Json.Null
  | "textDocument/didOpen" -> (
      match Json.member "textDocument" params with
      | None -> []
      | Some td -> (
          match (string_field "uri" td, string_field "text" td) with
          | Some uri, Some text -> opened st uri text
          | _ -> []))
  | "textDocument/didChange" -> (
      match (uri_of params, changed_text params) with
      | Some uri, Some text -> opened st uri text
      | _ -> [])
  | "textDocument/didClose" -> (
      match uri_of params with
      | Some uri ->
          Store.remove st.store uri;
          withdraw uri
      | None -> [])
  | "textDocument/documentSymbol" -> (
      match uri_of params with
      | None ->
          fail id ~code:invalid_params "params.textDocument.uri is missing"
      (* An unknown document gets null: the client may have just closed it. *)
      | Some uri -> (
          match text_of st uri with
          | None -> reply id Json.Null
          | Some text ->
              reply id (Json.List (Outline.of_text (Text.of_string text)))))
  | "textDocument/hover" | "textDocument/completion" -> (
      match (uri_of params, position_of params) with
      | None, _ ->
          fail id ~code:invalid_params "params.textDocument.uri is missing"
      | _, None -> fail id ~code:invalid_params "params.position is missing"
      | Some uri, Some pos -> reply id (point st ~meth ~uri ~pos))
  (* An unknown request must be answered, or the client waits forever; an
     unknown notification is dropped. *)
  | _ -> fail id ~code:method_not_found ("no such method: " ^ meth)

let handle (st : state) (msg : Json.t) : Json.t list =
  let id = Json.member "id" msg in
  match Option.bind (Json.member "method" msg) Json.to_string_opt with
  | None -> fail id ~code:invalid_request "no method in the request"
  | Some meth -> (
      let params =
        match Json.member "params" msg with Some p -> p | None -> Json.Null
      in
      try dispatch st ~id ~meth ~params
      with e ->
        fail id ~code:internal_error (meth ^ ": " ^ Printexc.to_string e))

let is_exit (msg : Json.t) =
  match Json.member "method" msg with
  | Some (Json.String "exit") -> true
  | _ -> false

(* The error for a body that is not JSON, which has no id to echo. *)
let malformed (detail : string) : Json.t =
  Rpc.error ~id:Json.Null ~code:parse_error detail
