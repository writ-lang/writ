# writ-cert — the Lean checker for writ's certificates, built in a box.
#
# Lean is not a thing you apt-get. elan is its toolchain manager and the
# toolchain is half a gigabyte, so the build happens here and the version is
# written down in three places that have to agree: this file, lean-toolchain,
# and docker-compose.yml. Everything is pinned — the base image by digest, elan
# by tag, Lean by version. The toolchain stage is the same, instruction for
# instruction, as the other Lean projects on this machine use, so its layers
# come from the cache.

# writ itself, for the stages that run it: the image `make image` builds from
# the repository above (Debian 12, like this one, so its binary runs here).
ARG WRIT_IMAGE=writ:latest
FROM ${WRIT_IMAGE} AS writ

FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS toolchain

ARG ELAN_VERSION=v4.2.4
ARG LEAN_VERSION=v4.33.1

# Lean shells out to a C compiler for the final link, and lake fetches over
# https.  git is here because lake wants it even with no dependencies.
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

# --- the toolchain, with writ beside it --------------------------------------
#
# For `make test` and `make corpus`, which write certificates and then check
# them, and for `writ_model … from "MODEL.writ"`, which runs writ while Lean
# elaborates. Only these stages need the writ image; `make build` never pulls it.

FROM toolchain AS with-writ
COPY --from=writ /usr/local/bin/writ /usr/local/bin/writ
COPY --from=writ /usr/local/share/writ/lib /usr/local/share/writ/lib

# --- the checker and its proofs ----------------------------------------------
#
# Building IS the proof check: every theorem in WritCert/ is re-checked by the
# kernel here, and Examples/ discharges real writ properties with `by writ`.

FROM toolchain AS build
COPY lean-toolchain lakefile.toml ./
COPY WritCert.lean Main.lean Examples.lean ./
COPY WritCert ./WritCert
COPY Examples ./Examples
RUN lake build

# --- the checker, static ------------------------------------------------------
#
# What writ's release tarball ships: every binary in it is statically linked,
# so it runs on any Linux of its architecture. scripts/static-cc.sh says what
# that takes. Built FROM build, so it cannot exist unless every proof checked;
# and refused here, not downstream, if the link came out dynamic after all.

FROM build AS static
COPY scripts/static-cc.sh ./scripts/
# The build stage linked writ-cert already, dynamically, and lake does not count
# LEAN_CC among a link's inputs — so without this it would call the old binary
# up to date and the check below would (rightly) refuse it.
RUN rm -f .lake/build/bin/writ-cert* \
 && LEAN_CC=/w/scripts/static-cc.sh lake build writ-cert \
 && strip .lake/build/bin/writ-cert \
 && { ldd .lake/build/bin/writ-cert 2>&1 | grep -q 'not a dynamic' \
      || { echo "writ-cert linked dynamically" >&2; exit 1; }; } \
 && cp .lake/build/bin/writ-cert /writ-cert

# --- the checker, alone -------------------------------------------------------

FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS dist
COPY --from=static /writ-cert /usr/local/bin/writ-cert
ENTRYPOINT ["/usr/local/bin/writ-cert"]
CMD ["--help"]
