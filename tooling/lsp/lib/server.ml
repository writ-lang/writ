(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Routing and lifecycle: one message in, zero or more messages out.

   [handle] is a FUNCTION, not a loop and not a process. Everything that would
   make it one — a file descriptor, a channel — lives in the one executable above
   it, so the whole protocol surface is driven in tests by scripting messages and
   asserting on the list that comes back.

   Two failure modes are designed against, not hoped about.

   NOTHING HERE RAISES. An uncaught exception kills the process; the editor then
   restarts the server silently and gives up with no visible error. Every request
   is wrapped, and an exception becomes a JSON-RPC error response.

   THE URI IS ECHOED, NEVER REBUILT. A file:// URI is percent-encoded, and a path
   reassembled from pieces will not compare equal to the one the client sent —
   diagnostics would publish against a document the editor does not believe is
   open, and nothing would appear.

   The state is the store plus a [resolve] callback INJECTED by the binary: given
   the open document's URI and a [(load …)] target, it reads that target off
   disk. The library itself does no I/O — there is no implicit prelude
   (kernel §0.7): only the loads a buffer actually writes pull anything in. *)

open Pol_data
open Pol_syntax

type state = {
  store : Store.t;
  resolve : string -> string -> (string, Errors.t) result;
}

let create ~resolve = { store = Store.create (); resolve }

(* JSON-RPC 2.0 §5.1 — only the codes this server can actually produce. *)
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

(* textDocumentSync is Full, so each element of [contentChanges] is a whole
   document. When a client batches several, the LAST is what the author is
   looking at — the earlier ones are states already left behind. *)
let changed_text params =
  match Json.member "contentChanges" params with
  | Some (Json.List (_ :: _ as cs)) ->
      string_field "text" (List.nth cs (List.length cs - 1))
  | Some _ | None -> None

(* ------------------------------------------------------------ store views *)

let text_of st uri = Option.map (fun d -> d.Store.text) (Store.get st.store uri)

(* The parse resolver for [uri]: the buffer answers for the model file itself
   (which [Loader.read_model] asks for by basename, so an UNSAVED buffer still
   parses), and every other [(load …)] target defers to the injected disk
   reader. This is the seam that keeps the library free of I/O. *)
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

(* Closing a document does not clear its last-published diagnostics; an empty
   array withdraws them so a closed file leaves nothing in the Problems panel. *)
let withdraw uri = [ published uri [] ]

let opened st uri text =
  Store.set st.store uri text;
  publish st uri

(* ------------------------------------------------------------ intellisense *)

(* Hover and completion share the decoding of their params and the [null] owed a
   client whose document is gone. Both run over the current text through the same
   injected [resolve]; completion offers names while the text does not parse. *)
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

let initialize_result =
  Json.Assoc
    [
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
  (* [initialized] and [exit] are notifications with nothing to answer; ordering
     is not enforced, so a didOpen arriving before [initialized] is honoured. *)
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
      (* A never-opened document is answered with null, not refused: the client
         may have closed it between send and receive. *)
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
  (* An unknown notification is dropped; an unknown request is answered, because
     a client that gets no answer to a request waits for one forever. *)
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

(* After this message the process is expected to be gone; kept here so the loop
   holds no method names of its own. *)
let is_exit (msg : Json.t) =
  match Json.member "method" msg with
  | Some (Json.String "exit") -> true
  | _ -> false

(* A body that is not JSON at all is still framed, so the stream stays intact and
   the server answers rather than stopping. There is no id — it was inside the
   body that would not parse. *)
let malformed (detail : string) : Json.t =
  Rpc.error ~id:Json.Null ~code:parse_error detail
