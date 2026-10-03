(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The writ verbs, as tool calls.

   Every function here answers with a [result] and never exits. The CLI dies
   with status 2 on an unreadable model because a shell wants that; a tool call
   must come back with something the caller can READ and act on — an LLM that
   gets a dead process learns nothing, and one that gets the parser's own
   message can usually fix the file. So the load path is re-expressed over
   [result] rather than reusing [Cli_io], which is the one part of the CLI that
   cannot be shared.

   Everything else IS shared: the same [Loader], the same [Space], the same
   [Report]. An answer from this server is an answer `writ check` would give,
   for the same reason the language server is written in OCaml — a second
   implementation would be a second set of bugs.

   [resolve] is a FUNCTION from the file being read to a resolver, because
   design D3 searches the including file's own directory first and a rules file
   need not sit beside its model. The binary supplies it; no I/O happens here. *)

open Writ_data
open Writ_syntax
open Writ_runtime

let ( let* ) = Result.bind

let load resolve path =
  Loader.read_model (resolve path) path |> Result.map_error Errors.to_string

let build path m = Space.build m |> Result.map_error (fun e -> path ^ ": " ^ e)

let read_claims resolve m path =
  Loader.read_claims (resolve path) m path |> Result.map_error Errors.to_string

(* A buffer that never emits a blank line for a section that had nothing to
   say — [Report] returns "" for an empty gap list, and a tool's text is read
   by something that pays per token. *)
let adder b s =
  if s <> "" then (
    Buffer.add_string b s;
    Buffer.add_char b '\n')

(* ── pinned claims ─────────────────────────────────────────────────────────
   With a claims directory pinned (`writ-mcp --claims-dir DIR`), every claims
   path a caller passes is taken by its basename under DIR — and a sibling
   `.claims` is looked for there too. The questions are the human's: an agent
   that edits the model to make a check pass cannot also edit what is asked
   of it, because the server never reads a claims file from anywhere else. *)
let pin ~(pinned : string option) (path : string) : string =
  match pinned with
  | Some dir -> Filename.concat dir (Filename.basename path)
  | None -> path

let sibling_claims ~pinned model =
  pin ~pinned (Filename.remove_extension model ^ ".claims")

(* ── revision memory ───────────────────────────────────────────────────────
   What the last model checked against each claims file looked like, so the
   next check can say what the edit between them LOST. The table is created
   by whoever runs the server — the binary, or a test — because [Server] is a
   pure function and must stay one; it is keyed by the (pinned) claims path,
   since a guarantee is defined by the questions, not by the file name of the
   model that happened to answer them. *)
type memory = (string, Space.t) Hashtbl.t

let remember : memory = Hashtbl.create 8

(* The §17 classification of this check against the remembered one, as the
   prose [Compare] prints. [None] when nothing was remembered yet. A property
   that became n/a is classified LOST, as `writ compare` classifies it: a
   guarantee that can no longer be confirmed is not a guarantee kept. *)
let revision ~(memory : memory) ~(cpath : string) (cl : Claims.t) (sp : Space.t)
    : (string * Json.t) option =
  let result =
    match Hashtbl.find_opt memory cpath with
    | None -> None
    | Some old_sp ->
        let equations = Compare.equation_rows [] old_sp sp in
        let properties = Compare.property_rows [] old_sp sp cl in
        let any_lost =
          List.exists
            (fun (r : Compare.row) -> r.Compare.status = "LOST")
            (equations @ properties)
        in
        let text, _ = Compare.run old_sp sp cl [] in
        let head =
          "revision: against the previous model checked with "
          ^ Filename.basename cpath
          ^ if any_lost then " — a guarantee was LOST" else " — nothing lost"
        in
        let json =
          Report_json.compare ~new_sp:sp ~equations ~properties
            ~exit:(if any_lost then 1 else 0)
        in
        Some (head ^ "\n" ^ text, json)
  in
  Hashtbl.replace memory cpath sp;
  result

(* ── check ─────────────────────────────────────────────────────────────────
   The flagship verb: build the space, report it, and — with a claims file —
   answer every property and query. Same output as `writ check`, and the same
   meaning: `fails` carries the shortest route to the counterexample. With
   [json] the answer is the object `writ check --json` prints. *)
