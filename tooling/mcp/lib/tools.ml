(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The writ verbs as tool calls. Each returns a [result] instead of exiting as
   [Cli_io] does, so the agent gets the error and can fix its input; a failure
   is a [Fault.failure], which [Diagnose] turns into a coded diagnostic.
   Loading, checking and reporting are the same engine code `writ check` uses.

   [resolve] maps the file being read to its resolver, since loads search the
   including file's directory first (D3). The binary supplies it. *)

open Writ_data
open Writ_syntax
open Writ_runtime

let ( let* ) = Result.bind

(* How far a search may go before it is cut off ([Fault.Limit]). *)
type limits = { max : int; timeout : float option }

let default_limits = { max = Space.cap; timeout = None }

let load resolve path =
  Loader.read_model (resolve path) path
  |> Result.map_error (fun e -> Fault.bad Fault.Model e)

(* An instance that breaks its own schema surfaces here, not at parse, and
   carries no position: the message names the cell instead. *)
let model_fault path e =
  Fault.bad Fault.Model { Errors.pos = None; msg = path ^ ": " ^ e }

let build ?(limits = default_limits) ?(undecided = []) path m =
  match Space.explore ~max:limits.max ?timeout:limits.timeout m with
  | Ok sp -> Ok sp
  | Error (`Model e) -> Error (model_fault path e)
  | Error (`Cutoff cutoff) -> Error (Fault.Limit { cutoff; undecided })

let read_claims resolve m path =
  Loader.read_claims (resolve path) m path
  |> Result.map_error (fun e -> Fault.bad Fault.Claims e)

(* The rules as read (for their declarations) and as checked (to run). *)
let read_rules resolve m path =
  Result.bind
    (Loader.read_rules (resolve path) m path)
    (fun t -> Result.map (fun prog -> (t, prog)) (Rules_check.check m t))
  |> Result.map_error (fun e -> Fault.bad Fault.Rules e)

let no_situation i n =
  Fault.arg "E_NO_SITUATION"
    ("no situation " ^ string_of_int i ^ ": this model has " ^ string_of_int n
   ^ " (indices 0 to "
    ^ string_of_int (n - 1)
    ^ ")")

let prop_names (cl : Claims.t) =
  List.map (fun (p : Claims.property) -> p.Claims.name) cl.Claims.props

(* ── why a property is n/a ──────────────────────────────────────────────────
   The checker answers n/a when a property names structure the model lacks,
   and says no more. Here is the first such name, with what it could have
   been: (code, message, found, alternatives). *)

let entities (ctx : State.ctx) =
  List.concat_map
    (fun (r : Instance.roster) -> r.Instance.entities)
    ctx.State.rosters

let members (ctx : State.ctx) ty =
  match Schema.type_of ctx.State.schema ty with
  | Some { Schema.flavor = Schema.Enumerated vs; _ } -> vs
  | _ ->
      List.concat_map
        (fun (r : Instance.roster) ->
          if r.Instance.ty = ty then r.Instance.entities else [])
        ctx.State.rosters

let arrows_from (ctx : State.ctx) ty =
  List.filter_map
    (fun (a : Schema.arrow) ->
      if a.Schema.dom = ty then Some a.Schema.name else None)
    ctx.State.schema.Schema.arrows

let rec missing_in (ctx : State.ctx) env (g : Model.guard) =
  let path (p : Value.path) =
    match Checker.root_type ctx env p.Value.root with
    | None ->
        Some
          ( "E_UNKNOWN_ENTITY",
            "unknown entity or variable `" ^ p.Value.root ^ "`",
            p.Value.root,
            List.map fst env @ entities ctx )
    | Some ty ->
        let rec walk cur = function
          | [] -> None
          | step :: rest -> (
              match Schema.arrow_in ctx.State.schema ~dom:cur step with
              | Some a -> walk a.Schema.cod rest
              | None ->
                  Some
                    ( "E_UNKNOWN_ARROW",
                      "`" ^ cur ^ "` has no arrow `" ^ step ^ "`",
                      step,
                      arrows_from ctx cur ))
        in
        walk ty p.Value.steps
  in
  let ( |? ) a b = match a with Some _ -> a | None -> Lazy.force b in
  match g with
  | Model.And gs | Model.Or gs -> List.find_map (missing_in ctx env) gs
  | Model.Not g -> missing_in ctx env g
  | Model.Defined p -> path p
  | Model.Is (p, Model.Lit v) ->
      path p
      |? lazy
           (match Checker.path_cod ctx env p with
           | Some ty when not (Checker.value_in_type ctx ty v) ->
               Some
                 ( "E_UNKNOWN_VALUE",
                   "value " ^ v ^ " not in codomain " ^ ty,
                   v,
                   members ctx ty )
           | _ -> None)
  | Model.Is (p, Model.Chain q) ->
      path p
      |? lazy (path q)
      |? lazy
           (match (Checker.path_cod ctx env p, Checker.path_cod ctx env q) with
           | Some a, Some b when a <> b ->
               Some
                 ( "E_TYPE_MISMATCH",
                   "one side lands in `" ^ a ^ "`, the other in `" ^ b ^ "`",
                   b,
                   [] )
           | _ -> None)
  | Model.Some_ (x, ty, g) -> (
      match Schema.type_of ctx.State.schema ty with
      | None ->
          Some
            ( "E_UNKNOWN_TYPE",
              "`" ^ ty ^ "` is not a declared type",
              ty,
              List.map
                (fun (t : Schema.ty) -> t.Schema.name)
                ctx.State.schema.Schema.types )
      | Some _ -> missing_in ctx ((x, ty) :: env) g)

let move_names (m : Model.t) =
  List.filter_map
    (fun (t : Model.transition) -> t.Model.name)
    m.Model.transitions

let missing (ctx : State.ctx) (m : Model.t) (p : Claims.property) =
  match missing_in ctx [] p.Claims.formula with
  | Some r -> Some r
  | None -> (
      match p.Claims.modality with
      | Claims.Inevitable fair -> (
          match
            List.find_opt (fun mv -> not (List.mem mv (move_names m))) fair
          with
          | Some mv ->
              Some
                ( "E_UNKNOWN_MOVE",
                  "no move named `" ^ mv ^ "`",
                  mv,
                  move_names m )
          | None -> None)
      | _ -> None)

(* Where [token] first stands as a whole word in [text], at or after the line
   holding [after]: the claims datum is not positioned once parsed. *)
let locate ~file ~after ~token text : Errors.pos option =
  let ls = String.split_on_char '\n' text in
  let start =
    let rec go k = function
      | [] -> 0
      | l :: rest ->
          if Diagnose.contains ~sub:after l then k else go (k + 1) rest
    in
    go 0 ls
  in
  let word l i =
    let n = String.length token and len = String.length l in
    let name c = Diagnose.is_name c in
    String.sub l i n = token
    && (i = 0 || not (name l.[i - 1]))
    && (i + n = len || not (name l.[i + n]))
  in
  List.find_map
    (fun (k, l) ->
      if k < start then None
      else
        let n = String.length token in
        let rec go i =
          if i + n > String.length l then None
          else if word l i then Some i
          else go (i + 1)
        in
        Option.map
          (fun i -> { Errors.file = Some file; line = k + 1; col = i + 1 })
          (go 0))
    (List.mapi (fun k l -> (k, l)) ls)

(* One line per n/a property of a check: what it names that the model lacks. *)
let na_notes ctx m (props : (Claims.property * Checker.outcome) list) =
  List.filter_map
    (fun ((p : Claims.property), o) ->
      match (o, missing ctx m p) with
      | Checker.Not_applicable _, Some (code, msg, found, alts) ->
          let _, best = Diagnose.rank found alts in
          Some
            ("why n/a  " ^ p.Claims.name ^ ": " ^ msg
            ^ (match best with
              | Some b -> " — did you mean `" ^ b ^ "`?"
              | None -> "")
            ^ "   (" ^ code ^ "; n/a is a failure)")
      | _ -> None)
    props

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

(* A space can be large, so only this many are kept; past it the memory
   starts over rather than grow without bound. *)
let memory_cap = 16

(* The §17 comparison against the remembered space, or [None] the first time.
   As in `writ compare`, a property that became n/a counts as LOST. *)
let revision ~(memory : memory) ?(key = "") ~(cpath : string) (cl : Claims.t)
    (sp : Space.t) : (string * Json.t) option =
  let key = key ^ "|" ^ cpath in
  let result =
    match Hashtbl.find_opt memory key with
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
  if Hashtbl.length memory >= memory_cap && not (Hashtbl.mem memory key) then
    Hashtbl.reset memory;
  Hashtbl.replace memory key sp;
  result

(* ── check ─────────────────────────────────────────────────────────────────
   Same output as `writ check` (or `writ check --json`). *)
let check ?(json = false) ?(pinned = None) ?(memory = remember) ?memory_key
    ?certify ?(version = "") ?limits ~resolve ~model ~claims () =
  let* m = load resolve model in
  let claims = Option.map (pin ~pinned) claims in
  (* Claims are typed against the model alone, so they are read before the
     search: a cut-off search can then name what it left undecided. *)
  let* cl =
    match claims with
    | None -> Ok None
    | Some c -> Result.map (fun cl -> Some (c, cl)) (read_claims resolve m c)
  in
  let undecided = match cl with Some (_, cl) -> prop_names cl | None -> [] in
  let* sp = build ?limits ~undecided model m in
  let parts =
    Option.map
      (fun (c, cl) ->
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
        (c, cl, unadmitted, stale, props, queries))
      cl
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
             (fun (_, o) ->
               (* n/a is a finding, as in `writ check` *)
               match o with
               | Checker.Holds _ -> false
               | _ -> true)
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
    | Some (c, cl, _, _, _, _) ->
        revision ~memory ?key:memory_key ~cpath:c cl sp
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
    let notes =
      match parts with
      | Some (_, _, _, _, props, _) -> na_notes sp.Space.ctx m props
      | None -> []
    in
    let with_notes =
      match (with_pin, notes) with
      | Json.Assoc kvs, _ :: _ ->
          Json.Assoc
            (kvs
            @ [
                ("why_na", Json.List (List.map (fun n -> Json.String n) notes));
              ])
      | j, _ -> j
    in
    Ok (Json.to_string with_notes)
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
        List.iter (fun (q, i, rows) -> add (Report.query_rows q i rows)) queries;
        List.iter add (na_notes sp.Space.ctx m props));
    (match rev with Some (text, _) -> add text | None -> ());
    let nothing_decided =
      match parts with
      | Some (_, _, _, _, props, queries) ->
          Certify_json.nothing_decided (List.map snd props)
            ~queries:(List.length queries)
      | None -> false
    in
    Option.iter
      (fun v -> add (Certify_json.verdict_line ~nothing_decided v))
      certified;
    Ok (Buffer.contents b)
  end

