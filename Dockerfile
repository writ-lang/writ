# Build the standalone `pol` binary from source and ship a slim runtime that
# runs the Prologue puzzle tests. Two stages: stage 1 compiles `pol` with dune;
# stage 2 is a minimal Debian with `pol` on PATH and the stdlib bundled at
# ../share/pol/lib (so `(load "stdlib.pol")` resolves from anywhere).

# ---- stage 1: build ---------------------------------------------------------
FROM ocaml/opam:debian-12-ocaml-5.2 AS build
WORKDIR /src
# Only what `tooling/cli/pol.exe` needs — the three engine libraries under core/
# and runtime/, the shared load-path library, plus the CLI itself. Every library
# the CLI links must be COPYed or the build stops here, by design: this list is
# the check that `pol` really is a small closed set of libraries. No tooling/lsp,
# tests/, tooling/vscode
# (keeps the build lean and free of ocamlformat/test deps). pol has NO external
# libraries. The stdlib .pol data ships beside the binary.
COPY --chown=opam:opam dune-project ./
COPY --chown=opam:opam core ./core
COPY --chown=opam:opam runtime ./runtime
COPY --chown=opam:opam tooling/cli ./tooling/cli
COPY --chown=opam:opam tooling/loadpath ./tooling/loadpath
RUN opam install -y dune \
 && opam exec -- dune build tooling/cli/pol.exe \
 && mkdir -p /tmp/out/bin /tmp/out/share/pol/lib \
 && cp _build/default/tooling/cli/pol.exe /tmp/out/bin/pol \
 && cp core/stdlib/*.pol /tmp/out/share/pol/lib/

# ---- stage 2: runtime -------------------------------------------------------
FROM debian:12-slim
# git is needed only by the `gitcompare` test (pol compare --git over a
# throwaway two-commit history); pol itself has no runtime deps.
RUN apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /tmp/out/bin/pol /usr/local/bin/pol
COPY --from=build /tmp/out/share/pol/lib /usr/local/share/pol/lib
COPY tests/examples /examples
# Prove the binary is wired before any test runs.
RUN pol check /examples/river/river.pol >/dev/null 2>&1 || \
    { echo "pol failed its smoke check" >&2; exit 1; }
ENTRYPOINT ["/examples/run-tests.sh"]
CMD ["all"]