let check ?(json = false) ?(pinned = None) ?(memory = remember) ~resolve ~model
    ~claims () =
  let* m = load resolve model in
  let* sp = build model m in
  let claims = Option.map (pin ~pinned) claims in
  let* parts =
    match claims with
    | None -> Ok None
    | Some c ->
        let* cl = read_claims resolve m c in
        let unadmitted = Observe.unadmitted sp cl
        and stale = Observe.stale sp cl in
        let props =
          List.map
            (fun (p : Claims.property) -> (p, Checker.check sp p))
            cl.Claims.props
        in
        let queries =
          List.map
            (fun (q : Claims.query) -> (q, 0, Query.run sp q ()))
            cl.Claims.queries
        in
        Ok (Some (c, cl, unadmitted, stale, props, queries))
  in
  let failed =
    List.exists
      (fun (l : Observe.law) -> l.Observe.violation <> None)
      (Observe.laws sp)
    ||
    match parts with
    | Some (_, _, u, s, props, _) ->
        u <> [] || s <> []
        || List.exists
             (fun (_, o) -> match o with Checker.Fails _ -> true | _ -> false)
             props
    | None -> false
  in
  let exit = if failed then 1 else 0 in
  let rev =
    match parts with
    | Some (c, cl, _, _, _, _) -> revision ~memory ~cpath:c cl sp
    | None -> None
  in
  if json then
    let base =
      match parts with
      | None ->
          Report_json.check ~queries:[] ~sp ~unadmitted:[] ~stale:[] ~props:[]
            ~answered:[] ~exit
      | Some (_, cl, unadmitted, stale, props, queries) ->
          Report_json.check ~queries:cl.Claims.queries ~sp ~unadmitted ~stale
            ~props ~answered:queries ~exit
    in
    let with_rev =
      match (base, rev) with
      | Json.Assoc kvs, Some (_, j) -> Json.Assoc (kvs @ [ ("revision", j) ])
      | j, _ -> j
    in
    let with_pin =
      match (with_rev, claims, pinned) with
      | Json.Assoc kvs, Some c, Some _ ->
          Json.Assoc (kvs @ [ ("claims", Json.String c) ])
      | j, _, _ -> j
    in
    Ok (Json.to_string with_pin)
  else begin
    let b = Buffer.create 1024 in
    let add = adder b in
    add (Report.build sp);
    (match parts with
    | None -> ()
    | Some (c, cl, unadmitted, stale, props, queries) ->
        if pinned <> None then add ("claims: " ^ c ^ "   (pinned)");
        add (Report.acks unadmitted stale);
        List.iter
          (fun (p, o) -> add (Report.outcome ~queries:cl.Claims.queries sp p o))
          props;
        List.iter (fun (q, i, rows) -> add (Report.query_rows q i rows)) queries);
    (match rev with Some (text, _) -> add text | None -> ());
    Ok (Buffer.contents b)
  end

(* ── show ──────────────────────────────────────────────────────────────────
   What a situation IS: its cells, the fewest moves to it, every move out —
   the verb that reads back what a witness step or a derived row names by
   index. Several indices at once, because that is the shape an answer has. *)
let show ?(json = false) ~resolve ~model ~at () =
  let* m = load resolve model in
  let* sp = build model m in
  let n = Array.length sp.Space.states in
  let* idxs =
    match at with
    | [] -> Ok [ 0 ]
    | is -> (
        match List.find_opt (fun i -> i < 0 || i >= n) is with
        | Some i ->
            Error
              ("no situation " ^ string_of_int i ^ ": this model has "
             ^ string_of_int n)
        | None -> Ok is)
  in
  if json then Ok (Json.to_string (Report_json.show sp idxs))
  else Ok (String.concat "\n\n" (List.map (Report.situation sp) idxs))

(* ── compare ───────────────────────────────────────────────────────────────
   Which guarantees an edit kept, lost and gained: OLD's claims (pinned, if a
   directory is) put to both models. The way an agent prices its own edit
   before anyone else has to. *)
let compare ?(json = false) ?(pinned = None) ~resolve ~old_model ~new_model () =
  let* old_m = load resolve old_model in
  let* old_sp = build old_model old_m in
  let* new_m = load resolve new_model in
  let* new_sp = build new_model new_m in
  let cpath = sibling_claims ~pinned old_model in
  let* cl =
    match read_claims resolve old_m cpath with
    | Ok cl -> Ok cl
    | Error _ -> Ok { Claims.props = []; queries = []; accepts = [] }
  in
  let equations = Compare.equation_rows [] old_sp new_sp in
  let properties = Compare.property_rows [] old_sp new_sp cl in
  let any_lost =
    List.exists
      (fun (r : Compare.row) -> r.Compare.status = "LOST")
      (equations @ properties)
  in
  if json then
    Ok
      (Json.to_string
         (Report_json.compare ~new_sp ~equations ~properties
            ~exit:(if any_lost then 1 else 0)))
  else
    let text, _ = Compare.run old_sp new_sp cl [] in
    Ok text

