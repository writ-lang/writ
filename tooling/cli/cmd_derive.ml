(* [Cmd_derive] — the [pol derive] verb (extension §4): run a .rules file
   against a model's already-enumerated universe and print what it derives.
   Three forms, one code path: a bare RELATION is the fully unbound query, a
   [(RELATION ARG…)] datum binds the arguments that are not ALL-CAPS, and
   [--why] walks one ground fact's derivation instead of listing rows.

   Exit status is narrower here than for the other verbs (§9, kernel §18):
   0 for any well-formed query INCLUDING an empty answer set — an empty
   relation is an answer — and 2 for input this cannot read, which covers a
   relation the rules file never declared. It never exits 1: nothing `pol
   derive` can be asked is bad news. *)

open Pol_data
open Pol_syntax
open Pol_runtime
open Cli_io

(* The query argument is read by the LANGUAGE's own reader, so [(reach 0 X)]
   parses the way it would in a file and no second notation exists. A term is a
   variable iff it is ALL-CAPS ([Rules.is_var] — the same predicate the .rules
   parser applies), and a variable is simply an unbound column. Everything else
   is a constant, read against its column's sort by [Derive_table]: an integer
   in a Situation column is a state index, an atom in an Entity column is an
   entity name. *)
let parse_ask (spec : string) : string * string option list option =
  let arg (d : Reader.t) : string option =
    match d with
    | Reader.Atom (a, _) -> if Rules.is_var a then None else Some a
    | Reader.List _ ->
        die 2 ("a query argument is an atom, not a list: " ^ Reader.to_string d)
  in
  match Reader.read_string spec with
  | Ok [ Reader.Atom (r, _) ] -> (r, None)
  | Ok [ Reader.List (Reader.Atom (r, _) :: ts, _) ] ->
      (r, Some (List.map arg ts))
  | _ -> die 2 ("a query is a relation name or a (RELATION ARG…) datum: " ^ spec)

(* [--why] asks why ONE fact holds, so every column must be given. A variable
   there is not an empty answer, it is a question this verb does not answer —
   list the rows and pick one. *)
let ground (spec : string) (args : string option list) : string list =
  List.map
    (function
      | Some a -> a
      | None ->
          die 2
            ("--why needs a fact with every argument given, not a variable: "
           ^ spec))
    args

let run (model : string) (rules_path : string) ~(why : bool) (spec : string) =
  let m = load_model (make_resolve model) model in
  let sp = build_space model m in
  (* Two resolvers, because [(load …)] searches the INCLUDING file's directory
     first (design D3) and the rules file need not sit beside the model. *)
  let prog = read_rules (make_resolve rules_path) m rules_path in
  let t = Derive.run sp prog in
  let rel, given = parse_ask spec in
  let arity =
    match Derive_table.sorts_of t rel with
    | Some ss -> List.length ss
    (* An undeclared relation is an AUTHOR error, not an empty answer: the
       question names something the rules file never brought into existence. *)
    | None -> die 2 ("no relation named `" ^ rel ^ "` in " ^ rules_path)
  in
  let args =
    match given with None -> List.init arity (fun _ -> None) | Some a -> a
  in
  if List.length args <> arity then
    die 2
      (rel ^ " takes " ^ string_of_int arity ^ " arguments, not "
      ^ string_of_int (List.length args)
      ^ ": " ^ spec);
  let answer =
    if why then Report_derive.why t rel (ground spec args)
    else
      match Derive_table.query t rel args with
      | Some tuples -> Report_derive.rows t rel tuples
      (* Unreachable: the arity and the declaration were both checked above. *)
      | None -> die 2 ("no relation named `" ^ rel ^ "` in " ^ rules_path)
  in
  say answer;
  flush stdout;
  exit 0
