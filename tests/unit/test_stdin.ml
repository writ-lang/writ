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
  Printf.printf "test_stdin: %d checks passed\n" !checks
