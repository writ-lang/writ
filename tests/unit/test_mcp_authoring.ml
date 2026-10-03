(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Authoring through MCP: a client that knows nothing of Writ and cannot write
   to the server's filesystem must be able to learn the language (writ_guide,
   instructions, the example in writ_check), send sources inline, fix its
   errors from the error alone, and be told when a model is too big.

   Also the guide's own promises: every example in it still produces the
   output it shows, every error code's wrong example raises that code and its
   right example validates, and no topic outgrows its budget. *)

open Writ_data

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let contains ~sub s =
  let ls = String.length s and n = String.length sub in
  let rec go i = i + n <= ls && (String.sub s i n = sub || go (i + 1)) in
  go 0

(* dune runs tests from _build/default/tests/unit, so walk up to the root. *)
let repo_root () =
  let rec up dir n =
    if Sys.file_exists (Filename.concat dir "core/stdlib/stdlib.writ") then dir
    else if n = 0 then dir
    else up (Filename.dirname dir) (n - 1)
  in
  up (Sys.getcwd ()) 8

let read_file p =
  match open_in_bin p with
  | exception Sys_error _ -> None
  | ic ->
      let s = really_input_string ic (in_channel_length ic) in
      close_in ic;
      Some s

(* Only the standard library is on disk: everything else must come inline. *)
let resolve _base name : (string, Errors.t) result =
  match read_file (Filename.concat (repo_root ()) ("core/stdlib/" ^ name)) with
  | Some s -> Ok s
  | None -> Error { Errors.pos = None; msg = "cannot resolve load: " ^ name }

let memory : Writ_mcp.Tools.memory = Hashtbl.create 4

let handle ?(pinned = None) msg =
  Writ_mcp.Server.handle ~resolve ~pinned ~memory ~version:"test" msg

let req ?(id = 1) m params =
  Json.Assoc
    ([
       ("jsonrpc", Json.String "2.0");
       ("id", Json.Int id);
       ("method", Json.String m);
     ]
    @ match params with None -> [] | Some p -> [ ("params", p) ])

let result = function Some j -> Json.member "result" j | None -> None
let s x = Json.String x

(* A tool call: (is-error, text). *)
let tool ?pinned name args =
  let r =
    result
      (handle ?pinned
         (req "tools/call"
            (Some
               (Json.Assoc [ ("name", s name); ("arguments", Json.Assoc args) ]))))
  in
  let text =
    match Option.bind r (Json.member "content") with
    | Some (Json.List (c :: _)) ->
        Option.value
          (Option.bind (Json.member "text" c) Json.to_string_opt)
          ~default:""
    | _ -> ""
  in
  let err =
    match Option.bind r (Json.member "isError") with
    | Some (Json.Bool b) -> b
    | _ -> false
  in
  (err, text)

let lines t = String.split_on_char '\n' t

(* ── initialize: instructions ───────────────────────────────────────────── *)

let () =
  let r = result (handle (req "initialize" None)) in
  let ins =
    Option.bind (Option.bind r (Json.member "instructions")) Json.to_string_opt
  in
  check "initialize: sets instructions" (ins <> None);
  let ins = Option.value ins ~default:"" in
  check "instructions: under 1500 characters" (String.length ins < 1500);
  check "instructions: send the client to writ_guide index first"
    (contains ~sub:"call writ_guide with [\"index\"]" ins);
  check "instructions: give the workflow"
    (contains ~sub:"writ_validate" ins
    && contains ~sub:"writ_compare" ins
    && contains ~sub:"writ_show" ins);
  check "instructions: n/a is a failure" (contains ~sub:"n/a is a FAILURE" ins);
  check "initialize: declares resources and prompts"
    (match Option.bind r (Json.member "capabilities") with
    | Some c ->
        Json.member "resources" c <> None && Json.member "prompts" c <> None
    | None -> false)

(* ── tools/list ─────────────────────────────────────────────────────────── *)

let tools =
  match
    Option.bind (result (handle (req "tools/list" None))) (Json.member "tools")
  with
  | Some (Json.List xs) -> xs
  | _ -> []

let tool_named n =
  List.find_opt
    (fun t -> Option.bind (Json.member "name" t) Json.to_string_opt = Some n)
    tools

let description n =
  Option.value
    (Option.bind
       (Option.bind (tool_named n) (Json.member "description"))
       Json.to_string_opt)
    ~default:""

let () =
  check "tools/list: writ_guide and writ_validate are listed"
    (tool_named "writ_guide" <> None && tool_named "writ_validate" <> None);
  check "tools/list: every tool is marked read-only"
    (List.for_all
       (fun t ->
         match
           Option.bind
             (Json.member "annotations" t)
             (Json.member "readOnlyHint")
         with
         | Some (Json.Bool true) -> true
         | _ -> false)
       tools);
  check "writ_guide: its description says to call it first"
    (contains ~sub:"BEFORE" (description "writ_guide"));
  check "writ_check: documents the default limits"
    (contains ~sub:"200000" (description "writ_check")
    && contains ~sub:"60000" (description "writ_check"))

