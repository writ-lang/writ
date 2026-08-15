(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [--stdin] — a model read from a pipe.

   The sentinel is internal: the dispatch substitutes it for the model path
   when --stdin is given, and the resolver in [Cli_io] answers it. It is
   spelled "<stdin>" for how it reads in a diagnostic — a parse error in a
   piped model must say <stdin>:12:3 rather than name a file that does not
   exist. *)

let checks = ref 0

let check name cond =
  incr checks;
  if not cond then failwith ("FAILED: " ^ name)

let () =
  check "sentinel is <stdin>" (Cli_io.stdin_name = "<stdin>");
  (* dirname of the sentinel is ".", so a (load …) from a piped model
     searches the cwd first — see Load_path.candidates. *)
  check "sentinel dirname is ." (Filename.dirname Cli_io.stdin_name = ".");
  check "sentinel basename is itself"
    (Filename.basename Cli_io.stdin_name = Cli_io.stdin_name);
  (* The dispatch strips flags before counting positionals, which is what
     makes `writ query --stdin health` unambiguous where a bare `writ query
     health` would not be: with the model removed from the positionals, the
     remaining arity is fixed. *)
  let strip = Writ_dispatch.take_stdin in
  check "strip finds the flag" (fst (strip [ "--stdin"; "health" ]) = true);
  check "strip removes it" (snd (strip [ "--stdin"; "health" ]) = [ "health" ]);
  check "strip anywhere" (fst (strip [ "health"; "--stdin" ]) = true);
  check "strip absent" (fst (strip [ "health" ]) = false);
  check "strip leaves order" (snd (strip [ "a"; "--stdin"; "b" ]) = [ "a"; "b" ]);
  Printf.printf "test_stdin: %d checks passed\n" !checks
