# The pol runtime image: `pol`, the standard library, and git.
#
# WHAT IT IS FOR, since a Dockerfile in a compiler repository is a fair thing to
# ask about. It is this repository's distributable — `make image` tags it
# locally and .github/workflows/image.yml publishes it as
# ghcr.io/sajonaro/pol on a version tag. github.com/sajonaro/pol-problems
# builds FROM it, which is how the worked scenarios run with nothing installed
# on the host but Docker. It is a product, not a test rig.
#
# It used to BE a test rig — it copied the examples in and ran them as its
# entrypoint. They live in their own repository now, so this ships the tool and
# nothing else, and its smoke check uses a model written inline below rather
# than a file that could move again.
#
# Two stages: stage 1 compiles with dune; stage 2 is a minimal Debian carrying
# the result. The stdlib lands at ../share/pol/lib relative to the binary, which
# is where the resolver looks, so `(load "stdlib.pol")` works from any
# directory.
#
# The CLI ONLY — not pol-lsp, not pol-mcp. Stage 1 copies exactly the libraries
# `tooling/cli/pol.exe` links, and that list is itself the check that `pol` is a
# small closed set; pulling the servers in would spend that check to ship two
# binaries nothing in a container asks for. An editor and an MCP client both run
# on the host, where installing pol puts all three.

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

# git is a RUNTIME dependency of the tool, not of anyone's tests. `pol compare
# --git R1 R2 MODEL` shells out to read two revisions of a model
# (tooling/cli/cmd_compare.ml), so an image without git ships a verb that
# cannot work. Nothing else pol does needs anything.
RUN apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

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
