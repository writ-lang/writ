(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The Model Context Protocol, as a pure function: one JSON message in, at most
   one JSON message out. Same shape as the language server's [Server.handle],
   and for the same reason — a protocol you can drive from a unit test without
   a socket is a protocol you can actually test.

   MCP is JSON-RPC 2.0. The four methods below are the whole of what a tools-
   only server owes a client: [initialize], the [notifications/initialized]
   acknowledgement (which expects no reply), [tools/list], and [tools/call].
   [ping] is answered because clients send it to check the process is alive.

   ONE THING IS EASY TO GET WRONG, and it decides whether this server is useful.
   A tool that FAILS — a model that will not parse, a relation that is not
   declared — must come back as a SUCCESSFUL JSON-RPC result carrying
   [isError: true], not as a JSON-RPC error. A JSON-RPC error is a transport
   fault: the client handles it and the model never sees it. An [isError]
   result is content the model reads, which for a parse error is precisely what
   it needs in order to fix the file. Protocol faults — an unknown method,
   a call naming no tool — stay JSON-RPC errors, because no amount of reading
   them helps a model. *)

let protocol_version = "2024-11-05"

(* ── JSON-RPC plumbing ───────────────────────────────────────────────────── *)

let ok id result =
  Some
    (Json.Assoc
       [ ("jsonrpc", Json.String "2.0"); ("id", id); ("result", result) ])

let error id code msg =
  Some
    (Json.Assoc
       [
         ("jsonrpc", Json.String "2.0");
         ("id", id);
         ( "error",
           Json.Assoc [ ("code", Json.Int code); ("message", Json.String msg) ]
         );
       ])

let text ?(is_error = false) s =
  Json.Assoc
    [
      ( "content",
        Json.List
          [
            Json.Assoc [ ("type", Json.String "text"); ("text", Json.String s) ];
          ] );
      ("isError", Json.Bool is_error);
    ]

let str j k = Option.bind (Json.member k j) Json.to_string_opt
let int_ j k = Option.bind (Json.member k j) Json.to_int_opt

let bool_ j k =
  match Json.member k j with Some (Json.Bool b) -> Some b | _ -> None

(* An argument list for [derive]: JSON nulls are the unbound positions, so
   ["a", null] asks for every tuple whose first column is `a`. *)
let args_of j k =
  match Json.member k j with
  | Some (Json.List xs) ->
      Some (List.map (function Json.String s -> Some s | _ -> None) xs)
  | _ -> None

(* ── the tools ───────────────────────────────────────────────────────────── *)

let obj props required =
  Json.Assoc
    [
      ("type", Json.String "object");
      ("properties", Json.Assoc props);
      ("required", Json.List (List.map (fun s -> Json.String s) required));
    ]

let p name ty desc =
  ( name,
    Json.Assoc [ ("type", Json.String ty); ("description", Json.String desc) ]
  )

let descriptors =
  [
    ( "writ_check",
      "Build a Writ model's situation space and report it: how many situations \
       and edges, the declared gaps, the dead ends, and whether any law can be \
       broken. With a .claims file it also answers every property — `holds` \
       with a shortest witness route, `fails` with the shortest counterexample \
       — and runs every query. This is the verb to reach for first; the \
       witness under a holding `possible` IS a solution.",
      obj
        [
          p "model" "string" "Path to the .writ model.";
          p "claims" "string"
            "Optional path to a .claims file of properties and queries to \
             answer.";
        ]
        [ "model" ] );
    ( "writ_query",
      "Run ONE named query from the model's sibling .claims file, optionally \
       at a situation other than the initial one. Use when writ_check's full \
       report is more than you need.",
      obj
        [
          p "model" "string" "Path to the .writ model.";
          p "name" "string" "The query's name, as written in the .claims file.";
          p "at" "integer"
            "Optional index into the enumerated space; defaults to the initial \
             situation (0).";
        ]
        [ "model"; "name" ] );
    ( "writ_derive",
      "Answer a relation from a .rules file over the model's space. Leave an \
       argument null to ask for every value it can take. With why=true you get \
       the DERIVATION TREE instead of the rows — why the engine believes a \
       fact, down to the model facts it rests on — which needs every argument \
       given.",
      obj
        [
          p "model" "string" "Path to the .writ model.";
          p "rules" "string" "Path to the .rules file.";
          p "relation" "string" "The relation to ask about.";
          ( "args",
            Json.Assoc
              [
                ("type", Json.String "array");
                ("items", Json.Assoc [ ("type", Json.String "string") ]);
                ( "description",
                  Json.String
                    "One entry per column; null leaves that column open. Omit \
                     to leave all of them open." );
              ] );
          p "why" "boolean" "Return the derivation tree instead of the rows.";
        ]
        [ "model"; "rules"; "relation" ] );
  ]

