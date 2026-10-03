# The downstream regression image: this checkout of writ, uncommitted changes
# included, built and tested, then every repository that depends on it run
# against it.
#
#   make downstream                       # from the writ checkout
#   docker build -f downstream/Dockerfile -t writ-downstream .
#   docker run --rm writ-downstream       # rerun every suite, no rebuild
#   docker run --rm writ-downstream arch  # rerun one suite
#
# A successful build is a pass: each suite is a RUN in its own check-* stage.
#
# *_REF is a branch, tag or commit and *_REPO lets a fork stand in.
# `make downstream` passes commit SHAs, since a clone keyed on "main" would stay
# cached forever.
#
# Works under the classic builder too, so no RUN --mount, ADD <git url> or
# --build-context. There `--target check-arch` builds every stage above it, so
# use `docker run ... arch` on a built image instead.

ARG OCAML_IMAGE=ocaml/opam:debian-12-ocaml-5.2
# Debian 12 to match OCAML_IMAGE's glibc; plain python:3.12-slim has moved on.
ARG SUITES_IMAGE=python:3.12-slim-bookworm
# Debian 12 too: its `node` binary is copied across.
ARG NODE_IMAGE=node:22-bookworm-slim

# ---- engine: build and test this checkout ----------------------------------
FROM ${OCAML_IMAGE} AS engine

# As in ../Dockerfile: WORKDIR would create /src as root.
USER root
RUN mkdir -p /src /opt/writ && chown opam:opam /src /opt/writ
USER opam
WORKDIR /src

# Before the COPY, so a source edit does not reinstall dune.
RUN opam install -y dune

# The whole tree: the suites need tests/, tooling/lsp and scripts/.
COPY --chown=opam:opam . ./

# The same targets a developer types.
RUN opam exec -- make build test install-writ PREFIX=/opt/writ \
 && /opt/writ/bin/writ --version

# ---- mgtt2writ: build and unit-test the translator --------------------------
# FROM engine for its toolchain only: mgtt2writ vendors writ's JSON reader, so
# only the end-to-end check in check-mgtt2writ sees the change under test.
FROM engine AS mgtt2writ
ARG MGTT2WRIT_REPO=https://github.com/mgt-tool/mgtt2writ.git
ARG MGTT2WRIT_REF=main
WORKDIR /home/opam
RUN git clone -q "$MGTT2WRIT_REPO" mgtt2writ \
 && cd mgtt2writ && git checkout -q "$MGTT2WRIT_REF" \
 && git log --oneline -1 \
 && opam exec -- dune build \
 && opam exec -- dune runtest --force \
 && cp -L _build/default/bin/main.exe /home/opam/mgtt2writ.bin

# ---- vscode: the editor client and its dependencies -------------------------
# npm stays in this stage; the suites stage takes the checkout and `node`.
FROM ${NODE_IMAGE} AS vscode
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ARG VSCODE_REPO=https://github.com/writ-lang/writ-vscode.git
ARG VSCODE_REF=main
WORKDIR /build
RUN git clone -q "$VSCODE_REPO" writ-vscode \
 && cd writ-vscode && git checkout -q "$VSCODE_REF" \
 && git log --oneline -1 \
 && npm ci --omit=dev --no-audit --no-fund

# ---- suites: the binaries, the tools, the downstream checkouts --------------
FROM ${SUITES_IMAGE} AS suites

# git: writ-problems' gitcompare scenario drives `writ compare --git`.
# curl: only to fetch d2 below.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Optional for writ-arch; without it the c4 SVG test is skipped.
ARG D2_VERSION=v0.7.1
RUN arch=$(dpkg --print-architecture) \
 && curl -fsSL "https://github.com/terrastruct/d2/releases/download/${D2_VERSION}/d2-${D2_VERSION}-linux-${arch}.tar.gz" \
    | tar xz -C /tmp 2>/dev/null \
 && install -m 755 "/tmp/d2-${D2_VERSION}/bin/d2" /usr/local/bin/d2 \
 && rm -rf "/tmp/d2-${D2_VERSION}" \
 && d2 --version

# writ-scheduling-verification's dependencies; the slow layer, so it goes first.
RUN pip install --no-cache-dir "ortools>=9.10" "pyyaml>=6"

# Non-root, as the downstream images run.
RUN useradd -m runner && mkdir /downstream && chown runner:runner /downstream
USER runner
WORKDIR /downstream

# One RUN per repository, ARGs just above it, so a new commit in one
# reclones only that one.
ARG PROBLEMS_REPO=https://github.com/writ-lang/writ-problems.git
ARG PROBLEMS_REF=main
RUN git clone -q "$PROBLEMS_REPO" writ-problems \
 && git -C writ-problems checkout -q "$PROBLEMS_REF" \
 && git -C writ-problems log --oneline -1

ARG ARCH_REPO=https://github.com/writ-lang/writ-arch.git
ARG ARCH_REF=main
RUN git clone -q "$ARCH_REPO" writ-arch \
 && git -C writ-arch checkout -q "$ARCH_REF" \
 && git -C writ-arch log --oneline -1

ARG SCHEDULING_REPO=https://github.com/writ-lang/writ-scheduling-verification.git
ARG SCHEDULING_REF=main
RUN git clone -q "$SCHEDULING_REPO" writ-scheduling-verification \
 && git -C writ-scheduling-verification checkout -q "$SCHEDULING_REF" \
 && git -C writ-scheduling-verification log --oneline -1

# Fixture and binary from the same mgtt2writ commit.
COPY --from=mgtt2writ --chown=runner:runner /home/opam/mgtt2writ/test /downstream/mgtt2writ/test
COPY --from=mgtt2writ /home/opam/mgtt2writ.bin /usr/local/bin/mgtt2writ

COPY --from=vscode /usr/local/bin/node /usr/local/bin/node
COPY --from=vscode --chown=runner:runner /build/writ-vscode /downstream/writ-vscode

# writ last: it changes on every edit, and everything above it does not.
COPY --from=engine /opt/writ/bin/ /usr/local/bin/
COPY --from=engine /opt/writ/share/writ/lib /usr/local/share/writ/lib
COPY --chown=runner:runner downstream/run.sh /downstream/run.sh

# ---- check-*: one stage per suite ------------------------------------------
FROM suites AS check-problems
RUN /downstream/run.sh problems && touch /tmp/passed

FROM suites AS check-crosscheck
RUN /downstream/run.sh crosscheck && touch /tmp/passed

FROM suites AS check-arch
RUN /downstream/run.sh arch && touch /tmp/passed

FROM suites AS check-scheduling
RUN /downstream/run.sh scheduling && touch /tmp/passed

FROM suites AS check-mgtt2writ
RUN /downstream/run.sh mgtt2writ && touch /tmp/passed

FROM suites AS check-vscode
RUN /downstream/run.sh vscode && touch /tmp/passed

# ---- all: the default target ------------------------------------------------
# BuildKit skips stages nothing depends on, so a check not COPYed here would
# silently stop running.
FROM suites AS all
COPY --from=check-problems   /tmp/passed /tmp/passed-problems
COPY --from=check-crosscheck /tmp/passed /tmp/passed-crosscheck
COPY --from=check-arch       /tmp/passed /tmp/passed-arch
COPY --from=check-scheduling /tmp/passed /tmp/passed-scheduling
COPY --from=check-mgtt2writ  /tmp/passed /tmp/passed-mgtt2writ
COPY --from=check-vscode     /tmp/passed /tmp/passed-vscode

ENTRYPOINT ["/downstream/run.sh"]
CMD ["all"]