(* ── R4: the example in writ_check's description runs as described ──────── *)

let model = Writ_mcp.Server.example_model
let claims = Writ_mcp.Server.example_claims

let () =
  let d = description "writ_check" in
  check "writ_check: carries the example model and claims"
    (contains ~sub:model d && contains ~sub:claims d);
  let n t =
    List.length (List.filter (fun l -> String.trim l <> "") (lines t))
  in
  check "the example is at most 25 lines" (n model + n claims <= 25);
  let err, out =
    tool "writ_check" [ ("model_source", s model); ("claims_source", s claims) ]
  in
  check "the example checks inline" (not err);
  check "the example: can-open holds" (contains ~sub:"holds  can-open" out);
  check "the example: never-trapped fails"
    (contains ~sub:"fails  never-trapped" out);
  check "the example: never-lost fails" (contains ~sub:"fails  never-lost" out);
  check "the example: the law is broken"
    (contains ~sub:"equation locked-means-held" out)

(* ── R1: inline sources ─────────────────────────────────────────────────── *)

let base = Writ_mcp.Diagnose.base

let () =
  let _, out =
    tool "writ_check" [ ("model_source", s model); ("claims_source", s claims) ]
  in
  (* every index a witness names resolves through writ_show, same source *)
  let idx =
    List.filter_map
      (fun l ->
        match String.index_opt l '#' with
        | Some i ->
            let j = ref (i + 1) in
            while !j < String.length l && l.[!j] >= '0' && l.[!j] <= '9' do
              incr j
            done;
            int_of_string_opt (String.sub l (i + 1) (!j - i - 1))
        | None -> None)
      (lines out)
  in
  check "witnesses name indices" (idx <> []);
  List.iter
    (fun i ->
      let err, shown =
        tool "writ_show"
          [ ("model_source", s model); ("at", Json.List [ Json.Int i ]) ]
      in
      check
        ("writ_show resolves witness index " ^ string_of_int i)
        ((not err)
        && contains ~sub:("situation " ^ string_of_int i ^ " of") shown))
    idx;
  let err, out =
    tool "writ_check" [ ("model", s "x.writ"); ("model_source", s base) ]
  in
  check "path and source together: E_ARG_CONFLICT"
    (err && contains ~sub:"E_ARG_CONFLICT" out);
  let err, out = tool "writ_check" [] in
  check "neither path nor source: E_ARG_CONFLICT"
    (err && contains ~sub:"E_ARG_CONFLICT" out);
  let err, out =
    tool "writ_check" [ ("model_source", s (String.make (300 * 1024) ' ')) ]
  in
  check "an oversized source: E_SOURCE_TOO_LARGE"
    (err && contains ~sub:"E_SOURCE_TOO_LARGE" out);
  let err, out =
    tool ~pinned:(Some "humans") "writ_check"
      [
        ("model_source", s base);
        ("claims_source", s "(property p \"x\" (possible (is a.stage done)))");
      ]
  in
  check "pinned claims refuse inline claims: E_CLAIMS_PINNED"
    (err && contains ~sub:"E_CLAIMS_PINNED" out);
  let err, out =
    tool "writ_check" [ ("model_source", s base); ("model_name", s "../x") ]
  in
  check "a model_name with a path in it is refused"
    (err && contains ~sub:"E_ARG_INVALID" out);
  let err, out =
    tool "writ_query"
      [
        ("model_source", s base);
        ("claims_source", s "(query where (where (j job)) (is j.stage queued))");
        ("name", s "where");
      ]
  in
  check "writ_query: inline claims" ((not err) && contains ~sub:"j = a" out);
  let err, out =
    tool "writ_derive"
      [
        ("model_source", s base);
        ( "rules_source",
          s
            "(relation done 1)\n\
             (rule (done S) (situation S) (holds S (is a.stage done)))\n" );
        ("relation", s "done");
      ]
  in
  check "writ_derive: inline rules"
    ((not err) && contains ~sub:"done  (1 row)" out)

(* ── revision history per model_name ────────────────────────────────────── *)

let () =
  (* finish can never fire: a stays running *)
  let stuck =
    Writ_mcp.Diagnose.replace base
      [
        ( "(transition finish (when (is a.stage running))",
          "(transition finish (when (is a.stage done))" );
      ]
  in
  let cl =
    "(property finishes \"it can finish\" (possible (is a.stage done)))\n"
  in
  let run ?name m =
    tool "writ_check"
      ([ ("model_source", s m); ("claims_source", s cl) ]
      @ match name with Some n -> [ ("model_name", s n) ] | None -> [])
  in
  Hashtbl.reset memory;
  let _, first = run ~name:"shop" base in
  check "revision: first named check has none"
    (not (contains ~sub:"revision:" first));
  let _, second = run ~name:"shop" stuck in
  check "revision: the second named check reports the LOST guarantee"
    (contains ~sub:"a guarantee was LOST" second
    && contains ~sub:"finishes" second);
  let _, _ = run base in
  let _, unnamed = run stuck in
  check "revision: unnamed inline models keep no history"
    (not (contains ~sub:"revision:" unnamed))

(* ── compare inline: the handoff regression ─────────────────────────────── *)

let guide_topic n =
  List.assoc_opt n (Writ_mcp.Guide.topics ()) |> Option.value ~default:""

(* The fenced blocks of a topic: (info string, body). *)
let blocks body =
  let rec go acc cur = function
    | [] -> List.rev acc
    | l :: rest -> (
        match cur with
        | None ->
            if String.length l >= 3 && String.sub l 0 3 = "```" then
              go acc
                (Some (String.trim (String.sub l 3 (String.length l - 3)), []))
                rest
            else go acc None rest
        | Some (info, ls) ->
            if String.trim l = "```" then
              go
                ((info, String.concat "\n" (List.rev ls) ^ "\n") :: acc)
                None rest
            else go acc (Some (info, l :: ls)) rest)
  in
  go [] None (lines body)

let words s = List.filter (( <> ) "") (String.split_on_char ' ' s)

let kv info k =
  List.find_map
    (fun w ->
      let p = k ^ "=" in
      let n = String.length p in
      if String.length w > n && String.sub w 0 n = p then
        Some (String.sub w n (String.length w - n))
      else None)
    (words info)

let strip_cert t =
  String.concat "\n"
    (List.filter (fun l -> not (contains ~sub:"certified" l)) (lines t))
  |> String.trim

(* ── the guide's examples still do what the guide says ──────────────────── *)

let () =
  let examples =
    List.filter
      (fun n -> String.length n > 9 && String.sub n 0 9 = "examples.")
      (Writ_mcp.Guide.names ())
  in
  check "the guide has 4-6 examples"
    (List.length examples >= 4 && List.length examples <= 6);
  List.iter
    (fun ex ->
      let bs = blocks (guide_topic ex) in
      let files =
        List.filter_map
          (fun (info, b) -> Option.map (fun f -> (f, b)) (kv info "file"))
          bs
      in
      let src f =
        match List.assoc_opt f files with
        | Some b -> s b
        | None ->
            check (ex ^ ": names a file it defines: " ^ f) false;
            s ""
      in
      let outputs =
        List.filter
          (fun (info, _) ->
            String.length info > 5 && String.sub info 0 5 = "text ")
          bs
      in
      check (ex ^ ": shows tool output") (outputs <> []);
      List.iter
        (fun (info, expected) ->
          let get k = Option.value (kv info k) ~default:"" in
          let _, actual =
            match words info with
            | _ :: "writ_check" :: _ ->
                tool "writ_check"
                  [
                    ("model_source", src (get "model"));
                    ("claims_source", src (get "claims"));
                  ]
            | _ :: "writ_compare" :: _ ->
                tool "writ_compare"
                  [
                    ("old_model_source", src (get "old"));
                    ("new_model_source", src (get "new"));
                    ("claims_source", src (get "claims"));
                  ]
            | _ -> (true, "unknown tool in " ^ info)
          in
          let ok = strip_cert actual = strip_cert expected in
          if not ok then
            print_string
              ("--- expected\n" ^ expected ^ "--- actual\n" ^ actual ^ "\n");
          check (ex ^ ": " ^ info ^ " matches the guide") ok)
        outputs)
    examples;
  (* syntax topics: their whole model, claims and rules validate together *)
  let first_lisp n =
    List.find_map
      (fun (info, b) -> if info = "lisp" then Some b else None)
      (blocks (guide_topic n))
  in
  match
    ( first_lisp "syntax.model",
      first_lisp "syntax.claims",
      first_lisp "syntax.rules" )
  with
  | Some m, Some c, Some r ->
      let law =
        Writ_mcp.Diagnose.replace m
          [
            ( "(arrow uses (to machine) fixed)))",
              "(arrow uses (to machine) fixed))\n\
              \  (equation one-holder (not (and (is job.stage running) (not \
               (defined job.uses.held-by))))))" );
          ]
      in
      let err, out =
        tool "writ_validate"
          [
            ("model_source", s law);
            ("claims_source", s c);
            ("rules_source", s r);
          ]
      in
      if err then print_string out;
      check "syntax.*: the topics' examples validate together" (not err)
  | _ -> check "syntax.*: each topic has a lisp example" false

(* ── R6: every code's wrong example raises it; its right one validates ──── *)

let validate_example (ex : Writ_mcp.Diagnose.example) =
  match ex with
  | Writ_mcp.Diagnose.Model m ->
      Some (tool "writ_validate" [ ("model_source", s m) ])
  | Writ_mcp.Diagnose.Claims c ->
      Some
        (tool "writ_validate"
           [ ("model_source", s base); ("claims_source", s c) ])
  | Writ_mcp.Diagnose.Rules r ->
      Some
        (tool "writ_validate"
           [ ("model_source", s base); ("rules_source", s r) ])
  | Writ_mcp.Diagnose.Call _ -> None

let () =
  List.iter
    (fun (e : Writ_mcp.Diagnose.entry) ->
      (match validate_example e.wrong with
      | Some (err, out) ->
          if not (err && contains ~sub:("error " ^ e.code ^ " ") out) then
            print_string out;
          check
            (e.code ^ ": its wrong example raises it")
            (err && contains ~sub:("error " ^ e.code ^ " ") out)
      | None -> ());
      match validate_example e.right with
      | Some (err, out) ->
          if err then print_string out;
          check (e.code ^ ": its right example validates") (not err)
      | None -> ())
    Writ_mcp.Diagnose.codes;
  (* the Call examples, driven directly *)
  let err, out =
    tool "writ_show"
      [ ("model_source", s base); ("at", Json.List [ Json.Int 99 ]) ]
  in
  check "E_NO_SITUATION: an index out of range"
    (err && contains ~sub:"E_NO_SITUATION" out);
  let err, out = tool "writ_query" [ ("model_source", s base) ] in
  check "E_ARG_INVALID: a missing name"
    (err && contains ~sub:"E_ARG_INVALID" out);
  let err, out =
    tool "writ_check"
      [ ("model_source", s base); ("max_situations", Json.Int 0) ]
  in
  check "E_ARG_INVALID: a limit out of range"
    (err && contains ~sub:"E_ARG_INVALID" out);
  (* every code has its guide topic *)
  List.iter
    (fun (e : Writ_mcp.Diagnose.entry) ->
      check
        ("errors." ^ e.code ^ " is a guide topic")
        (guide_topic ("errors." ^ e.code) <> ""))
    Writ_mcp.Diagnose.codes

(* ── R6: the acceptance case: a misspelt name, fixed from the error alone ── *)

let () =
  let typo =
    Writ_mcp.Diagnose.replace base
      [ ("(set a.stage running)", "(set a.stage runing)") ]
  in
  let err, out =
    tool "writ_validate" [ ("model_source", s typo); ("json", Json.Bool true) ]
  in
  check "typo: an error" err;
  let d =
    match Json_parse.parse out with
    | Ok j -> (
        match Json.member "errors" j with
        | Some (Json.List (d :: _)) -> Some d
        | _ -> None)
    | Error _ -> None
  in
  let field k =
    Option.bind (Option.bind d (Json.member k)) Json.to_string_opt
  in
  let int_field k =
    Option.bind (Option.bind d (Json.member k)) Json.to_int_opt
  in
  check "typo: E_UNKNOWN_VALUE" (field "code" = Some "E_UNKNOWN_VALUE");
  check "typo: names the source" (field "source" = Some "model");
  check "typo: found the misspelling" (field "found" = Some "runing");
  check "typo: line and column"
    (int_field "line" = Some 8 && int_field "col" <> None);
  check "typo: expected lists the value meant"
    (match Option.bind d (Json.member "expected") with
    | Some (Json.List (Json.String "running" :: _)) -> true
    | _ -> false);
  check "typo: see points at the guide"
    (field "see" = Some "writ_guide errors.E_UNKNOWN_VALUE");
  match field "fix" with
  | None -> check "typo: carries a fix" false
  | Some fix ->
      let broken = List.nth (lines typo) 7 in
      let fixed =
        String.concat "\n"
          (List.mapi (fun i l -> if i = 7 then fix else l) (lines typo))
      in
      check "typo: the fix replaces the offending line"
        (String.trim broken <> fix);
      let err, _ = tool "writ_validate" [ ("model_source", s fixed) ] in
      check "typo: applying the fix validates" (not err)

(* ── a modality from another logic gets its Writ spelling ──────────────── *)

let () =
  let _, out =
    tool "writ_validate"
      [
        ("model_source", s base);
        ("claims_source", s "(property p \"x\" (always (is a.stage done)))");
      ]
  in
  check "always: the hint gives (never (not P))"
    (contains ~sub:"(never (not P))" out)

(* ── review and acceptance fixes ──────────────────────────────────────── *)

let () =
  (* a typo in claims is an error at validate, with the name meant *)
  let err, out =
    tool "writ_validate"
      [
        ("model_source", s base);
        ( "claims_source",
          s "(property done \"x\"\n  (possible (is a.stage don)))\n" );
      ]
  in
  check "claims typo: validate reports it"
    (err && contains ~sub:"E_UNKNOWN_VALUE in claims" out);
  check "claims typo: positioned on the name"
    (contains ~sub:"inline:model.claims:2:" out);
  check "claims typo: with the fix"
    (contains ~sub:"fix:      (possible (is a.stage done)))" out);
  (* and writ_check says why the property is n/a *)
  let _, out =
    tool "writ_check"
      [
        ("model_source", s base);
        ("claims_source", s "(property done \"x\" (possible (is a.stage don)))");
      ]
  in
  check "n/a: check says why, with the name meant"
    (contains
       ~sub:
         "why n/a  done: value don not in codomain stage-t — did you mean \
          `done`?"
       out);
  (* inline models have no sibling claims *)
  let err, out =
    tool "writ_compare"
      [ ("old_model_source", s base); ("new_model_source", s base) ]
  in
  check "compare: inline old model needs claims"
    (err && contains ~sub:"pass `claims` or `claims_source`" out);
  let err, out =
    tool "writ_query" [ ("model_source", s base); ("name", s "q") ]
  in
  check "query: inline model needs claims"
    (err && contains ~sub:"E_ARG_INVALID" out);
  (* an inline model is never what a (load …) reads *)
  let err, out =
    tool "writ_validate"
      [
        ("model_source", s base);
        ( "claims_source",
          s "(load \"model.writ\")\n(load \"inline:model.writ\")\n" );
      ]
  in
  check "overlay: a load does not read the inline model"
    (err && contains ~sub:"E_LOAD" out);
  (* arithmetic gets the no-numbers hint, naming what is unknown *)
  let plus =
    Writ_mcp.Diagnose.replace base
      [
        ( "(use shop)",
          "(form (bump J) (transition (when (is J.stage queued)) (do (+ \
           J.stage 1))))\n\
           (use shop)" );
      ]
  in
  let _, out = tool "writ_validate" [ ("model_source", s plus) ] in
  if not (contains ~sub:"no numbers" out) then print_string out;
  check "arithmetic: the hint says there are no numbers"
    (contains ~sub:"no numbers or arithmetic" out);
  (* bad `at` is refused, not read as 0 *)
  let err, _ =
    tool "writ_show" [ ("model_source", s base); ("at", Json.List [ s "3" ]) ]
  in
  check "at: a string index is refused" err;
  (* an instance error has no invented position *)
  let unset =
    Writ_mcp.Diagnose.replace base [ ("(job a) (stage (a queued))", "(job a)") ]
  in
  let _, js =
    tool "writ_validate" [ ("model_source", s unset); ("json", Json.Bool true) ]
  in
  check "instance error: no made-up line" (not (contains ~sub:"\"line\"" js));
  (* history is per model_name *)
  Hashtbl.reset memory;
  let cl =
    "(property finishes \"it can finish\" (possible (is a.stage done)))\n"
  in
  let stuck =
    Writ_mcp.Diagnose.replace base
      [
        ( "(transition finish (when (is a.stage running))",
          "(transition finish (when (is a.stage done))" );
      ]
  in
  let _ =
    tool "writ_check"
      [
        ("model_source", s base);
        ("claims_source", s cl);
        ("model_name", s "one");
      ]
  in
  let _, out =
    tool "writ_check"
      [
        ("model_source", s stuck);
        ("claims_source", s cl);
        ("model_name", s "two");
      ]
  in
  check "history: another name starts fresh"
    (not (contains ~sub:"revision:" out));
  (* the budget warning *)
  let wide =
    Writ_mcp.Diagnose.replace base
      [
        ( "(type stage-t (queued running done))",
          "(type stage-t (queued running done s3 s4 s5 s6 s7 s8 s9))" );
        ( "(type job (arrow stage (to stage-t))))",
          "(type job (arrow stage (to stage-t)) (arrow b (to stage-t)) (arrow \
           c (to stage-t)) (arrow d (to stage-t)) (arrow e (to stage-t)) \
           (arrow f (to stage-t))))" );
        ( "(stage (a queued))",
          "(stage (a queued)) (b (a queued)) (c (a queued)) (d (a queued)) (e \
           (a queued)) (f (a queued))" );
      ]
  in
  let _, out = tool "writ_validate" [ ("model_source", s wide) ] in
  check "validate: warns when the bound is over budget"
    (contains ~sub:"warning: the bound is over" out);
  (* a timeout cuts a big search short *)
  let spin =
    Writ_mcp.Diagnose.replace wide
      [
        ( "(transition begin",
          String.concat "\n"
            (List.concat_map
               (fun c ->
                 List.map
                   (fun v ->
                     Printf.sprintf
                       "(transition (when (is a.%s a.%s)) (do (set a.%s %s)))" c
                       c c v)
                   [
                     "queued";
                     "running";
                     "done";
                     "s3";
                     "s4";
                     "s5";
                     "s6";
                     "s7";
                     "s8";
                     "s9";
                   ])
               [ "b"; "c"; "d"; "e"; "f" ])
          ^ "\n(transition begin" );
      ]
  in
  let err, out =
    tool "writ_check"
      [
        ("model_source", s spin);
        ("max_situations", Json.Int 2000000);
        ("timeout_ms", Json.Int 1);
      ]
  in
  if not (contains ~sub:"timeout" out) then print_string out;
  check "timeout: a long search stops at the clock"
    (err && contains ~sub:"stopped at timeout" out)

(* ── how an inevitable failure avoids F; long dead-end routes ──────────── *)

let () =
  let consumer =
    List.assoc "consumer-fixed.writ"
      (List.filter_map
         (fun (info, b) -> Option.map (fun f -> (f, b)) (kv info "file"))
         (blocks (guide_topic "examples.consumer")))
  in
  let _, out =
    tool "writ_check"
      [
        ("model_source", s consumer);
        ( "claims_source",
          s "(property f \"x\" (inevitable (is m.stage acked) (fair deliver)))"
        );
      ]
  in
  check "fair inevitable: names the region a fair run circles in"
    (contains ~sub:"loops among: #2 #4 #5, taking every fair move offered there"
       out);
  (* a 40-step ladder: its dead end's route is shortened in the middle *)
  let n = 40 in
  let steps = List.init n (fun i -> "t" ^ string_of_int i) in
  let ladder =
    "(schema l (type tick (arrow next (to tick) fixed vacatable)) (type c \
     (arrow at (to tick))))\n\
     (instance i l (tick " ^ String.concat " " steps ^ ") (next "
    ^ String.concat " "
        (List.mapi
           (fun i t ->
             if i = n - 1 then "(" ^ t ^ " vacant)"
             else "(" ^ t ^ " t" ^ string_of_int (i + 1) ^ ")")
           steps)
    ^ ") (c k (at t0)))\n\
       (use l)\n\
       (initial i)\n\
       (transition step (when (defined k.at.next)) (do (set k.at k.at.next)))\n"
  in
  let err, out = tool "writ_check" [ ("model_source", s ladder) ] in
  if err then print_string out;
  check "dead ends: a long route is shortened"
    (contains ~sub:"… 19 more moves …" out)

(* ── issues from live testing (mcp_advanced.md, second round) ─────────── *)

let count ~sub t =
  let n = String.length sub and l = String.length t in
  let rec go i c =
    if i + n > l then c
    else go (i + 1) (if String.sub t i n = sub then c + 1 else c)
  in
  go 0 0

let () =
  (* 1. a missing path is E_FILE_NOT_FOUND in arguments, not a (load …) *)
  let err, out =
    tool "writ_check" [ ("model", s "probe-does-not-exist.writ") ]
  in
  check "missing model: E_FILE_NOT_FOUND in arguments"
    (err && contains ~sub:"error E_FILE_NOT_FOUND in arguments" out);
  check "missing model: names the argument and the resolved path"
    (contains ~sub:"model: probe-does-not-exist.writ not found (resolved to /"
       out);
  check "missing model: no stdlib hint" (not (contains ~sub:"stdlib" out));
  let err, out =
    tool "writ_check" [ ("model_source", s base); ("claims", s "nope.claims") ]
  in
  check "missing claims: E_FILE_NOT_FOUND names claims"
    (err && contains ~sub:"claims: nope.claims not found" out);
  let err, out =
    tool "writ_derive"
      [
        ("model_source", s base); ("rules", s "nope.rules"); ("relation", s "r");
      ]
  in
  check "missing rules: E_FILE_NOT_FOUND names rules"
    (err && contains ~sub:"rules: nope.rules not found" out);
  let _, out =
    tool "writ_validate"
      [
        ( "model_source",
          s (Writ_mcp.Diagnose.replace base [ ("stdlib.writ", "stdlb.writ") ])
        );
      ]
  in
  check "a bad (load …) is still E_LOAD" (contains ~sub:"error E_LOAD" out);
  (* 2. dead ends lead with their index and end with their cells *)
  let _, out = tool "writ_check" [ ("model_source", s base) ] in
  check "dead end: index, route and cells"
    (contains ~sub:"  #2  reached by: begin, finish   (a.stage=done)" out);
  let idx =
    List.filter_map
      (fun l ->
        let l = String.trim l in
        if String.length l > 1 && l.[0] = '#' && contains ~sub:"reached by" l
        then
          int_of_string_opt
            (List.hd
               (String.split_on_char ' ' (String.sub l 1 (String.length l - 1))))
        else None)
      (lines out)
  in
  check "dead end: its index resolves through writ_show"
    (idx <> []
    && List.for_all
         (fun i ->
           let e, o =
             tool "writ_show"
               [ ("model_source", s base); ("at", Json.List [ Json.Int i ]) ]
           in
           (not e) && contains ~sub:"a dead end" o)
         idx);
  (* 3. every independent error, not just the first *)
  (* typos in three different top-level datums; a fourth move adds one *)
  let typos =
    Writ_mcp.Diagnose.replace base
      [
        ("(set a.stage running)", "(set a.stage runing)");
        ("(set a.stage done)", "(set a.stage dne)");
        ( "(transition finish",
          "(transition reset (when (is a.stage dne)) (do (set a.stage queued)))\n\
           (transition finish" );
      ]
  in
  let err, out = tool "writ_validate" [ ("model_source", s typos) ] in
  check "validate: three typos, three errors"
    (err && count ~sub:"error E_" out = 3);
  check "validate: each with its fix" (count ~sub:"  fix:" out = 3);
  let err, out =
    tool "writ_validate"
      [
        ("model_source", s base);
        ( "claims_source",
          s
            "(property a \"x\" (possible (is a.stage don)))\n\
             (property b \"y\" (alwys (is a.stage done)))\n\
             (property c \"z\" (never (is a.stag done)))\n" );
      ]
  in
  check "validate: claims errors all reported, in file order"
    (err
    && count ~sub:"in claims at" out = 3
    &&
    let i k =
      Option.get
        (List.find_index
           (fun l -> contains ~sub:("model.claims:" ^ k ^ ":") l)
           (lines out))
    in
    i "1" < i "2" && i "2" < i "3");
  let err, out =
    tool "writ_validate"
      [
        ( "model_source",
          s (Writ_mcp.Diagnose.replace base [ ("(use shop)", "(use shop") ]) );
      ]
  in
  check "validate: a syntax error still stops at one"
    (err && count ~sub:"error E_" out = 1);
  (* 4. the protocol version is negotiated, so instructions are not ignored *)
  let init v =
    Option.bind
      (result
         (handle
            (req "initialize" (Some (Json.Assoc [ ("protocolVersion", s v) ])))))
      (fun r ->
        Option.bind (Json.member "protocolVersion" r) Json.to_string_opt)
  in
  check "initialize: answers the client's version"
    (init "2025-06-18" = Some "2025-06-18");
  check "initialize: keeps an older one it speaks"
    (init "2024-11-05" = Some "2024-11-05");
  check "initialize: an unknown one gets the newest"
    (init "1999-01-01" = Some "2025-06-18");
  (* 5. compare says `none`, not an empty label *)
  let _, out =
    tool "writ_compare"
      [
        ("old_model_source", s base);
        ("new_model_source", s base);
        ("claims_source", s "(property f \"x\" (possible (is a.stage done)))");
      ]
  in
  check "compare: no laws reads `equations:   none`"
    (contains ~sub:"equations:   none" out)

(* ── a bare (set …) outside (do …) is an error, not a silent no-op ───────── *)

let () =
  let bare =
    Writ_mcp.Diagnose.replace base
      [ ("(do (set a.stage done))", "(set a.stage done)") ]
  in
  let err, out = tool "writ_validate" [ ("model_source", s bare) ] in
  check "a transition clause outside when/do is refused"
    (err
    && contains ~sub:"unknown transition clause" out
    && contains ~sub:"E_UNKNOWN_DECL" out)

(* ── writ_validate: the summary ─────────────────────────────────────────── *)

let () =
  let err, out =
    tool "writ_validate"
      [ ("model_source", s model); ("claims_source", s claims) ]
  in
  check "validate: ok" ((not err) && contains ~sub:"ok: model, claims parse" out);
  check "validate: lists types with values"
    (contains ~sub:"type pos  values: shut open locked" out);
  check "validate: lists arrows" (contains ~sub:"arrow at -> pos" out);
  check "validate: lists laws and moves"
    (contains ~sub:"laws: locked-means-held" out
    && contains ~sub:"moves (4): open, close, lock, drop-key" out);
  check "validate: bounds the space" (contains ~sub:"at most 6 situations" out);
  check "validate: property kinds" (contains ~sub:"never-trapped (live)" out);
  let _, js =
    tool "writ_validate" [ ("model_source", s model); ("json", Json.Bool true) ]
  in
  check "validate: json"
    (match Json_parse.parse js with
    | Ok j ->
        Json.member "ok" j = Some (Json.Bool true)
        && Json.member "cells" j = Some (Json.Int 2)
    | Error _ -> false);
  (* claims and rules errors are reported together, one per file *)
  let err, out =
    tool "writ_validate"
      [
        ("model_source", s base);
        ("claims_source", s "(property p \"x\" (always (is a.stage done)))");
        ("rules_source", s "(rule (nope S) (situation S))");
      ]
  in
  check "validate: one error per file"
    (err && contains ~sub:"in claims" out && contains ~sub:"in rules" out)

(* ── R7: limits ─────────────────────────────────────────────────────────── *)

let () =
  let err, out =
    tool "writ_check"
      [
        ("model_source", s model);
        ("claims_source", s claims);
        ("max_situations", Json.Int 3);
      ]
  in
  check "limit: E_STATE_LIMIT, as an error"
    (err && contains ~sub:"limit E_STATE_LIMIT" out);
  check "limit: says how far it got"
    (contains ~sub:"explored:  3 situations" out);
  check "limit: names every property undecided"
    (contains ~sub:"undecided: can-open, never-trapped, never-lost" out);
  check "limit: ranks the cells driving growth" (contains ~sub:"d.at" out);
  check "limit: points at idioms" (contains ~sub:"writ_guide idioms" out);
  let _, js =
    tool "writ_check"
      [
        ("model_source", s model);
        ("max_situations", Json.Int 3);
        ("json", Json.Bool true);
      ]
  in
  check "limit: json"
    (match Json_parse.parse js with
    | Ok j -> (
        match Json.member "limit" j with
        | Some l -> Json.member "explored" l = Some (Json.Int 3)
        | None -> false)
    | Error _ -> false);
  let err, _ =
    tool "writ_check"
      [ ("model_source", s model); ("max_situations", Json.Int 6) ]
  in
  check "limit: a space exactly at the limit is not cut off" (not err)

(* ── R2: the guide ──────────────────────────────────────────────────────── *)

(* ~4 bytes per token for this prose; the budgets have headroom below it. *)
let () =
  let topics = Writ_mcp.Guide.topics () in
  List.iter
    (fun t -> check ("guide: has " ^ t) (List.mem_assoc t topics))
    [
      "index";
      "syntax.model";
      "syntax.claims";
      "syntax.rules";
      "semantics";
      "idioms";
      "errors";
    ];
  check "guide: index under 1000 tokens"
    (String.length (guide_topic "index") <= 4000);
  List.iter
    (fun (n, b) ->
      check ("guide: " ^ n ^ " under 6000 tokens") (String.length b <= 20000))
    topics;
  let g = Writ_mcp.Guide.get [ "index"; "semantics" ] in
  check "guide: one section per topic, in order"
    (contains ~sub:"# topic.index" g && contains ~sub:"# topic.semantics" g);
  let g = Writ_mcp.Guide.get [ "nonesuch" ] in
  check "guide: an unknown topic lists the valid ones"
    (contains ~sub:"unknown topic" g && contains ~sub:"syntax.model" g);
  let err, out =
    tool "writ_guide" [ ("items", Json.List [ s "errors.E_PAREN" ]) ]
  in
  check "writ_guide: the tool serves topics"
    ((not err) && contains ~sub:"**Wrong:**" out)

(* ── R8: resources and the prompt ───────────────────────────────────────── *)

let () =
  let r = result (handle (req "resources/list" None)) in
  let n =
    match Option.bind r (Json.member "resources") with
    | Some (Json.List xs) -> List.length xs
    | _ -> 0
  in
  check "resources: one per guide topic"
    (n = List.length (Writ_mcp.Guide.topics ()));
  let r =
    result
      (handle
         (req "resources/read"
            (Some (Json.Assoc [ ("uri", s "writ://guide/semantics") ]))))
  in
  check "resources: read a topic"
    (match Option.bind r (Json.member "contents") with
    | Some (Json.List (c :: _)) ->
        Option.bind (Json.member "text" c) Json.to_string_opt
        = Some (guide_topic "semantics")
    | _ -> false);
  let j =
    handle
      (req "resources/read"
         (Some (Json.Assoc [ ("uri", s "writ://guide/none") ])))
  in
  check "resources: an unknown uri is a protocol error"
    (Option.bind j (Json.member "error") <> None);
  let r =
    result
      (handle
         (req "prompts/get"
            (Some
               (Json.Assoc
                  [
                    ("name", s "writ_model_system");
                    ( "arguments",
                      Json.Assoc [ ("description", s "a door that locks") ] );
                  ]))))
  in
  check "prompt: writ_model_system carries the description and the workflow"
    (match Option.bind r (Json.member "messages") with
    | Some (Json.List (m :: _)) -> (
        match Option.bind (Json.member "content" m) (Json.member "text") with
        | Some (Json.String t) ->
            contains ~sub:"a door that locks" t
            && contains ~sub:"writ_validate" t
            && contains ~sub:"writ_compare" t
        | _ -> false)
    | _ -> false)

let () =
  print_string
    ("mcp authoring tests: " ^ string_of_int !passed ^ " checks passed\n")