let tool_list =
  Json.Assoc
    [
      ( "tools",
        Json.List
          (List.map
             (fun (n, d, schema) ->
               Json.Assoc
                 [
                   ("name", Json.String n);
                   ("description", Json.String d);
                   ("inputSchema", schema);
                 ])
             descriptors) );
    ]

(* ── dispatch ────────────────────────────────────────────────────────────── *)

let call ~resolve name (a : Json.t) =
  let need k =
    match str a k with Some s -> Ok s | None -> Error ("missing `" ^ k ^ "`")
  in
  let ( let* ) = Result.bind in
  match name with
  | "writ_check" ->
      let* model = need "model" in
      Tools.check ~resolve ~model ~claims:(str a "claims")
  | "writ_query" ->
      let* model = need "model" in
      let* n = need "name" in
      Tools.query ~resolve ~model ~name:n ~at:(int_ a "at")
  | "writ_derive" ->
      let* model = need "model" in
      let* rules = need "rules" in
      let* relation = need "relation" in
      Tools.derive ~resolve ~model ~rules ~relation ~args:(args_of a "args")
        ~why:(Option.value (bool_ a "why") ~default:false)
  (* Unreachable: [handle] rejects an unknown name before getting here, so
     this arm exists only to make the match total. *)
  | _ -> Error ("no such tool: " ^ name)

let handle ~resolve ~version (msg : Json.t) : Json.t option =
  let id = Option.value (Json.member "id" msg) ~default:Json.Null in
  match str msg "method" with
  | Some "initialize" ->
      ok id
        (Json.Assoc
           [
             ("protocolVersion", Json.String protocol_version);
             ("capabilities", Json.Assoc [ ("tools", Json.Assoc []) ]);
             ( "serverInfo",
               Json.Assoc
                 [
                   ("name", Json.String "writ"); ("version", Json.String version);
                 ] );
           ])
  (* Notifications carry no id and expect no reply; answering one is a protocol
     error the client is entitled to complain about. *)
  | Some "notifications/initialized" | Some "notifications/cancelled" -> None
  | Some "ping" -> ok id (Json.Assoc [])
  | Some "tools/list" -> ok id tool_list
  | Some "tools/call" -> (
      let params = Option.value (Json.member "params" msg) ~default:Json.Null in
      match str params "name" with
      | None -> error id (-32602) "tools/call needs a `name`"
      (* An unknown tool is a PROTOCOL fault, not a tool failure: the client
         was given the list and asked for something not on it, and no amount of
         a model reading that helps. Tool failures below are the other kind. *)
      | Some name when not (List.exists (fun (n, _, _) -> n = name) descriptors)
        ->
          error id (-32602) ("no such tool: " ^ name)
      | Some name -> (
          let a =
            Option.value
              (Json.member "arguments" params)
              ~default:(Json.Assoc [])
          in
          match call ~resolve name a with
          | Ok s -> ok id (text s)
          (* A tool that failed still answers: see the header. *)
          | Error e -> ok id (text ~is_error:true e)))
  | Some m -> error id (-32601) ("no such method: " ^ m)
  | None -> error id (-32600) "not a JSON-RPC request: no `method`"
