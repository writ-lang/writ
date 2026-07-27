(* [Cmd_control] — the [pol control] verb, kept beside its sibling verbs rather
   than inside the dispatch module.

   Emits the model's move list as data: an instance of the standard library's
   [quiver] schema (kernel §17). [Control.quiver] builds the string; this module
   does the printing. The instance name is the model's basename + [-control]. *)

open Pol_runtime
open Cli_io

let run (model : string) =
  let resolve = make_resolve model in
  let m = load_model resolve model in
  let name = Filename.remove_extension (Filename.basename model) in
  say (Control.quiver name m);
  flush stdout;
  exit 0
