(lang dune 3.0)

; `pol` is a real opam package: `opam install .` (or `opam pin add pol .`) builds
; the CLI and the language server and installs them together with the .pol
; standard library. The stdlib install stanza lives in the root `dune` — it puts
; core/stdlib/*.pol under <prefix>/share/pol/lib/, which is exactly where the
; resolver in tooling/cli/cli_io.ml looks (<exe>/../share/pol/lib), so a `(load
; "stdlib.pol")` resolves from any directory once installed.
;
; pol.opam is GENERATED from the (package) stanza below — edit this file, not
; the .opam, and run `dune build @install` (or any `make build`) to regenerate.

(name pol)

; The single source of truth for "which pol is this": opam publishes it,
; `pol --version` prints it (tooling/cli/dune generates the module from it), and
; `make release` names the tarball with it. Bump it here and nowhere else.
(version 0.1.0)

(generate_opam_files true)

(authors "Alex Kunich")

(maintainers "alex.kunich@gmail.com")

(license AGPL-3.0-or-later)

(source
 (github sajonaro/pol))

(homepage "https://github.com/sajonaro/pol")

(bug_reports "https://github.com/sajonaro/pol/issues")

(package
 (name pol)
 (synopsis
  "Partial Olog — a language for modelling real-world domains, and an interrogator that proves facts about them")
 (description
  "A Pol model is a state machine written down: a schema (the kinds of things that exist, the typed arrows between them, and the laws certain arrow-chains must obey), an instance (one starting configuration) and guarded transitions. The `pol` tool enumerates every reachable situation and answers the questions put to it by exhaustion, printing a concrete route as evidence. The whole language is twenty-eight words; everything else is a library of forms over them. Questions live apart from models, in .claims files, so one question suite can be asked of many models and comparing two versions of a model is a tool operation. OCaml stdlib only — no external dependencies.")
 (depends
  (ocaml
   (>= 4.14))
  (dune
   (>= 3.0))))
