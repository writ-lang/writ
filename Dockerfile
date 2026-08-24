# The writ runtime image: `writ`, the standard library, and git.
#
# WHAT IT IS FOR, since a Dockerfile in a compiler repository is a fair thing to
# ask about. It is this repository's distributable — `make image` tags it
# locally and .github/workflows/image-publish.yml publishes it as
# ghcr.io/writ-lang/writ on a version tag. github.com/writ-lang/writ-problems
# builds FROM it, which is how the worked scenarios run with nothing installed
# on the host but Docker. It is a product, not a test rig.
#
# It used to BE a test rig — it copied the examples in and ran them as its
# entrypoint. They live in their own repository now, so this ships the tool and
# nothing else, and its smoke check uses a model written inline below rather
# than a file that could move again.
#
# Two stages: stage 1 compiles with dune; stage 2 is a minimal Debian carrying
# the result. The stdlib lands at ../share/writ/lib relative to the binary, which
# is where the resolver looks, so `(load "stdlib.writ")` works from any
# directory.
#
# It carries `writ` and `writ-mcp`, and NOT writ-lsp.
#
# writ-mcp is here so the Claude plugin can run the server in a container and
# never put native code on the host — the platform problem that stopped the
# plugin bundling a binary. It reads models from a mount; see plugins/writ/bin/.
#
# writ-lsp stays out because an editor extension spawns its server locally and
# gains nothing from a container.
#
# Stage 1 lists every library each binary links, and that list is still the
# check that they are a small closed set — it is simply a longer list now than
# when only the CLI shipped.

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
# Only what the two executables need — the three engine libraries under core/
# and runtime/, the shared bridges (load path, JSON, SQL), plus the CLI and the
# MCP server themselves. Every library either binary links must be COPYed or the
# build stops here, by design: this list is the check that they really are a
# small closed set of libraries. No tooling/lsp, tests/ (keeps the build lean
# and free of ocamlformat/test deps). writ has NO external libraries. The stdlib
# .writ data ships beside the binary.
#
# The failure mode this list has, and the reason to read the dune files rather
# than this comment when adding a verb: a library added to tooling/cli/dune and
# not added here builds everywhere except in the image, and the image is what
# ships. `writ_sql` did exactly that.
COPY --chown=opam:opam dune-project ./
COPY --chown=opam:opam core ./core
COPY --chown=opam:opam runtime ./runtime
COPY --chown=opam:opam tooling/cli ./tooling/cli
COPY --chown=opam:opam tooling/loadpath ./tooling/loadpath
COPY --chown=opam:opam tooling/json ./tooling/json
COPY --chown=opam:opam tooling/sql ./tooling/sql
COPY --chown=opam:opam tooling/mcp ./tooling/mcp
RUN opam install -y dune \
 && opam exec -- dune build tooling/cli/writ.exe tooling/mcp/bin/writ_mcp.exe \
 && mkdir -p /tmp/out/bin /tmp/out/share/writ/lib \
 && cp _build/default/tooling/cli/writ.exe /tmp/out/bin/writ \
 && cp _build/default/tooling/mcp/bin/writ_mcp.exe /tmp/out/bin/writ-mcp \
 && cp core/stdlib/* /tmp/out/share/writ/lib/

# ---- stage 2: runtime -------------------------------------------------------
FROM debian:12-slim

# git is a RUNTIME dependency of the tool, not of anyone's tests. `writ compare
# --git R1 R2 MODEL` shells out to read two revisions of a model
# (tooling/cli/cmd_compare.ml), so an image without git ships a verb that
# cannot work. Nothing else writ does needs anything.
RUN apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /tmp/out/bin/ /usr/local/bin/
COPY --from=build /tmp/out/share/writ/lib /usr/local/share/writ/lib

# Prove the image is wired before anyone uses it: a model written HERE, so the
# check depends on nothing that could be removed from somewhere else. It also
# exercises the load path — `(load "stdlib.writ")` must resolve from a directory
# that is not the install prefix — and it does that TWICE, once for a model and
# once for a .rules file, because the two libraries ship by the same copy and a
# glob narrowed back to *.writ would drop the second silently.
#
# git is checked HERE rather than after a `docker push`, because git missing is
# a property of the image and not of the registry: `writ compare --git` shells
# out to it, so an image without it ships a verb that cannot run. Checked at
# this line it is checked by every build there is — `make image`, the pull
# request job, and the publish — instead of only by the one workflow that used
# to run it afterwards.
RUN printf '%s\n' \
      '(load "stdlib.writ")' \
      '(schema s (type v (lo hi)) (type box (arrow f (to v))))' \
      '(instance i s (box b (f lo)))' \
      '(use s)' '(initial i)' \
      '(transition raise (when (is b.f lo)) (do (set b.f hi)))' \
      > /tmp/smoke.writ \
 && cd /tmp && writ check /tmp/smoke.writ | grep -q 'states: 2' \
 && printf '%s\n' '(load "ct.rules")' > /tmp/smoke.rules \
 && writ derive /tmp/smoke.writ /tmp/smoke.rules reach | grep -q '(3 rows)' \
 && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
      | writ-mcp | grep -q '"protocolVersion"' \
 && { command -v git >/dev/null \
      || { echo "no git: writ compare --git would not run" >&2; exit 1; }; } \
 && rm -f /tmp/smoke.writ /tmp/smoke.rules

ENTRYPOINT ["writ"]
CMD ["--help"]