(* ── show ──────────────────────────────────────────────────────────────────
   The situations at the given indices; the initial one if none. *)
let show ?(json = false) ?limits ~resolve ~model ~at () =
  let* m = load resolve model in
  let* sp = build ?limits model m in
  let n = Array.length sp.Space.states in
  let* idxs =
    match at with
    | [] -> Ok [ 0 ]
    | is -> (
        match List.find_opt (fun i -> i < 0 || i >= n) is with
        | Some i -> Error (no_situation i n)
        | None -> Ok is)
  in
  if json then Ok (Json.to_string (Report_json.show sp idxs))
  else Ok (String.concat "\n\n" (List.map (Report.situation sp) idxs))

(* ── compare ───────────────────────────────────────────────────────────────
   OLD's claims put to both models: guarantees kept, lost and gained. *)
let compare ?(json = false) ?(pinned = None) ?limits ?claims ~resolve ~old_model
    ~new_model () =
  let* old_m = load resolve old_model in
  let* new_m = load resolve new_model in
  (* The old model's claims: the ones named, else its sibling, else none. A
     named file that does not read is an error; a missing sibling is not. *)
  let* cl =
    match claims with
    | Some c -> read_claims resolve old_m (pin ~pinned c)
    | None -> (
        match read_claims resolve old_m (sibling_claims ~pinned old_model) with
        | Ok cl -> Ok cl
        | Error _ -> Ok { Claims.props = []; queries = []; accepts = [] })
  in
  let undecided = prop_names cl in
  let* old_sp = build ?limits ~undecided old_model old_m in
  let* new_sp = build ?limits ~undecided new_model new_m in
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
    (* Compare lists what changed; a property failing in both is silent
       there, which reads as "nothing wrong". *)
    let failing sp (p : Claims.property) =
      match Checker.check sp p with Checker.Holds _ -> false | _ -> true
    in
    let still =
      List.filter_map
        (fun (p : Claims.property) ->
          if failing old_sp p && failing new_sp p then Some p.Claims.name
          else None)
        cl.Claims.props
    in
    Ok
      (if still = [] then text
       else
         String.trim text ^ "\nstill failing in both models: "
         ^ String.concat ", " still ^ "\n")

(* ── query ─────────────────────────────────────────────────────────────────
   One named query from the sibling .claims. An out-of-range [at] is an error,
   not an empty answer. *)
let query ?(json = false) ?(pinned = None) ?limits ?claims ~resolve ~model ~name
    ~at () =
  let* m = load resolve model in
  let cpath =
    match claims with
    | Some c -> pin ~pinned c
    | None -> sibling_claims ~pinned model
  in
  let* cl = read_claims resolve m cpath in
  let* sp = build ?limits model m in
  let* q =
    match
      List.find_opt
        (fun (q : Claims.query) -> q.Claims.name = name)
        cl.Claims.queries
    with
    | Some q -> Ok q
    | None ->
        Error
          (Fault.Bad
             [
               {
                 Fault.source = Fault.Claims;
                 code = Some "E_UNKNOWN_QUERY";
                 err =
                   {
                     Errors.pos = None;
                     msg = "no query named `" ^ name ^ "` in " ^ cpath;
                   };
                 meant =
                   Some
                     ( name,
                       List.map
                         (fun (q : Claims.query) -> q.Claims.name)
                         cl.Claims.queries );
               };
             ])
  in
  let* idx, st =
    match at with
    | None -> Ok (0, sp.Space.initial)
    | Some i when i >= 0 && i < Array.length sp.Space.states ->
        Ok (i, sp.Space.states.(i))
    | Some i -> Error (no_situation i (Array.length sp.Space.states))
  in
  let rows = Query.run sp q ~at:st () in
  if json then Ok (Json.to_string (Report_json.query_rows q idx rows))
  else Ok (Report.query_rows q idx rows)

let no_relation relation rules =
  Fault.bad ~code:"E_UNKNOWN_RELATION" Fault.Rules
    {
      Errors.pos = None;
      msg = "no relation named `" ^ relation ^ "` in " ^ rules;
    }

(* ── derive ────────────────────────────────────────────────────────────────
   A relation from a .rules file, with arguments as a JSON list (null =
   unbound). [why] returns the derivation tree and needs every argument. *)
let derive ?(json = false) ?limits ~resolve ~model ~rules ~relation ~args ~why
    () =
  let* m = load resolve model in
  let* _, prog = read_rules resolve m rules in
  let* sp = build ?limits model m in
  (* Compute only the relation asked for, as [Cmd_derive] does. *)
  let t = Derive.run ~only:relation sp prog in
  let* sorts =
    match Derive_answers.sorts_of t relation with
    | Some ss -> Ok ss
    | None -> Error (no_relation relation rules)
  in
  let arity = List.length sorts in
  let args =
    match args with None -> List.init arity (fun _ -> None) | Some a -> a
  in
  let* () =
    if List.length args = arity then Ok ()
    else
      Error
        (Fault.arg "E_ARG_INVALID"
           (relation ^ " takes " ^ string_of_int arity ^ " arguments, not "
           ^ string_of_int (List.length args)))
  in
  if why then
    let* ground =
      if List.for_all Option.is_some args then
        Ok (List.map (Option.value ~default:"") args)
      else
        Error
          (Fault.arg "E_ARG_INVALID"
             ("`why` needs every argument of `" ^ relation
            ^ "` given, not left open"))
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
          (Fault.arg "E_ARG_INVALID"
             ("`"
             ^ Option.value ~default:"?" (List.nth args i)
             ^ "` is not " ^ Rules_terms.sort_name srt
             ^ ", which is what column "
             ^ string_of_int (i + 1)
             ^ " of `" ^ relation ^ "` takes"))
    | None -> Error (no_relation relation rules)

(* ── validate ──────────────────────────────────────────────────────────────
   Parse and type-check without enumerating: every file's first error, or
   what the sources declare, so the agent can see the model means what it
   intended. Claims and rules are typed against the model, so a broken model
   is the only error reported. *)

let modality_name = function
  | Claims.Possible -> "possible"
  | Claims.Never -> "never"
  | Claims.Live -> "live"
  | Claims.Inevitable [] -> "inevitable"
  | Claims.Inevitable fair -> "inevitable (fair " ^ String.concat " " fair ^ ")"

let arity (r : Rules.relation) =
  match r.Rules.cols with Rules.Arity n -> n | Rules.Sorts l -> List.length l

let validate ?(json = false) ?(pinned = None) ~resolve ~model ~claims ~rules ()
    =
  let* m = load resolve model in
  let* ctx, _ =
    State.build_ctx m.Model.schema m.Model.initial
    |> Result.map_error (model_fault model)
  in
  let claims = Option.map (pin ~pinned) claims in
  let cl = Option.map (read_claims resolve m) claims in
  let rl =
    Option.map (fun r -> Result.map fst (read_rules resolve m r)) rules
  in
  let errs =
    List.concat_map
      (function Some (Error (Fault.Bad fs)) -> fs | _ -> [])
      [ Option.map (Result.map ignore) cl; Option.map (Result.map ignore) rl ]
  in
  (* Claims are typed against the model, but a name the model lacks parses
     and only answers n/a: almost always a typo in new claims, so here it is
     an error with the name meant. *)
  let errs =
    match (cl, claims) with
    | Some (Ok cl), Some cpath ->
        let text =
          match resolve cpath (Filename.basename cpath) with
          | Ok t -> t
          | Error _ -> ""
        in
        errs
        @ List.filter_map
            (fun (p : Claims.property) ->
              Option.map
                (fun (code, msg, found, alts) ->
                  {
                    Fault.source = Fault.Claims;
                    code = Some code;
                    err =
                      {
                        Errors.pos =
                          locate ~file:cpath
                            ~after:("property " ^ p.Claims.name)
                            ~token:found text;
                        msg =
                          "property `" ^ p.Claims.name ^ "` would be n/a: "
                          ^ msg;
                      };
                    meant = Some (found, alts);
                  })
                (missing ctx m p))
            cl.Claims.props
    | _ -> errs
  in
  if errs <> [] then Error (Fault.Bad errs)
  else
    let cl = Option.map Result.get_ok cl and rl = Option.map Result.get_ok rl in
    let schema = m.Model.schema and inst = m.Model.initial in
    let lay = ctx.State.layout in
    let cells = Array.length lay.State.cells in
    let bound = Space.bound lay and show_bound = Space.show_bound in
    let members (ty : Schema.ty) =
      match ty.Schema.flavor with
      | Schema.Enumerated vs -> ("values", vs)
      | Schema.Open ->
          ("entities", Instance.entities_of_type inst ty.Schema.name)
    in
    let arrows_of (ty : Schema.ty) =
      List.filter
        (fun (a : Schema.arrow) -> a.Schema.dom = ty.Schema.name)
        schema.Schema.arrows
    in
    let moves =
      List.mapi
        (fun i (t : Model.transition) ->
          match t.Model.name with Some n -> n | None -> "#" ^ string_of_int i)
        m.Model.transitions
    in
    let laws =
      List.map
        (fun (e : Schema.equation) -> e.Schema.name)
        schema.Schema.equations
    in
    if json then
      let strs l = Json.List (List.map (fun s -> Json.String s) l) in
      let types =
        List.map
          (fun (ty : Schema.ty) ->
            let k, vs = members ty in
            Json.Assoc
              [
                ("name", Json.String ty.Schema.name);
                (k, strs vs);
                ( "arrows",
                  Json.List
                    (List.map
                       (fun (a : Schema.arrow) ->
                         Json.Assoc
                           [
                             ("name", Json.String a.Schema.name);
                             ("to", Json.String a.Schema.cod);
                             ("fixed", Json.Bool a.Schema.fixed);
                             ("vacatable", Json.Bool a.Schema.vacatable);
                           ])
                       (arrows_of ty)) );
              ])
          schema.Schema.types
      in
      let claims_j =
        match cl with
        | None -> []
        | Some cl ->
            [
              ( "properties",
                Json.List
                  (List.map
                     (fun (p : Claims.property) ->
                       Json.Assoc
                         [
                           ("name", Json.String p.Claims.name);
                           ( "modality",
                             Json.String (modality_name p.Claims.modality) );
                         ])
                     cl.Claims.props) );
              ( "queries",
                strs
                  (List.map
                     (fun (q : Claims.query) -> q.Claims.name)
                     cl.Claims.queries) );
            ]
      in
      let rules_j =
        match rl with
        | None -> []
        | Some (t : Rules_parser.t) ->
            [
              ( "relations",
                Json.List
                  (List.map
                     (fun (r : Rules.relation) ->
                       Json.Assoc
                         [
                           ("name", Json.String r.Rules.rel_name);
                           ("arity", Json.Int (arity r));
                         ])
                     t.Rules_parser.relations) );
            ]
      in
      Ok
        (Json.to_string
           (Json.Assoc
              ([
                 ("ok", Json.Bool true);
                 ("schema", Json.String schema.Schema.name);
                 ("instance", Json.String inst.Instance.name);
                 ("types", Json.List types);
                 ("laws", strs laws);
                 ("moves", strs moves);
                 ("cells", Json.Int cells);
                 ("bound", Json.String (show_bound bound));
               ]
              @ claims_j @ rules_j)))
    else
      let b = Buffer.create 1024 in
      let add = adder b in
      add
        ("ok: "
        ^ String.concat ", "
            (("model" :: (if cl <> None then [ "claims" ] else []))
            @ if rl <> None then [ "rules" ] else [])
        ^ " parse and type-check (nothing was enumerated)");
      add ("schema " ^ schema.Schema.name ^ ", instance " ^ inst.Instance.name);
      List.iter
        (fun (ty : Schema.ty) ->
          let k, vs = members ty in
          add
            ("  type " ^ ty.Schema.name ^ "  " ^ k ^ ": "
            ^ if vs = [] then "(none)" else String.concat " " vs);
          List.iter
            (fun (a : Schema.arrow) ->
              add
                ("    arrow " ^ a.Schema.name ^ " -> " ^ a.Schema.cod
                ^ (if a.Schema.fixed then "  fixed" else "")
                ^ if a.Schema.vacatable then "  vacatable" else ""))
            (arrows_of ty))
        schema.Schema.types;
      if laws <> [] then add ("laws: " ^ String.concat ", " laws);
      add
        ("moves ("
        ^ string_of_int (List.length moves)
        ^ "): " ^ String.concat ", " moves);
      add
        ("cells: " ^ string_of_int cells ^ " mutable; at most "
       ^ show_bound bound
       ^ " situations (the product of their domains; check budget "
       ^ string_of_int Space.cap ^ ")");
      if bound > float_of_int Space.cap then
        add
          "warning: the bound is over the check budget; writ_check may stop \
           with E_STATE_LIMIT. Shrink domains and drop unread cells \
           (writ_guide idioms, Abstraction and size).";
      Option.iter
        (fun (cl : Claims.t) ->
          add
            ("properties: "
            ^ String.concat ", "
                (List.map
                   (fun (p : Claims.property) ->
                     p.Claims.name ^ " ("
                     ^ modality_name p.Claims.modality
                     ^ ")")
                   cl.Claims.props));
          if cl.Claims.queries <> [] then
            add
              ("queries: "
              ^ String.concat ", "
                  (List.map
                     (fun (q : Claims.query) -> q.Claims.name)
                     cl.Claims.queries)))
        cl;
      Option.iter
        (fun (t : Rules_parser.t) ->
          add
            ("relations: "
            ^ String.concat ", "
                (List.map
                   (fun (r : Rules.relation) ->
                     r.Rules.rel_name ^ "/" ^ string_of_int (arity r))
                   t.Rules_parser.relations)))
        rl;
      Ok (Buffer.contents b)
