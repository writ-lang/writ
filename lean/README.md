# writ in Lean

writ answers questions about a model by exploring every situation it can reach.
This package checks those answers independently. It holds three things:

- **a reference semantics** — what a writ model means, as plain Lean
  definitions ([WritCert/Semantics.lean](WritCert/Semantics.lean));
- **`writ-cert`** — a checker, proved sound against those definitions, that
  re-derives every line of a `writ check` report. `writ check` runs it
  automatically ([docs/certificates.md](../docs/certificates.md));
- **`by writ`** — a tactic that turns a writ property into a kernel-checked
  Lean theorem:

```lean
writ_model river from "river.writ" claims "river.claims"

theorem river_solvable : river.solvable.Holds river.model := by writ
```

The key theorem is `checkCert_sound`: if a certificate passes the checker, its
verdict is the property's truth — for `possible`, `never`, `live` and fair
`inevitable`. The proofs use no `sorry` and only Lean's three standard axioms.
The code that *searches* for evidence is not proved; a bug there can lose an
answer, never produce a wrong one.

Lean runs only in Docker (pinned to v4.33.1):

```sh
make build    # every proof and example
make test     # fixtures certify; tampered certificates are refused
make check F=river.cert.json
```

The static `writ-cert` binary that writ's tarball and image ship comes from the
`static` stage of the [Dockerfile](Dockerfile).
