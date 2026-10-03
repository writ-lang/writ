(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* MCP tests: [Server.handle] is pure, so the protocol is driven with no
   process. A failing tool must answer `isError: true`, not a JSON-RPC error,
   which the client hides from the model. *)

open Writ_data

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let contains ~sub s =
  let ls = String.length s and n = String.length sub in
  let rec go i =
    if i + n > ls then false
    else if String.sub s i n = sub then true
    else go (i + 1)
  in
  go 0

(* --- fixtures, served in memory ------------------------------------------- *)

let model_src =
  "(schema tiny\n\
  \  (type flag (lo hi))\n\
  \  (type box (arrow f (to flag))))\n\
   (instance i tiny  (box b (f lo))  )\n\
   (use tiny)\n\
   (initial i)\n\
   (transition raise (when (is b.f lo)) (do (set b.f hi)))\n"

let claims_src =
  "(property reachable \"hi is reachable\" (possible (is b.f hi)))\n"

(* The same world without the move. *)
let stuck_src =
  "(schema tiny\n\
  \  (type flag (lo hi))\n\
  \  (type box (arrow f (to flag))))\n\
   (instance i tiny  (box b (f lo))  )\n\
   (use tiny)\n\
   (initial i)\n"

let files =
  [
    ("tiny.writ", model_src);
    ("tiny.claims", claims_src);
    ("stuck.writ", stuck_src);
    ("stuck.claims", claims_src);
  ]

let resolve _base name : (string, Errors.t) result =
  match List.assoc_opt name files with
  | Some s -> Ok s
  | None -> Error { Errors.pos = None; msg = "no such file: " ^ name }

let memory : Writ_mcp.Tools.memory = Hashtbl.create 4

let handle ?(pinned = None) msg =
  Writ_mcp.Server.handle ~resolve ~pinned ~memory ~version:"test" msg

(* --- message helpers ------------------------------------------------------ *)

let req ?(id = 1) m params =
  let base =
    [
      ("jsonrpc", Json.String "2.0");
      ("id", Json.Int id);
      ("method", Json.String m);
    ]
  in
  Json.Assoc
    (match params with None -> base | Some p -> base @ [ ("params", p) ])

let call name args =
  req "tools/call"
    (Some
       (Json.Assoc
          [ ("name", Json.String name); ("arguments", Json.Assoc args) ]))

let result = function Some j -> Json.member "result" j | None -> None

let content j =
  match Option.bind j (Json.member "content") with
  | Some (Json.List (c :: _)) ->
      Option.value
        (Option.bind (Json.member "text" c) Json.to_string_opt)
        ~default:""
  | _ -> ""

let is_error j =
  match Option.bind j (Json.member "isError") with
  | Some (Json.Bool b) -> b
  | _ -> false

(* --- 1. initialize -------------------------------------------------------- *)

let () =
  let r = result (handle (req "initialize" None)) in
  check "initialize: answers a protocolVersion"
    (Option.bind r (Json.member "protocolVersion") <> None);
  check "initialize: names itself and its version"
    (match Option.bind r (Json.member "serverInfo") with
    | Some si ->
        Option.bind (Json.member "name" si) Json.to_string_opt = Some "writ"
        && Option.bind (Json.member "version" si) Json.to_string_opt
           = Some "test"
    | None -> false);
  check "initialize: declares the tools capability"
    (match Option.bind r (Json.member "capabilities") with
    | Some c -> Json.member "tools" c <> None
    | None -> false)

(* --- 2. a notification is answered with nothing --------------------------- *)

let () =
  let n =
    Json.Assoc
      [
        ("jsonrpc", Json.String "2.0");
        ("method", Json.String "notifications/initialized");
      ]
  in
  check "a notification gets no reply at all" (handle n = None)

(* --- 3. tools/list, and everything on it is callable ---------------------- *)

let () =
  let r = result (handle (req "tools/list" None)) in
  let tools =
    match Option.bind r (Json.member "tools") with
    | Some (Json.List xs) -> xs
    | _ -> []
  in
  let name t = Option.bind (Json.member "name" t) Json.to_string_opt in
  check "tools/list: lists tools" (List.length tools >= 3);
  check "tools/list: every tool has a name, a description and a schema"
    (List.for_all
       (fun t ->
         name t <> None
         && Json.member "description" t <> None
         && Json.member "inputSchema" t <> None)
       tools);
  (* No arguments may give a missing-argument error, never "no such tool". *)
  check "tools/list: every tool it advertises is implemented"
    (List.for_all
       (fun t ->
         match name t with
         | None -> false
         | Some n ->
             let j = handle (call n []) in
             Option.bind j (Json.member "error") = None)
       tools)

(* --- 4. a real answer, and a real failure -------------------------------- *)

