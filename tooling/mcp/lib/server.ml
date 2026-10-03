(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The Model Context Protocol (JSON-RPC 2.0) as a pure function: one message
   in, at most one out, so it can be unit-tested without a process. A tools-only
   server: [initialize], [tools/list], [tools/call], [ping], and notifications.

   A tool that fails (a parse error, an undeclared relation) returns a
   successful result with [isError: true], so the agent sees the message and can
   fix its input; a JSON-RPC error would go only to the client. Protocol faults
   such as an unknown method or tool stay JSON-RPC errors. *)

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

(* [derive] arguments: a null is an unbound column. *)
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

let json_p =
  p "json" "boolean"
    "Answer as the JSON object `writ … --json` prints (docs/json.md) instead \
     of prose: witnesses carry the situation each move lands in."

let descriptors =
  [
    ( "writ_check",
      "Build a Writ model's situation space and report it: how many situations \
       and edges, the declared gaps, the dead ends, and whether any law can be \
       broken. With a .claims file it also answers every property — `holds` \
       with a shortest witness route, `fails` with the shortest counterexample \
       — and runs every query. This is the verb to reach for first; the \
       witness under a holding `possible` IS a solution. A property reported \
       `n/a` names structure the model lacks: treat it as a FAILURE, never a \
       pass. When the same claims file was checked before, the answer ends \
       with a `revision:` block saying which guarantees this model LOST \
       against the previous one — an edit that makes one property pass by \
       losing another is reported in the same reply.",
      obj
        [
          p "model" "string" "Path to the .writ model.";
          p "claims" "string"
            "Optional path to a .claims file of properties and queries to \
             answer. If the server was started with --claims-dir, the file is \
             read from that directory by its basename, whatever path is given.";
          json_p;
        ]
        [ "model" ] );
    ( "writ_show",
      "Print what a situation IS, by the index a witness step, a derived row \
       or a `stuck at:` line names: its cells, the fewest moves to it, and \
       every move out. Follow a witness with this rather than guessing what \
       `#17` holds.",
      obj
        [
          p "model" "string" "Path to the .writ model.";
          ( "at",
            Json.Assoc
              [
                ("type", Json.String "array");
                ("items", Json.Assoc [ ("type", Json.String "integer") ]);
                ( "description",
                  Json.String
                    "Situation indices to show; omit for the initial situation."
                );
              ] );
          json_p;
        ]
        [ "model" ] );
    ( "writ_compare",
      "Which guarantees an edit kept, LOST and gained: the old model's sibling \
       .claims put to both models. Price your own edit with this before \
       calling it done — a LOST row carries the route through the new model \
       that breaks the guarantee.",
      obj
        [
          p "old_model" "string" "Path to the model before the edit.";
          p "new_model" "string" "Path to the model after it.";
          json_p;
        ]
        [ "old_model"; "new_model" ] );
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
          json_p;
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
          json_p;
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

(* [writ_show] indices: a list, or a single integer. *)
let ints_of j k =
  match Json.member k j with
  | Some (Json.List xs) -> List.filter_map Json.to_int_opt xs
  | Some (Json.Int i) -> [ i ]
  | _ -> []

let call ?certify ?(version = "") ~resolve ?(pinned = None)
    ?(memory = Tools.remember) name (a : Json.t) =
  let need k =
    match str a k with Some s -> Ok s | None -> Error ("missing `" ^ k ^ "`")
  in
  let json = Option.value (bool_ a "json") ~default:false in
  let ( let* ) = Result.bind in
  match name with
  | "writ_check" ->
      let* model = need "model" in
      Tools.check ~json ~pinned ~memory ?certify ~version ~resolve ~model
        ~claims:(str a "claims") ()
  | "writ_show" ->
      let* model = need "model" in
      Tools.show ~json ~resolve ~model ~at:(ints_of a "at") ()
  | "writ_compare" ->
      let* old_model = need "old_model" in
      let* new_model = need "new_model" in
      Tools.compare ~json ~pinned ~resolve ~old_model ~new_model ()
  | "writ_query" ->
      let* model = need "model" in
      let* n = need "name" in
      Tools.query ~json ~pinned ~resolve ~model ~name:n ~at:(int_ a "at") ()
  | "writ_derive" ->
      let* model = need "model" in
      let* rules = need "rules" in
      let* relation = need "relation" in
      Tools.derive ~json ~resolve ~model ~rules ~relation
        ~args:(args_of a "args")
        ~why:(Option.value (bool_ a "why") ~default:false)
        ()
  (* Unreachable: [handle] rejects unknown names first. *)
  | _ -> Error ("no such tool: " ^ name)

(* [certify] runs writ-cert and, like [resolve], is injected by the binary
   because it is I/O. Without it, checks are not certified. *)
let handle ~resolve ?(pinned = None) ?(memory = Tools.remember) ?certify
    ~version (msg : Json.t) : Json.t option =
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
  (* Notifications expect no reply. *)
  | Some "notifications/initialized" | Some "notifications/cancelled" -> None
  | Some "ping" -> ok id (Json.Assoc [])
  | Some "tools/list" -> ok id tool_list
  | Some "tools/call" -> (
      let params = Option.value (Json.member "params" msg) ~default:Json.Null in
      match str params "name" with
      | None -> error id (-32602) "tools/call needs a `name`"
      (* An unknown tool is a protocol fault (see the header). *)
      | Some name when not (List.exists (fun (n, _, _) -> n = name) descriptors)
        ->
          error id (-32602) ("no such tool: " ^ name)
      | Some name -> (
          let a =
            Option.value
              (Json.member "arguments" params)
              ~default:(Json.Assoc [])
          in
          match call ?certify ~version ~resolve ~pinned ~memory name a with
          | Ok s -> ok id (text s)
          (* A tool that failed still answers: see the header. *)
          | Error e -> ok id (text ~is_error:true e)))
  | Some m -> error id (-32601) ("no such method: " ^ m)
  | None -> error id (-32600) "not a JSON-RPC request: no `method`"
