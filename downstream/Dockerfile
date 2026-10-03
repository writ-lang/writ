# The downstream regression image: THIS checkout of writ, built and tested,
# then every repository that depends on it, run against it.
#
# WHAT IT IS FOR. The runtime image (../Dockerfile) is a product and runs a
# smoke check. It cannot tell you that a change to the engine broke a worked
# scenario in writ-problems, a generator in writ-arch, the CP-SAT audit in
# writ-scheduling-verification, the translator in mgtt2writ, or the editor
# client in writ-vscode, because none of them live here. This image is the place where they all meet the writ in your
# working tree, uncommitted changes included, before anything is merged.
#
#   make downstream                       # from the writ checkout
#   docker build -f downstream/Dockerfile -t writ-downstream .
#   docker run --rm writ-downstream       # rerun every suite, no rebuild
#   docker run --rm writ-downstream arch  # rerun one suite
#
# A successful BUILD is a pass: every suite runs as a RUN in its own check-*
# stage, the way the runtime image's smoke check does, so `docker build` exits
# non-zero on the first suite that fails and prints that suite's output.
#
# Stages, in order:
#
#   engine       OCaml. Builds the whole tree, runs writ's own suites
#                (`make test`), installs writ, writ-lsp, writ-mcp.
#   mgtt2writ    OCaml. Builds mgtt2writ and runs its unit suite.
#   vscode       Node. Checks out writ-vscode and installs its dependencies.
#   suites       Debian 12 + Python. The binaries from above, node, d2,
#                CP-SAT, and a checkout of each downstream repository.
#   check-*      One per suite, each a RUN of downstream/run.sh.
#   all          Depends on every check-*, and reruns them as its entrypoint.
#
# DOWNSTREAM REVISIONS are build arguments: *_REF is a branch, tag or commit,
# and *_REPO lets a fork stand in. `make downstream` resolves every branch to
# its current commit first and passes the SHA. That matters for the cache: a
# clone keyed on the word "main" would be cached forever and never see a new
# commit, while a clone keyed on a SHA is reused exactly as long as it is right.
#
# Written for the classic builder as well as BuildKit, because the classic one
# is what a machine without the buildx plugin has. So: no RUN --mount, no
# ADD <git url>, no --build-context. Under BuildKit, `--target check-arch`
# builds only that suite's stages. Under the classic builder it builds every
# stage above it too, so use `docker run ... arch` on a built image instead.

ARG OCAML_IMAGE=ocaml/opam:debian-12-ocaml-5.2
# Debian 12 to match OCAML_IMAGE: the binaries are linked against its glibc.
# The unsuffixed python:3.12-slim tag has moved on to a newer Debian.
ARG SUITES_IMAGE=python:3.12-slim-bookworm
# Debian 12 too, for the same reason: its `node` binary is copied across.
ARG NODE_IMAGE=node:22-bookworm-slim

# ---- engine: build and test this checkout ----------------------------------
FROM ${OCAML_IMAGE} AS engine

# The same reason as in ../Dockerfile: WORKDIR makes a missing directory as
# root, and dune running as `opam` then cannot create _build.
USER root
RUN mkdir -p /src /opt/writ && chown opam:opam /src /opt/writ
USER opam
WORKDIR /src

# writ has no library dependencies; dune is the whole toolchain. Installed
# before the COPY so an edit to the source does not reinstall it.
RUN opam install -y dune

# The WHOLE tree, unlike ../Dockerfile's hand-picked list: this stage runs the
# unit suites and builds writ-lsp, so it needs tests/, tooling/lsp and scripts/.
COPY --chown=opam:opam . ./

# `make test` and `make install-writ` are the targets a developer types, so the
# image tests and installs exactly the way a checkout does. install-writ puts
# all three binaries under bin/ and the stdlib under share/writ/lib, the
# layout the resolver expects.
RUN opam exec -- make build test install-writ PREFIX=/opt/writ \
 && /opt/writ/bin/writ --version

# ---- mgtt2writ: build and unit-test the translator --------------------------
# FROM engine for its toolchain only. mgtt2writ vendors writ's JSON reader
# rather than linking this checkout, so its unit suite does not see the change
# under test. The end-to-end check in check-mgtt2writ is the one that does.
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
# npm runs here and stays here. The suites stage gets the checkout with its
# node_modules and one file from this image, the `node` binary, because the
# extension's tests are plain node and need nothing else.
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

# d2 is optional for writ-arch: without it the c4 test prints [skip] and the
# SVG rendering goes unexercised. It is here so that test runs for real.
ARG D2_VERSION=v0.7.1
RUN arch=$(dpkg --print-architecture) \
 && curl -fsSL "https://github.com/terrastruct/d2/releases/download/${D2_VERSION}/d2-${D2_VERSION}-linux-${arch}.tar.gz" \
    | tar xz -C /tmp 2>/dev/null \
 && install -m 755 "/tmp/d2-${D2_VERSION}/bin/d2" /usr/local/bin/d2 \
 && rm -rf "/tmp/d2-${D2_VERSION}" \
 && d2 --version

# writ-scheduling-verification's two Python dependencies, at the bounds its own
# Dockerfile declares. Before the checkouts, because this is the slow layer.
RUN pip install --no-cache-dir "ortools>=9.10" "pyyaml>=6"

# Non-root, as the downstream images run: a suite that writes where it should
# not fails here rather than in someone's container.
RUN useradd -m runner && mkdir /downstream && chown runner:runner /downstream
USER runner
WORKDIR /downstream

# One RUN per repository, each with its own ARGs declared just above it, so a
# new commit in one repository reclones that one and keeps the others cached.
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

# mgtt2writ's end-to-end check, from the same checkout the binary was built
# from, so the fixture and the translator cannot come from different commits.
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
# The COPYs are what make every check a dependency of this stage. Under
# BuildKit, a stage nothing depends on is skipped, so a check that is not
# listed here would silently stop running.
FROM suites AS all
COPY --from=check-problems   /tmp/passed /tmp/passed-problems
COPY --from=check-crosscheck /tmp/passed /tmp/passed-crosscheck
COPY --from=check-arch       /tmp/passed /tmp/passed-arch
COPY --from=check-scheduling /tmp/passed /tmp/passed-scheduling
COPY --from=check-mgtt2writ  /tmp/passed /tmp/passed-mgtt2writ
COPY --from=check-vscode     /tmp/passed /tmp/passed-vscode

ENTRYPOINT ["/downstream/run.sh"]
CMD ["all"]
