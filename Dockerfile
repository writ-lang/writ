# The writ runtime image: `writ`, `writ-mcp`, the standard library, and git.
# Published as ghcr.io/writ-lang/writ; writ-problems builds FROM it. writ-mcp is
# here so the Claude plugin can run it in a container (see plugins/writ/bin/);
# writ-lsp is not, because editors spawn their server locally.

# ---- stage 1: build ---------------------------------------------------------
FROM ocaml/opam:debian-12-ocaml-5.2 AS build

# WORKDIR would create /src as root, and dune (running as opam) could not
# create _build in it.
USER root
RUN mkdir -p /src && chown opam:opam /src
USER opam
WORKDIR /src
# Every library either binary links must be COPYed here. A library added to
# tooling/cli/dune but not here builds everywhere except in the image, which is
# what ships — check the dune files when adding one.
COPY --chown=opam:opam dune-project ./
COPY --chown=opam:opam core ./core
COPY --chown=opam:opam runtime ./runtime
COPY --chown=opam:opam tooling/cli ./tooling/cli
COPY --chown=opam:opam tooling/loadpath ./tooling/loadpath
COPY --chown=opam:opam tooling/json ./tooling/json
COPY --chown=opam:opam tooling/sql ./tooling/sql
COPY --chown=opam:opam tooling/report_json ./tooling/report_json
COPY --chown=opam:opam tooling/mcp ./tooling/mcp
RUN opam install -y dune \
 && opam exec -- dune build tooling/cli/writ.exe tooling/mcp/bin/writ_mcp.exe \
 && mkdir -p /tmp/out/bin /tmp/out/share/writ/lib \
 && cp _build/default/tooling/cli/writ.exe /tmp/out/bin/writ \
 && cp _build/default/tooling/mcp/bin/writ_mcp.exe /tmp/out/bin/writ-mcp \
 && cp core/stdlib/* /tmp/out/share/writ/lib/

# ---- stage 1b: the certificate checker --------------------------------------
# writ-cert ships in the image so `docker run writ check` is certified by
# default. Written to match lean/Dockerfile instruction for instruction, so the
# two share cached layers.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS lean

ARG ELAN_VERSION=v4.2.4
ARG LEAN_VERSION=v4.33.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates=20250419~deb12u1 \
      curl=7.88.1-10+deb12u15 \
      git=1:2.39.5-0+deb12u3 \
      gcc=4:12.2.0-3 \
      libc6-dev=2.36-9+deb12u14 \
      make=4.3-4.1 \
 && rm -rf /var/lib/apt/lists/*

ENV ELAN_HOME=/opt/elan
ENV PATH=/opt/elan/bin:$PATH

RUN curl -fsSL --proto '=https' --tlsv1.2 \
      "https://github.com/leanprover/elan/releases/download/${ELAN_VERSION}/elan-$(uname -m)-unknown-linux-gnu.tar.gz" \
      | tar -xz -C /tmp \
 && /tmp/elan-init -y --no-modify-path --default-toolchain "leanprover/lean4:${LEAN_VERSION}" \
 && rm -f /tmp/elan-init \
 && lean --version && lake --version

WORKDIR /w
COPY lean/lean-toolchain lean/lakefile.toml lean/WritCert.lean lean/Main.lean ./
COPY lean/WritCert ./WritCert
COPY lean/scripts/static-cc.sh ./scripts/
RUN LEAN_CC=/w/scripts/static-cc.sh lake build writ-cert \
 && strip .lake/build/bin/writ-cert \
 && cp .lake/build/bin/writ-cert /writ-cert

# ---- stage 2: runtime -------------------------------------------------------
FROM debian:12-slim

# git is a runtime dependency: `writ compare --git` shells out to it.
RUN apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /tmp/out/bin/ /usr/local/bin/
COPY --from=build /tmp/out/share/writ/lib /usr/local/share/writ/lib
COPY --from=lean /writ-cert /usr/local/bin/writ-cert

# Smoke test on a model written inline. It loads from a directory outside the
# install prefix, once for a .writ and once for a .rules library, since both
# ship by the same copy. Checking git here covers every build, not just publish.
RUN printf '%s\n' \
      '(load "stdlib.writ")' \
      '(schema s (type v (lo hi)) (type box (arrow f (to v))))' \
      '(instance i s (box b (f lo)))' \
      '(use s)' '(initial i)' \
      '(transition raise (when (is b.f lo)) (do (set b.f hi)))' \
      > /tmp/smoke.writ \
 && cd /tmp && writ check /tmp/smoke.writ > /tmp/smoke.out \
 && grep -q 'states: 2' /tmp/smoke.out \
 && { grep -q '^certified:' /tmp/smoke.out \
      || { echo "writ check was not certified:" >&2; cat /tmp/smoke.out >&2; exit 1; }; } \
 && printf '%s\n' '(load "ct.rules")' > /tmp/smoke.rules \
 && writ derive /tmp/smoke.writ /tmp/smoke.rules reach | grep -q '(3 rows)' \
 && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
      | writ-mcp | grep -q '"protocolVersion"' \
 && { command -v git >/dev/null \
      || { echo "no git: writ compare --git would not run" >&2; exit 1; }; } \
 && rm -f /tmp/smoke.writ /tmp/smoke.rules /tmp/smoke.out /tmp/smoke.cert.json

ENTRYPOINT ["writ"]
CMD ["--help"]
