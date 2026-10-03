(lang dune 3.0)

; writ.opam is generated from the (package) stanza below; edit this file, not
; the .opam.

(name writ)

; The one version number: opam, `writ --version` and `make release` all read it.
(version 0.3.0)

(generate_opam_files true)

(authors "Alex Kunich")

(maintainers "alex.kunich@gmail.com")

(license AGPL-3.0-or-later)

(source
 (github writ-lang/writ))

(homepage "https://github.com/writ-lang/writ")

(bug_reports "https://github.com/writ-lang/writ/issues")

(package
 (name writ)
 (synopsis
  "Partial Olog — a language for modelling real-world domains, and an interrogator that proves facts about them")
 (description
  "A Writ model is a state machine written down: a schema (the kinds of things that exist, the typed arrows between them, and the laws certain arrow-chains must obey), an instance (one starting configuration) and guarded transitions. The `writ` tool enumerates every reachable situation and answers the questions put to it by exhaustion, printing a concrete route as evidence. The whole language is twenty-six words; everything else is a library of forms over them. Questions live apart from models, in .claims files, so one question suite can be asked of many models and comparing two versions of a model is a tool operation. OCaml stdlib only — no external dependencies.")
 (depends
  (ocaml
   (>= 4.14))
  (dune
   (>= 3.0))))