let () =
  let r =
    result (handle (call "writ_check" [ ("model", Json.String "tiny.writ") ]))
  in
  check "writ_check: answers" (not (is_error r));
  check "writ_check: reports the space" (contains ~sub:"states:" (content r))

let () =
  let r =
    result
      (handle
         (call "writ_check"
            [
              ("model", Json.String "tiny.writ");
              ("claims", Json.String "tiny.claims");
            ]))
  in
  check "writ_check: with claims, answers the property"
    (contains ~sub:"holds  reachable" (content r))

let () =
  let r =
    result (handle (call "writ_check" [ ("model", Json.String "absent.writ") ]))
  in
  check "a failing tool answers isError, not a JSON-RPC error" (is_error r);
  check "and carries the engine's own message"
    (contains ~sub:"absent.writ" (content r))

let () =
  let r = result (handle (call "writ_check" [])) in
  check "a missing required argument is an isError, and says which"
    (is_error r && contains ~sub:"model" (content r))

(* --- 5. an unknown tool is a PROTOCOL error ------------------------------- *)

let () =
  let j = handle (call "writ_nonesuch" []) in
  check "an unknown tool is a JSON-RPC error, not content"
    (Option.bind j (Json.member "error") <> None);
  check "an unknown method is a JSON-RPC error"
    (Option.bind (handle (req "nosuch/method" None)) (Json.member "error")
    <> None)

(* --- the verifier an agent cannot argue with ------------------------------- *)

let tool ?(id = 9) ?pinned name args =
  result
  @@ handle ?pinned
       (req ~id "tools/call"
          (Some
             (Json.Assoc
                [ ("name", Json.String name); ("arguments", Json.Assoc args) ])))

let () =
  (* show: a situation by index, and an index the model lacks is a tool error *)
  let r =
    tool "writ_show"
      [ ("model", Json.String "tiny.writ"); ("at", Json.List [ Json.Int 1 ]) ]
  in
  check "writ_show: answers" (not (is_error r));
  check "writ_show: names the situation"
    (contains ~sub:"situation 1 of 2" (content r));
  let r =
    tool "writ_show"
      [ ("model", Json.String "tiny.writ"); ("at", Json.List [ Json.Int 7 ]) ]
  in
  check "writ_show: an index the model lacks is an isError" (is_error r);
  (* json: the object `writ … --json` prints, as the text *)
  let r =
    tool "writ_check"
      [
        ("model", Json.String "tiny.writ");
        ("claims", Json.String "tiny.claims");
        ("json", Json.Bool true);
      ]
  in
  check "json: the reply parses as JSON"
    (match Json_parse.parse (content r) with
    | Ok (Json.Assoc _) -> true
    | _ -> false);
  check "json: and carries the verdict"
    (contains ~sub:"\"verdict\":\"holds\"" (content r));
  (* compare: the edit that deletes the move LOSES the guarantee *)
  let r =
    tool "writ_compare"
      [
        ("old_model", Json.String "tiny.writ");
        ("new_model", Json.String "stuck.writ");
      ]
  in
  check "writ_compare: answers" (not (is_error r));
  check "writ_compare: the deleted move loses reachable"
    (contains ~sub:"reachable" (content r) && contains ~sub:"LOST" (content r));
  (* revision: the second check against the same claims says what was lost *)
  Hashtbl.reset memory;
  let r1 =
    tool "writ_check"
      [
        ("model", Json.String "tiny.writ"); ("claims", Json.String "tiny.claims");
      ]
  in
  check "revision: the first check has nothing to compare against"
    (not (contains ~sub:"revision:" (content r1)));
  let r2 =
    tool "writ_check"
      [
        ("model", Json.String "stuck.writ");
        ("claims", Json.String "tiny.claims");
      ]
  in
  check "revision: the second check reports the loss"
    (contains
       ~sub:
         "revision: against the previous model checked with tiny.claims — a \
          guarantee was LOST"
       (content r2)
    && contains ~sub:"reachable" (content r2));
  let r3 =
    tool "writ_check"
      [
        ("model", Json.String "stuck.writ");
        ("claims", Json.String "tiny.claims");
        ("json", Json.Bool true);
      ]
  in
  check "revision: in JSON it is the compare object"
    (contains ~sub:"\"revision\":{" (content r3)
    && contains ~sub:"nothing lost" (content r3) = false);
  (* pinned: the claims path is taken by basename under the pinned directory *)
  let r =
    tool ~pinned:(Some "the-humans") "writ_check"
      [
        ("model", Json.String "tiny.writ");
        ("claims", Json.String "/anywhere/the/agent/likes/tiny.claims");
      ]
  in
  check "pinned: the claims are read from the pinned directory"
    (contains ~sub:"claims: the-humans/tiny.claims   (pinned)" (content r))

let () =
  print_string ("mcp tests: " ^ string_of_int !passed ^ " checks passed\n")
