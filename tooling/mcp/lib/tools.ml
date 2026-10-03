(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The writ verbs as tool calls. Each returns a [result] instead of exiting as
   [Cli_io] does, so the agent gets the error message and can fix its input.
   Loading, checking and reporting are the same engine code `writ check` uses.

   [resolve] maps the file being read to its resolver, since loads search the
   including file's directory first (D3). The binary supplies it. *)

open Writ_data
open Writ_syntax
open Writ_runtime

let ( let* ) = Result.bind

let load resolve path =
  Loader.read_model (resolve path) path |> Result.map_error Errors.to_string

let build path m = Space.build m |> Result.map_error (fun e -> path ^ ": " ^ e)

let read_claims resolve m path =
  Loader.read_claims (resolve path) m path |> Result.map_error Errors.to_string

(* Appends a line, skipping the empty sections [Report] returns as "". *)
let adder b s =
  if s <> "" then (
    Buffer.add_string b s;
    Buffer.add_char b '\n')

(* ── pinned claims ─────────────────────────────────────────────────────────
   Under `--claims-dir DIR`, every claims path, including a sibling `.claims`,
   is read by basename from DIR, so an agent cannot edit its own questions. *)
let pin ~(pinned : string option) (path : string) : string =
  match pinned with
  | Some dir -> Filename.concat dir (Filename.basename path)
  | None -> path

let sibling_claims ~pinned model =
  pin ~pinned (Filename.remove_extension model ^ ".claims")

(* ── revision memory ───────────────────────────────────────────────────────
   The last space checked against each claims path, so the next check can
   report what the edit LOST. Keyed by claims path, not model path: the
   guarantees are defined by the questions. *)
type memory = (string, Space.t) Hashtbl.t

let remember : memory = Hashtbl.create 8

(* The §17 comparison against the remembered space, or [None] the first time.
   As in `writ compare`, a property that became n/a counts as LOST. *)
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
   Same output as `writ check` (or `writ check --json`). *)
let check ?(json = false) ?(pinned = None) ?(memory = remember) ?certify
    ?(version = "") ~resolve ~model ~claims () =
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
  let report exit =
    match parts with
    | None ->
        Report_json.check ~queries:[] ~sp ~unadmitted:[] ~stale:[] ~props:[]
          ~answered:[] ~exit
    | Some (_, cl, unadmitted, stale, props, queries) ->
        Report_json.check ~queries:cl.Claims.queries ~sp ~unadmitted ~stale
          ~props ~answered:queries ~exit
  in
  (* Certify as `writ check` does; a refuted report is a finding. *)
  let certified =
    Option.map
      (fun f ->
        f
          (Certify_json.certificate ~version ~sp ~model_:m
             ~claims:(Option.map (fun (_, cl, _, _, _, _) -> cl) parts)
             ~report:(report (if failed then 1 else 0))))
      certify
  in
  let failed =
    failed
    ||
    match certified with
    | Some (Certify_json.Disagrees _) -> true
    | _ -> false
  in
  let exit = if failed then 1 else 0 in
  let rev =
    match parts with
    | Some (c, cl, _, _, _, _) -> revision ~memory ~cpath:c cl sp
    | None -> None
  in
  if json then
    let base =
      match (report exit, certified) with
      | Json.Assoc kvs, Some v ->
          Json.Assoc (kvs @ [ ("certification", Certify_json.verdict_json v) ])
      | j, _ -> j
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
    Option.iter (fun v -> add (Certify_json.verdict_line v)) certified;
    Ok (Buffer.contents b)
  end

(* ── show ──────────────────────────────────────────────────────────────────
   The situations at the given indices; the initial one if none. *)
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
   OLD's claims put to both models: guarantees kept, lost and gained. *)
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
   One named query from the sibling .claims. An out-of-range [at] is an error,
   not an empty answer. *)
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
   A relation from a .rules file, with arguments as a JSON list (null =
   unbound). [why] returns the derivation tree and needs every argument. *)
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
  (* Compute only the relation asked for, as [Cmd_derive] does. *)
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
    (* Wrong-sort constant: the .rules parser's wording. *)
    | Some (Error (i, srt)) ->
        Error
          ("`"
          ^ Option.value ~default:"?" (List.nth args i)
          ^ "` is not " ^ Rules_terms.sort_name srt ^ ", which is what column "
          ^ string_of_int (i + 1)
          ^ " of `" ^ relation ^ "` takes")
    | None -> Error ("no relation named `" ^ relation ^ "` in " ^ rules)