(* ── query ─────────────────────────────────────────────────────────────────
   One named question from the model's sibling .claims file. [at] indexes the
   enumerated space, so an out-of-range index is a mis-asked question rather
   than an empty answer — the caller is asking about a situation the model
   never reaches, and saying so is more useful than saying "no rows". *)
let query ?(json = false) ?(pinned = None) ~resolve ~model ~name ~at () =
  let* m = load resolve model in
  let* sp = build model m in
  let cpath = sibling_claims ~pinned model in
  let* cl = read_claims resolve m cpath in
  let* q =
    match
      List.find_opt
        (fun (q : Claims.query) -> q.Claims.name = name)
        cl.Claims.queries
    with
    | Some q -> Ok q
    | None -> Error ("no query named `" ^ name ^ "` in " ^ cpath)
  in
  let* idx, st =
    match at with
    | None -> Ok (0, sp.Space.initial)
    | Some i when i >= 0 && i < Array.length sp.Space.states ->
        Ok (i, sp.Space.states.(i))
    | Some i ->
        Error
          ("no situation " ^ string_of_int i ^ ": this model has "
          ^ string_of_int (Array.length sp.Space.states))
  in
  let rows = Query.run sp q ~at:st () in
  if json then Ok (Json.to_string (Report_json.query_rows q idx rows))
  else Ok (Report.query_rows q idx rows)

(* ── derive ────────────────────────────────────────────────────────────────
   A relation from a .rules file. Arguments arrive as a LIST with nulls for the
   unbound positions, rather than as `"(rel a b)"` to be parsed: a tool has
   structure available and should use it, and it keeps the CLI's little query
   parser from being duplicated where it would drift.

   [why] asks for the derivation TREE instead of the rows — the reason this
   verb is worth exposing at all, since it answers "how do you know" and not
   merely "what". It needs every argument ground; a tree of a partial question
   is not a thing. *)
let derive ?(json = false) ~resolve ~model ~rules ~relation ~args ~why () =
  let* m = load resolve model in
  let* sp = build model m in
  let* prog =
    let* t =
      Loader.read_rules (resolve rules) m rules
      |> Result.map_error Errors.to_string
    in
    Rules_check.check m t |> Result.map_error Errors.to_string
  in
  (* One call asks for one relation, so the fixpoint is told which — the same
     pruning [Cmd_derive] does, for the same reason. *)
  let t = Derive.run ~only:relation sp prog in
  let* sorts =
    match Derive_answers.sorts_of t relation with
    | Some ss -> Ok ss
    | None -> Error ("no relation named `" ^ relation ^ "` in " ^ rules)
  in
  let arity = List.length sorts in
  let args =
    match args with None -> List.init arity (fun _ -> None) | Some a -> a
  in
  let* () =
    if List.length args = arity then Ok ()
    else
      Error
        (relation ^ " takes " ^ string_of_int arity ^ " arguments, not "
        ^ string_of_int (List.length args))
  in
  if why then
    let* ground =
      if List.for_all Option.is_some args then
        Ok (List.map (Option.value ~default:"") args)
      else
        Error
          ("`why` needs every argument of `" ^ relation
         ^ "` given, not left open")
    in
    if json then Ok (Json.to_string (Report_json.derive_why t relation ground))
    else Ok (Report_derive.why t relation ground)
  else
    match Derive_answers.query t relation args with
    | Some (Ok tuples) ->
        if json then
          Ok (Json.to_string (Report_json.derive_rows t relation tuples))
        else Ok (Report_derive.rows t relation tuples)
    (* A constant the column can never hold is a mis-asked question, in the
       same words the .rules parser uses — a tool is not a looser door into
       the engine than a file is. *)
    | Some (Error (i, srt)) ->
        Error
          ("`"
          ^ Option.value ~default:"?" (List.nth args i)
          ^ "` is not " ^ Rules_terms.sort_name srt ^ ", which is what column "
          ^ string_of_int (i + 1)
          ^ " of `" ^ relation ^ "` takes")
    | None -> Error ("no relation named `" ^ relation ^ "` in " ^ rules)
