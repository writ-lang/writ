(* The pol verbs, as tool calls.

   Every function here answers with a [result] and never exits. The CLI dies
   with status 2 on an unreadable model because a shell wants that; a tool call
   must come back with something the caller can READ and act on — an LLM that
   gets a dead process learns nothing, and one that gets the parser's own
   message can usually fix the file. So the load path is re-expressed over
   [result] rather than reusing [Cli_io], which is the one part of the CLI that
   cannot be shared.

   Everything else IS shared: the same [Loader], the same [Space], the same
   [Report]. An answer from this server is an answer `pol check` would give,
   for the same reason the language server is written in OCaml — a second
   implementation would be a second set of bugs.

   [resolve] is a FUNCTION from the file being read to a resolver, because
   design D3 searches the including file's own directory first and a rules file
   need not sit beside its model. The binary supplies it; no I/O happens here. *)

open Pol_data
open Pol_syntax
open Pol_runtime

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

(* ── check ─────────────────────────────────────────────────────────────────
   The flagship verb: build the space, report it, and — with a claims file —
   answer every property and query. Same output as `pol check`, and the same
   meaning: `fails` carries the shortest route to the counterexample. *)
let check ~resolve ~model ~claims =
  let* m = load resolve model in
  let* sp = build model m in
  let b = Buffer.create 1024 in
  let add = adder b in
  add (Report.build sp);
  let* () =
    match claims with
    | None -> Ok ()
    | Some c ->
        let* cl = read_claims resolve m c in
        add (Report.acks (Observe.unadmitted sp cl) (Observe.stale sp cl));
        List.iter
          (fun (p : Claims.property) ->
            add (Report.outcome sp p (Checker.check sp p)))
          cl.Claims.props;
        List.iter
          (fun (q : Claims.query) ->
            add (Report.query_rows q 0 (Query.run sp q ())))
          cl.Claims.queries;
        Ok ()
  in
  Ok (Buffer.contents b)

(* ── query ─────────────────────────────────────────────────────────────────
   One named question from the model's sibling .claims file. [at] indexes the
   enumerated space, so an out-of-range index is a mis-asked question rather
   than an empty answer — the caller is asking about a situation the model
   never reaches, and saying so is more useful than saying "no rows". *)
let query ~resolve ~model ~name ~at =
  let* m = load resolve model in
  let* sp = build model m in
  let cpath = Filename.remove_extension model ^ ".claims" in
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
  Ok (Report.query_rows q idx (Query.run sp q ~at:st ()))

(* ── derive ────────────────────────────────────────────────────────────────
   A relation from a .rules file. Arguments arrive as a LIST with nulls for the
   unbound positions, rather than as `"(rel a b)"` to be parsed: a tool has
   structure available and should use it, and it keeps the CLI's little query
   parser from being duplicated where it would drift.

   [why] asks for the derivation TREE instead of the rows — the reason this
   verb is worth exposing at all, since it answers "how do you know" and not
   merely "what". It needs every argument ground; a tree of a partial question
   is not a thing. *)
let derive ~resolve ~model ~rules ~relation ~args ~why =
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
    Ok (Report_derive.why t relation ground)
  else
    match Derive_answers.query t relation args with
    | Some (Ok tuples) -> Ok (Report_derive.rows t relation tuples)
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
