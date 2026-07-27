# Build pol from source and ship a slim runtime carrying it. Two stages: stage 1
# compiles with dune; stage 2 is a minimal Debian with `pol` on PATH and the
# stdlib bundled at ../share/pol/lib, so `(load "stdlib.pol")` resolves from
# anywhere.
#
# The CLI ONLY — not pol-lsp, not pol-mcp. Stage 1 copies just the libraries
# `tooling/cli/pol.exe` links, and that list is itself the check that `pol` is a
# small closed set (see below); pulling the servers in would cost that check to
# ship two binaries nothing in a container asks for. An editor and an MCP client
# both run on the host, where `opam install pol` puts all three.
#
# It used to end by running the worked examples. Those live in
# github.com/sajonaro/pol-problems now, and this image is what they will
# eventually install rather than compile — so it ships the TOOL and nothing
# else, and its smoke check uses a model written inline here.

# ---- stage 1: build ---------------------------------------------------------
FROM ocaml/opam:debian-12-ocaml-5.2 AS build

# The build directory has to be MADE for the opam user. `WORKDIR` creates a
# missing directory as root whatever the image's USER is, and this image runs
# as `opam` — so dune's first act, mkdir _build, failed with EACCES. Copying
# files in with --chown does not help: the files were fine, the directory
# holding them was not. It stayed hidden for as long as the layer stayed
# cached, which is how a broken Dockerfile usually hides.
USER root
RUN mkdir -p /src && chown opam:opam /src
USER opam
WORKDIR /src
# Only what `tooling/cli/pol.exe` needs — the three engine libraries under core/
# and runtime/, the shared load-path library, plus the CLI itself. Every library
# the CLI links must be COPYed or the build stops here, by design: this list is
# the check that `pol` really is a small closed set of libraries. No tooling/lsp,
# tests/
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
COPY --from=build /tmp/out/bin/ /usr/local/bin/
COPY --from=build /tmp/out/share/pol/lib /usr/local/share/pol/lib

# Prove the image is wired before anyone uses it: a model written HERE, so the
# check depends on nothing that could be removed from somewhere else. It also
# exercises the load path — `(load "stdlib.pol")` must resolve from a directory
# that is not the install prefix.
RUN printf '%s\n' \
      '(load "stdlib.pol")' \
      '(schema s (type v (lo hi)) (type box (arrow f (to v))))' \
      '(instance i (of s) (box b) (f (b lo)))' \
      '(use s)' '(initial i)' \
      '(transition raise (when (is b.f lo)) (do (set b.f hi)))' \
      > /tmp/smoke.pol \
 && cd /tmp && pol check /tmp/smoke.pol | grep -q 'states: 2' \
 && rm -f /tmp/smoke.pol

ENTRYPOINT ["pol"]
CMD ["--help"]
