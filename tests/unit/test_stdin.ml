(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [--stdin]: the sentinel "<stdin>" stands for the model path, so a
   diagnostic reads <stdin>:12:3. *)

let checks = ref 0

let check name cond =
  incr checks;
  if not cond then failwith ("FAILED: " ^ name)

let () =
  check "sentinel is <stdin>" (Cli_io.stdin_name = "<stdin>");
  (* A load from a piped model searches the cwd first. *)
  check "sentinel dirname is ." (Filename.dirname Cli_io.stdin_name = ".");
  check "sentinel basename is itself"
    (Filename.basename Cli_io.stdin_name = Cli_io.stdin_name);

  (* Flags are stripped before positionals are counted. *)
  let takec = Writ_dispatch.take_claims in
  check "claims: absent" (takec [ "m.writ"; "q" ] = (None, [ "m.writ"; "q" ]));
  check "claims: taken with its file"
    (takec [ "m.writ"; "q"; "--claims"; "s.claims" ]
    = (Some "s.claims", [ "m.writ"; "q" ]));
  check "claims: taken from the middle"
    (takec [ "--claims"; "s.claims"; "m.writ"; "q" ]
    = (Some "s.claims", [ "m.writ"; "q" ]));
  check "claims: composes with --at"
    (takec [ "m.writ"; "q"; "--claims"; "s.claims"; "--at"; "7" ]
    = (Some "s.claims", [ "m.writ"; "q"; "--at"; "7" ]));
  (* A trailing --claims reaches the usage message, not the sibling. *)
  check "claims: trailing flag is not swallowed"
    (takec [ "m.writ"; "q"; "--claims" ] = (None, [ "m.writ"; "q"; "--claims" ]));
  check "claims: strips alongside --stdin"
    (let stdin_, r =
       Writ_dispatch.take_stdin [ "--stdin"; "q"; "--claims"; "s" ]
     in
     let c, r = takec r in
     stdin_ = true && c = Some "s" && r = [ "q" ]);
  let strip = Writ_dispatch.take_stdin in
  check "strip finds the flag" (fst (strip [ "--stdin"; "health" ]) = true);
  check "strip removes it" (snd (strip [ "--stdin"; "health" ]) = [ "health" ]);
  check "strip anywhere" (fst (strip [ "health"; "--stdin" ]) = true);
  check "strip absent" (fst (strip [ "health" ]) = false);
  check "strip leaves order" (snd (strip [ "a"; "--stdin"; "b" ]) = [ "a"; "b" ]);
  let takej = Writ_dispatch.take_json in
  check "json: absent" (takej [ "m.writ" ] = (false, [ "m.writ" ]));
  check "json: taken anywhere"
    (takej [ "m.writ"; "--json"; "--claims"; "c" ]
    = (true, [ "m.writ"; "--claims"; "c" ]));
  check "json: composes with --stdin"
    (let j, r = takej [ "--stdin"; "--json" ] in
     j && fst (strip r) && snd (strip r) = []);
  (* An n/a property is a finding: `check` exits 1 on it, so a gate that
     reads the exit status cannot be talked out of a question by an edit that
     deletes what the question asks about. *)
  let resolve : Writ_syntax.Loader.resolve =
   fun name ->
    let rec up dir n =
      let p = Filename.concat dir name in
      let f = Filename.concat dir ("fixtures/" ^ name) in
      let s = Filename.concat dir ("core/stdlib/" ^ name) in
      let read p =
        let ic = open_in_bin p in
        let t = really_input_string ic (in_channel_length ic) in
        close_in ic;
        Ok t
      in
      if Sys.file_exists f then read f
      else if Sys.file_exists s then read s
      else if Sys.file_exists p then read p
      else if n = 0 then
        Error { Writ_data.Errors.pos = None; msg = "cannot resolve " ^ name }
      else up (Filename.dirname dir) (n - 1)
    in
    up (Sys.getcwd ()) 8
  in
  (match Writ_syntax.Loader.read_model resolve "na.writ" with
  | Error e -> check ("na.writ: " ^ Writ_data.Errors.to_string e) false
  | Ok m -> (
      match Writ_runtime.Space.build m with
      | Error e -> check ("na space: " ^ e) false
      | Ok sp ->
          let a = Cmd_check.answer resolve m sp (Some "na.claims") in
          check "an n/a property makes check exit 1" (a.Cmd_check.exit_code = 1)
      ));
  Printf.printf "test_stdin: %d checks passed\n" !checks
