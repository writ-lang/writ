/-
Copyright (C) 2026 Alex Kunich
SPDX-License-Identifier: AGPL-3.0-or-later

`writ-cert` — check a certificate from `writ check --certificate`.

    writ check river.writ --claims river.claims --certificate river.cert.json
    writ-cert river.cert.json

Exit status: 0 every line certified and in agreement with writ; 1 some line
DISAGREES with writ; 2 the input could not be read; 3 nothing disagrees but
something could not be certified.
-/
-- Only the checker: the tactic half of the package (`WritCert.Tactic`) links the
-- whole Lean elaborator, and a checker has no use for it.
import WritCert.Verify

open Writ Writ.Verify

def usage : String :=
  "usage: writ-cert FILE.json | -\n\n" ++
  "Check a certificate written by `writ check MODEL.writ [--claims F] --certificate FILE`:\n" ++
  "re-derive every answer in writ's report from the kernel semantics, and\n" ++
  "say for each whether it is certified and whether writ got it right.\n"

def main (args : List String) : IO UInt32 := do
  let text ← match args with
    | ["-"] => (← IO.getStdin).readToEnd
    | [f] =>
      if f == "--help" || f == "-h" then
        IO.println usage; return 0
      try IO.FS.readFile f catch e =>
        IO.eprintln s!"writ-cert: {e}"; return 2
    | _ => IO.eprintln usage; return 2
  match Writ.Import.parse text with
  | .error e => IO.eprintln s!"writ-cert: {e}"; return 2
  | .ok cert =>
    let r := verify cert
    IO.println s!"writ {r.writ} — certificate checked against the kernel semantics"
    for l in r.lines do
      IO.println s!"{l.status.tag}  {l.what}  — {l.detail}"
    match r.worst with
    | .disagrees => IO.println "verdict: writ's report DISAGREES with its own model"; return 1
    | .uncertified => IO.println "verdict: no disagreement, but not everything was certified"; return 3
    | _ => IO.println "verdict: every answer certified"; return 0
