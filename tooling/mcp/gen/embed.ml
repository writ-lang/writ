(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Build step: embed the guide's markdown topics (tooling/mcp/guide/*.md) as an
   OCaml list, so writ-mcp serves them with no files to install. A topic is
   named by its file: syntax.model.md is `syntax.model`. *)

let read path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let () =
  let files =
    Array.to_list Sys.argv |> List.tl
    |> List.filter (fun f -> Filename.check_suffix f ".md")
    |> List.sort compare
  in
  print_string "let topics = [\n";
  List.iter
    (fun f ->
      Printf.printf "  (%S, %S);\n"
        (Filename.remove_extension (Filename.basename f))
        (read f))
    files;
  print_string "]\n"
