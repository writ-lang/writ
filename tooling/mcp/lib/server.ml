(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The Model Context Protocol (JSON-RPC 2.0) as a pure function: one message
   in, at most one out, so it can be unit-tested without a process. Methods:
   [initialize] (with [instructions]), [tools/*], [resources/*] (the guide,
   as writ://guide/<topic>), [prompts/*] (one authoring prompt), [ping], and
   notifications.

   A tool that fails (a parse error, an undeclared relation) returns a
   successful result with [isError: true], so the agent sees the message and can
   fix its input; a JSON-RPC error would go only to the client. Protocol faults
   such as an unknown method or tool stay JSON-RPC errors.

   Every model, claims and rules argument is a path OR inline source. Inline
   source is served from memory under a virtual file name (NAME.writ,
   NAME.claims, NAME.rules) by layering it over the injected resolver, so a
   client that cannot write to the server's filesystem can still author. *)

(* The protocol versions this server speaks, newest first. `instructions`
   arrived in 2025-03-26, so a client held to 2024-11-05 may ignore them:
   answer with the client's own version when it is one of these, else the
   newest (the client then decides whether to go on). *)
let protocol_versions = [ "2025-06-18"; "2025-03-26"; "2024-11-05" ]

let negotiate (requested : string option) =
  match requested with
  | Some v when List.mem v protocol_versions -> v
  | _ -> List.hd protocol_versions

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

let bool_ j k =
  match Json.member k j with Some (Json.Bool b) -> Some b | _ -> None

(* [derive] arguments: a null is an unbound column. *)
let args_of j k =
  match Json.member k j with
  | Some (Json.List xs) ->
      Some (List.map (function Json.String s -> Some s | _ -> None) xs)
  | _ -> None

(* ── limits ──────────────────────────────────────────────────────────────── *)

let max_source = 256 * 1024
let default_max = Writ_runtime.Space.cap
let ceiling_max = 2_000_000
let default_timeout_ms = 60_000
let ceiling_timeout_ms = 600_000

(* ── the R4 example: one whole model and its claims ──────────────────────── *)

let example_model =
  "(load \"stdlib.writ\")\n\
   (schema house\n\
  \  (type pos (shut open locked))\n\
  \  (type holder (nobody guest))\n\
  \  (type door (arrow at (to pos)) (arrow key (to holder)))\n\
  \  (equation locked-means-held (not (and (is door.at locked) (is door.key \
   nobody)))))\n\
   (instance start house (door d (at shut) (key guest)))\n\
   (use house)\n\
   (initial start)\n\
   (transition open (when (is d.at shut)) (do (set d.at open)))\n\
   (transition close (when (is d.at open)) (do (set d.at shut)))\n\
   (transition lock (when (is d.at shut)) (do (set d.at locked)))\n\
   (transition drop-key (when (is d.key guest)) (do (set d.key nobody)))\n"

let example_claims =
  "(property can-open \"the door can be opened\" (possible (is d.at open)))\n\
   (property never-trapped \"it can always be opened again\" (live (is d.at \
   open)))\n\
   (property never-lost \"the key is never lost while locked\" (never (and (is \
   d.at locked) (is d.key nobody))))\n"

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

let src_p name what =
  ( name,
    Json.Assoc
      [
        ("type", Json.String "string");
        ("maxLength", Json.Int max_source);
        ( "description",
          Json.String
            ("The " ^ what
           ^ " as inline source text, instead of a path (exactly one of the \
              two). At most 256 KB.") );
      ] )

let json_p =
  p "json" "boolean"
    "Answer as the JSON object `writ … --json` prints (docs/json.md) instead \
     of prose: witnesses carry the situation each move lands in; errors are \
     objects with code, line, col, found, expected, hint, fix."

let name_p =
  p "model_name" "string"
    "A name for an inline model (letters, digits, - and _). Errors cite it as \
     NAME.writ; writ_check keeps revision history per name, so give the same \
     name to every version of one system. History lasts while this server \
     runs. Default: `model`, with no history."

let model_ps =
  [
    p "model" "string" "Path to the .writ model.";
    src_p "model_source" ".writ model";
    name_p;
  ]

let claims_ps what =
  [
    p "claims" "string"
      ("Path to a .claims file" ^ what
     ^ ". Under --claims-dir it is read from that directory by basename.");
    src_p "claims_source" ".claims file";
  ]

let limit_ps =
  [
    p "max_situations" "integer"
      (Printf.sprintf
         "Stop exploring after this many situations (default %d, at most %d)."
         default_max ceiling_max);
    p "timeout_ms" "integer"
      (Printf.sprintf "Stop after this much CPU time (default %d, at most %d)."
         default_timeout_ms ceiling_timeout_ms);
  ]

let at_list_p =
  ( "at",
    Json.Assoc
      [
        ("type", Json.String "array");
        ("items", Json.Assoc [ ("type", Json.String "integer") ]);
        ( "description",
          Json.String
            "Situation indices to show; omit for the initial situation." );
      ] )

let check_description =
  "Build a Writ model's situation space and report it: how many situations and \
   edges, the declared gaps, the dead ends, and whether any law can be broken. \
   With claims it also answers every property — `holds` with a shortest \
   witness route, `fails` with the shortest counterexample — and runs every \
   query. This is the verb to reach for first; the witness under a holding \
   `possible` IS a solution. A property reported `n/a` names structure the \
   model lacks: treat it as a FAILURE, never a pass. When the same claims were \
   checked before (same path, or same model_name), the answer ends with a \
   `revision:` block saying which guarantees this model LOST against the \
   previous one.\n\n\
   Pass `model` (a path) or `model_source` (the text); likewise `claims` or \
   `claims_source`. Inline claims are never found as a sibling file: pass \
   claims_source explicitly. Limits: the search stops at max_situations \
   (default 200000) or timeout_ms (default 60000) and returns E_STATE_LIMIT \
   with the cells driving the growth; nothing is decided then.\n\n\
   A complete model (model_source):\n\n" ^ example_model
  ^ "\nand its claims (claims_source):\n\n" ^ example_claims
  ^ "\n\
     It reports can-open holds (witness: open), never-trapped fails (stuck at \
     the locked door: no move unlocks it), and never-lost fails (lock, \
     drop-key). More: writ_guide."

let descriptors =
  [
    ( "writ_guide",
      "Writ language guide. Call writ_guide({items:[\"index\"]}) BEFORE \
       writing any .writ, .claims or .rules source. Several topics per call is \
       fine: syntax.model, syntax.claims, syntax.rules, semantics, idioms, \
       examples.<name>, errors.<code>. Workflow: writ_validate -> writ_check \
       -> writ_show on each #N -> writ_compare after every edit. A property \
       reported n/a is a failure.",
      obj
        [
          ( "items",
            Json.Assoc
              [
                ("type", Json.String "array");
                ("items", Json.Assoc [ ("type", Json.String "string") ]);
                ( "description",
                  Json.String
                    "Topic names, e.g. index, syntax.model, syntax.claims, \
                     syntax.rules, semantics, idioms, examples.<name>, \
                     errors.<code>" );
              ] );
        ]
        [ "items" ] );
    ( "writ_validate",
      "Parse and type-check a model and, optionally, its claims and rules, \
       WITHOUT building the space: fast, for any size. On success, what the \
       sources declare (types with their values or entities, arrows, laws, \
       moves, the mutable cells and the most situations they allow, properties \
       with their kinds, queries, relations with arity), so you can confirm \
       the model means what you intended. On failure, every error it can find \
       (one per top-level form, up to 20; a syntax error stops the file it is \
       in), each with a code, position, found/expected, a hint and, for a \
       misspelt name, the corrected line. A name in the claims that the model \
       lacks is an error here too. Call it before writ_check.",
      obj
        (model_ps @ claims_ps " to type-check"
        @ [
            p "rules" "string" "Path to a .rules file to type-check.";
            src_p "rules_source" ".rules file";
            json_p;
          ])
        [] );
    ( "writ_check",
      check_description,
      obj
        (model_ps
        @ claims_ps " of properties and queries to answer"
        @ limit_ps @ [ json_p ])
        [] );
    ( "writ_show",
      "Print what a situation IS, by the index a witness step, a derived row \
       or a `stuck at:` line names: its cells, the fewest moves to it, and \
       every move out. Follow a witness with this rather than guessing what \
       `#17` holds. Indices are stable for the same source (the search is \
       deterministic) but NOT across edits: pass the exact source the index \
       came from.",
      obj (model_ps @ [ at_list_p ] @ limit_ps @ [ json_p ]) [] );
    ( "writ_compare",
      "Which guarantees an edit kept, LOST and gained: the old model's claims \
       put to both models, matched by property name. A LOST row (passes \
       before; fails or is n/a after) carries the route through the new model \
       that breaks the guarantee. Price every edit with this before calling it \
       done.",
      obj
        ([
           p "old_model" "string" "Path to the model before the edit.";
           src_p "old_model_source" "model before the edit";
           p "new_model" "string" "Path to the model after it.";
           src_p "new_model_source" "model after the edit";
         ]
        @ claims_ps
            " to put to both (default: the old model's sibling .claims; for an \
             inline old model, pass claims or claims_source)"
        @ limit_ps @ [ json_p ])
        [] );
    ( "writ_query",
      "Run ONE named query from the claims, optionally at a situation other \
       than the initial one. Use when writ_check's full report is more than \
       you need.",
      obj
        (model_ps
        @ claims_ps " holding the query (default: the model's sibling .claims)"
        @ [
            p "name" "string" "The query's name, as written in the claims.";
            p "at" "integer"
              "Optional index into the enumerated space; defaults to the \
               initial situation (0).";
          ]
        @ limit_ps @ [ json_p ])
        [ "name" ] );
    ( "writ_derive",
      "Answer a relation from a .rules file over the model's space. Leave an \
       argument null to ask for every value it can take. With why=true you get \
       the DERIVATION TREE instead of the rows — why the engine believes a \
       fact, down to the model facts it rests on — which needs every argument \
       given.",
      obj
        (model_ps
        @ [
            p "rules" "string" "Path to the .rules file.";
            src_p "rules_source" ".rules file";
            p "relation" "string" "The relation to ask about.";
            ( "args",
              Json.Assoc
                [
                  ("type", Json.String "array");
                  ("items", Json.Assoc [ ("type", Json.String "string") ]);
                  ( "description",
                    Json.String
                      "One entry per column; null leaves that column open. \
                       Omit to leave all of them open." );
                ] );
            p "why" "boolean" "Return the derivation tree instead of the rows.";
          ]
        @ limit_ps @ [ json_p ])
        [ "relation" ] );
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
                   ( "annotations",
                     Json.Assoc [ ("readOnlyHint", Json.Bool true) ] );
                 ])
             descriptors) );
    ]

(* ── instructions, resources, prompt ─────────────────────────────────────── *)

let instructions =
  "Writ is an explicit-state model checker for finite discrete systems: it \
   enumerates every reachable situation of a rule-governed world and answers \
   with a concrete route as evidence.\n\n\
   Before writing any Writ source, call writ_guide with [\"index\"].\n\n\
   Workflow: writ_validate (parse and type-check, instant) -> writ_check \
   (build the space, answer the claims) -> writ_show on any index a witness \
   names -> writ_compare after every edit, old model against new. Sources go \
   inline (model_source, claims_source, rules_source) or as paths.\n\n\
   A property reported n/a is a FAILURE, never a pass: it names structure the \
   model lacks. Do not make a check green by making its question unaskable."

let guide_uri n = "writ://guide/" ^ n

let resource_list () =
  Json.Assoc
    [
      ( "resources",
        Json.List
          (List.map
             (fun (n, body) ->
               Json.Assoc
                 [
                   ("uri", Json.String (guide_uri n));
                   ("name", Json.String ("writ guide: " ^ n));
                   ("description", Json.String (Guide.summary body));
                   ("mimeType", Json.String "text/markdown");
                 ])
             (Guide.topics ())) );
    ]

let prompt_name = "writ_model_system"

let prompt_list =
  Json.Assoc
    [
      ( "prompts",
        Json.List
          [
            Json.Assoc
              [
                ("name", Json.String prompt_name);
                ( "description",
                  Json.String
                    "Model a system described in plain language and check it \
                     with writ." );
                ( "arguments",
                  Json.List
                    [
                      Json.Assoc
                        [
                          ("name", Json.String "description");
                          ( "description",
                            Json.String "The system and what must hold of it."
                          );
                          ("required", Json.Bool true);
                        ];
                    ] );
              ];
          ] );
    ]

let prompt_text description =
  "Model this system in Writ and check it:\n\n" ^ description
  ^ "\n\n\
     1. Call writ_guide with [\"index\", \"semantics\", \"idioms\"] and read \
     them.\n\
     2. List the requirements in plain words. For each, choose the property \
     kind from semantics: never (it must not happen), possible (it can \
     happen), live (it can always still happen), inevitable (it must happen).\n\
     3. Draft the model (model_source) and the claims (claims_source). Keep \
     the space small: estimate the product of every mutable cell's domain.\n\
     4. Call writ_validate until it answers ok; check its summary says what \
     you meant.\n\
     5. Call writ_check. For each failing property, writ_show the stuck or \
     last situation and explain the counterexample in the system's own terms.\n\
     6. After any fix, call writ_compare (old model against new) and report \
     anything LOST."

(* ── arguments ───────────────────────────────────────────────────────────── *)

let ( let* ) = Result.bind

(* One path-or-source argument: [Ok None] when neither is given and it is
   optional. Inline text is added to [overlay] under [virtual_]. *)
let source_arg a ~path ~src ~virtual_ ~required overlay =
  match (str a path, str a src) with
  | Some _, Some _ ->
      Error
        (Fault.arg "E_ARG_CONFLICT"
           ("pass `" ^ path ^ "` or `" ^ src ^ "`, not both"))
  | None, None ->
      if required then
        Error
          (Fault.arg "E_ARG_CONFLICT"
             ("pass `" ^ path ^ "` (a path) or `" ^ src ^ "` (the text)"))
      else Ok None
  | Some f, None -> Ok (Some f)
  | None, Some text ->
      if String.length text > max_source then
        Error
          (Fault.arg "E_SOURCE_TOO_LARGE"
             (Printf.sprintf "`%s` is %d bytes; the limit is %d" src
                (String.length text) max_source))
      else (
        overlay := (virtual_, text) :: !overlay;
        Ok (Some virtual_))

(* Inline text is served under this prefix, which no (load …) names: so an
   inline model can never stand in for a library a pinned claims file loads. *)
let virtual_prefix = "inline:"

let valid_name n =
  n <> "" && n <> "stdlib"
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true | _ -> false)
       n

let int_arg a k ~default ~ceiling =
  match Json.member k a with
  | None | Some Json.Null -> Ok default
  | Some (Json.Int n) when n >= 1 && n <= ceiling -> Ok n
  | Some _ ->
      Error
        (Fault.arg "E_ARG_INVALID"
           (Printf.sprintf "`%s` must be an integer from 1 to %d" k ceiling))

let limits_of a =
  let* max =
    int_arg a "max_situations" ~default:default_max ~ceiling:ceiling_max
  in
  let* ms =
    int_arg a "timeout_ms" ~default:default_timeout_ms
      ~ceiling:ceiling_timeout_ms
  in
  Ok { Tools.max; timeout = Some (float_of_int ms /. 1000.) }

(* [writ_show] indices: a list, or a single integer. *)
let ints_of j k =
  match Json.member k j with
  | Some (Json.List xs) ->
      let is = List.filter_map Json.to_int_opt xs in
      if List.length is = List.length xs then Ok is
      else Error (Fault.arg "E_ARG_INVALID" ("`" ^ k ^ "` must be integers"))
  | Some (Json.Int i) -> Ok [ i ]
  | None | Some Json.Null -> Ok []
  | Some _ -> Error (Fault.arg "E_ARG_INVALID" ("`" ^ k ^ "` must be integers"))

let need a k =
  match str a k with
  | Some s -> Ok s
  | None -> Error (Fault.arg "E_ARG_INVALID" ("missing `" ^ k ^ "`"))

(* ── dispatch ────────────────────────────────────────────────────────────── *)

let call ?certify ?(version = "") ~resolve ?(pinned = None)
    ?(memory = Tools.remember) name (a : Json.t) =
  let json = Option.value (bool_ a "json") ~default:false in
  let overlay = ref [] in
  (* Inline text first, by basename, then whatever [resolve] finds. *)
  let resolve' base =
    let r = resolve base in
    fun n -> match List.assoc_opt n !overlay with Some s -> Ok s | None -> r n
  in
  let read f =
    match (resolve' f) (Filename.basename f) with
    | Ok s -> Some s
    | Error _ -> None
  in
  let files = ref [] in
  let note = function Some f -> files := f :: !files | None -> () in
  let result =
    let* mname =
      match str a "model_name" with
      | None -> Ok None
      | Some n when valid_name n -> Ok (Some n)
      | Some n ->
          Error
            (Fault.arg "E_ARG_INVALID"
               ("`model_name` `" ^ n
              ^ "` must be letters, digits, - and _ (and not `stdlib`)"))
    in
    let stem = Option.value mname ~default:"model" in
    let src ?(stem = stem) ?(required = false) path src ext =
      let* f =
        source_arg a ~path ~src
          ~virtual_:(virtual_prefix ^ stem ^ ext)
          ~required overlay
      in
      note f;
      Ok f
    in
    let model () =
      let* m = src ~required:true "model" "model_source" ".writ" in
      Ok (Option.get m)
    in
    (* Inline claims would let the agent write its own questions. *)
    let claims () =
      if pinned <> None && str a "claims_source" <> None then
        Error
          (Fault.arg "E_CLAIMS_PINNED"
             "this server pins claims (--claims-dir): pass `claims` as a path, \
              not `claims_source`")
      else src "claims" "claims_source" ".claims"
    in
    let inline s = str a s <> None in
    (* An unnamed inline model or claims keeps no history: unrelated drafts
       would otherwise be compared with each other. History is per name. *)
    let memory =
      if (inline "model_source" || inline "claims_source") && mname = None then
        Hashtbl.create 1
      else memory
    in
    (* Inline sources have no sibling .claims to fall back on. *)
    let claims_needed f =
      let* c = claims () in
      if c = None && inline f then
        Error
          (Fault.arg "E_ARG_INVALID"
             ("an inline `" ^ f
            ^ "` has no sibling .claims file: pass `claims` or `claims_source`"
             ))
      else Ok c
    in
    match name with
    | "writ_guide" ->
        let items =
          match Json.member "items" a with
          | Some (Json.List xs) -> List.filter_map Json.to_string_opt xs
          | Some (Json.String s) -> [ s ]
          | _ -> []
        in
        Ok (Guide.get items)
    | "writ_validate" ->
        let* model = model () in
        let* claims = claims () in
        let* rules = src "rules" "rules_source" ".rules" in
        Tools.validate ~json ~pinned ~resolve:resolve' ~model ~claims ~rules ()
    | "writ_check" ->
        let* model = model () in
        let* claims = claims () in
        let* limits = limits_of a in
        Tools.check ~json ~pinned ~memory ?memory_key:mname ?certify ~version
          ~limits ~resolve:resolve' ~model ~claims ()
    | "writ_show" ->
        let* model = model () in
        let* limits = limits_of a in
        let* at = ints_of a "at" in
        Tools.show ~json ~limits ~resolve:resolve' ~model ~at ()
    | "writ_compare" ->
        let* old_model =
          src ~stem:(stem ^ "-old") ~required:true "old_model"
            "old_model_source" ".writ"
        in
        let* new_model =
          src ~stem:(stem ^ "-new") ~required:true "new_model"
            "new_model_source" ".writ"
        in
        let* claims = claims_needed "old_model_source" in
        let* limits = limits_of a in
        Tools.compare ~json ~pinned ~limits ?claims ~resolve:resolve'
          ~old_model:(Option.get old_model) ~new_model:(Option.get new_model) ()
    | "writ_query" ->
        let* model = model () in
        let* claims = claims_needed "model_source" in
        let* n = need a "name" in
        let* limits = limits_of a in
        let* at =
          match Json.member "at" a with
          | None | Some Json.Null -> Ok None
          | Some (Json.Int i) -> Ok (Some i)
          | Some _ ->
              Error (Fault.arg "E_ARG_INVALID" "`at` must be an integer")
        in
        Tools.query ~json ~pinned ~limits ?claims ~resolve:resolve' ~model
          ~name:n ~at ()
    | "writ_derive" ->
        let* model = model () in
        let* rules = src ~required:true "rules" "rules_source" ".rules" in
        let* relation = need a "relation" in
        let* limits = limits_of a in
        Tools.derive ~json ~limits ~resolve:resolve' ~model
          ~rules:(Option.get rules) ~relation ~args:(args_of a "args")
          ~why:(Option.value (bool_ a "why") ~default:false)
          ()
    (* Unreachable: [handle] rejects unknown names first. *)
    | _ -> Error (Fault.arg "E_OTHER" ("no such tool: " ^ name))
  in
  Result.map_error (Diagnose.render ~json ~read ~files:(List.rev !files)) result

(* [certify] runs writ-cert and, like [resolve], is injected by the binary
   because it is I/O. Without it, checks are not certified. *)
let handle ~resolve ?(pinned = None) ?(memory = Tools.remember) ?certify
    ~version (msg : Json.t) : Json.t option =
  let id = Option.value (Json.member "id" msg) ~default:Json.Null in
  let params = Option.value (Json.member "params" msg) ~default:Json.Null in
  match str msg "method" with
  | Some "initialize" ->
      ok id
        (Json.Assoc
           [
             ( "protocolVersion",
               Json.String (negotiate (str params "protocolVersion")) );
             ( "capabilities",
               Json.Assoc
                 [
                   ("tools", Json.Assoc []);
                   ("resources", Json.Assoc []);
                   ("prompts", Json.Assoc []);
                 ] );
             ( "serverInfo",
               Json.Assoc
                 [
                   ("name", Json.String "writ"); ("version", Json.String version);
                 ] );
             ("instructions", Json.String instructions);
           ])
  (* Notifications expect no reply. *)
  | Some "notifications/initialized" | Some "notifications/cancelled" -> None
  | Some "ping" -> ok id (Json.Assoc [])
  | Some "tools/list" -> ok id tool_list
  | Some "resources/list" -> ok id (resource_list ())
  | Some "resources/templates/list" ->
      ok id (Json.Assoc [ ("resourceTemplates", Json.List []) ])
  | Some "resources/read" -> (
      let prefix = guide_uri "" in
      let lp = String.length prefix in
      match str params "uri" with
      | Some u when String.length u > lp && String.sub u 0 lp = prefix -> (
          let n = String.sub u lp (String.length u - lp) in
          match List.assoc_opt n (Guide.topics ()) with
          | Some body ->
              ok id
                (Json.Assoc
                   [
                     ( "contents",
                       Json.List
                         [
                           Json.Assoc
                             [
                               ("uri", Json.String u);
                               ("mimeType", Json.String "text/markdown");
                               ("text", Json.String body);
                             ];
                         ] );
                   ])
          | None -> error id (-32002) ("no such resource: " ^ u))
      | Some u -> error id (-32002) ("no such resource: " ^ u)
      | None -> error id (-32602) "resources/read needs a `uri`")
  | Some "prompts/list" -> ok id prompt_list
  | Some "prompts/get" -> (
      match str params "name" with
      | Some n when n = prompt_name ->
          let args =
            Option.value (Json.member "arguments" params) ~default:Json.Null
          in
          let d =
            Option.value (str args "description")
              ~default:"(describe the system here)"
          in
          ok id
            (Json.Assoc
               [
                 ( "description",
                   Json.String "Model a system in Writ and check it." );
                 ( "messages",
                   Json.List
                     [
                       Json.Assoc
                         [
                           ("role", Json.String "user");
                           ( "content",
                             Json.Assoc
                               [
                                 ("type", Json.String "text");
                                 ("text", Json.String (prompt_text d));
                               ] );
                         ];
                     ] );
               ])
      | Some n -> error id (-32602) ("no such prompt: " ^ n)
      | None -> error id (-32602) "prompts/get needs a `name`")
  | Some "tools/call" -> (
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
