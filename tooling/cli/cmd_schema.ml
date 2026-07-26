(* [Cmd_schema] — the [pol schema] verb, beside its sibling verbs rather than
   inside the dispatch module.

   Emits the model's SCHEMA as data: an instance of the standard library's
   [olog] schema (kernel §17), as [pol control] does for the move list.
   [Schema_data.olog] builds the string; this module does the printing. The
   instance name is the model's basename + [-schema].

   No space is built. A schema is static — every arrow of [olog] is `fixed` —
   so nothing here needs the situation graph, and asking for one would make the
   export cost of a model with a large space absurd for what it prints. *)

open Pol_data
open Pol_runtime
open Cli_io

let run (model : string) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let name = Filename.remove_extension (Filename.basename model) in
  say (Schema_data.olog name m.Model.schema);
  flush stdout;
  exit 0
