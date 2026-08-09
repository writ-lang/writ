(* MCP tests (rule 6): [Server.handle] is pure — one JSON message in, at most
   one out — so the whole protocol surface is driven here with no process, no
   pipe and no client. The [resolve] is injected, so the tool calls read fixture
   text from an in-memory map exactly as the binary's disk reader would.

   What is pinned, and why each one is a mistake worth catching:

     1. [initialize] answers with a protocol version and a serverInfo — a client
        that gets neither hangs waiting for a handshake.
     2. [notifications/initialized] answers NOTHING. Replying to a notification
        is a protocol error the client is entitled to complain about, and it is
        the easiest thing in a dispatch to get wrong by falling through.
     3. [tools/list] names every tool with an inputSchema, and every tool it
        names is actually callable — a list that advertises a tool the dispatch
        does not implement is worse than one that omits it.
     4. A tool that FAILS answers `isError: true` with the engine's own message,
        NOT a JSON-RPC error. This is the one that decides whether the server is
        useful: a JSON-RPC error is handled by the client and the model never
        sees it, so a parse error would reach the model as silence.
     5. A tool that does not exist IS a JSON-RPC error, because reading it helps
        nobody — the client had the list. *)

open Pol_data

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

let files = [ ("tiny.pol", model_src); ("tiny.claims", claims_src) ]

let resolve _base name : (string, Errors.t) result =
  match List.assoc_opt name files with
  | Some s -> Ok s
  | None -> Error { Errors.pos = None; msg = "no such file: " ^ name }

let handle msg = Pol_mcp.Server.handle ~resolve ~version:"test" msg

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
        Option.bind (Json.member "name" si) Json.to_string_opt = Some "pol"
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
  (* The list is a promise. Calling each advertised tool with no arguments must
     not come back "no such tool" — a missing argument is fine, a missing
     implementation is not. *)
  check "tools/list: every tool it advertises is implemented"
    (List.for_all
       (fun t ->
         match name t with
         | None -> false
         | Some n ->
             let j = handle (call n []) in
             (* a protocol error would mean the dispatch does not know it *)
             Option.bind j (Json.member "error") = None)
       tools)

(* --- 4. a real answer, and a real failure -------------------------------- *)

let () =
  let r =
    result (handle (call "pol_check" [ ("model", Json.String "tiny.pol") ]))
  in
  check "pol_check: answers" (not (is_error r));
  check "pol_check: reports the space" (contains ~sub:"states:" (content r))

let () =
  let r =
    result
      (handle
         (call "pol_check"
            [
              ("model", Json.String "tiny.pol");
              ("claims", Json.String "tiny.claims");
            ]))
  in
  check "pol_check: with claims, answers the property"
    (contains ~sub:"holds  reachable" (content r))

let () =
  let r =
    result (handle (call "pol_check" [ ("model", Json.String "absent.pol") ]))
  in
  (* The point of the whole design: the model must SEE this. *)
  check "a failing tool answers isError, not a JSON-RPC error" (is_error r);
  check "and carries the engine's own message"
    (contains ~sub:"absent.pol" (content r))

let () =
  let r = result (handle (call "pol_check" [])) in
  check "a missing required argument is an isError, and says which"
    (is_error r && contains ~sub:"model" (content r))

(* --- 5. an unknown tool is a PROTOCOL error ------------------------------- *)

let () =
  let j = handle (call "pol_nonesuch" []) in
  check "an unknown tool is a JSON-RPC error, not content"
    (Option.bind j (Json.member "error") <> None);
  check "an unknown method is a JSON-RPC error"
    (Option.bind (handle (req "nosuch/method" None)) (Json.member "error")
    <> None)

let () =
  print_string ("mcp tests: " ^ string_of_int !passed ^ " checks passed\n")
