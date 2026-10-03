# writ-cert — the Lean checker for writ's certificates, built in a box.
#
# Everything is pinned. The Lean version is written in three places that must
# agree: this file, lean-toolchain, and docker-compose.yml.

# writ itself, from `make image` in the repository above (also Debian 12).
ARG WRIT_IMAGE=writ:latest
FROM ${WRIT_IMAGE} AS writ

FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS toolchain

ARG ELAN_VERSION=v4.2.4
ARG LEAN_VERSION=v4.33.1

# Lean needs a C compiler to link; lake wants git even with no dependencies.
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
# For `make test`, `make corpus` and `writ_model … from`; `make build` never
# pulls the writ image.

FROM toolchain AS with-writ
COPY --from=writ /usr/local/bin/writ /usr/local/bin/writ
COPY --from=writ /usr/local/share/writ/lib /usr/local/share/writ/lib

# --- the checker and its proofs ----------------------------------------------
#
# Building is the proof check.

FROM toolchain AS build
COPY lean-toolchain lakefile.toml ./
COPY WritCert.lean Main.lean Examples.lean ./
COPY WritCert ./WritCert
COPY Examples ./Examples
RUN lake build

# --- the checker, static ------------------------------------------------------
#
# What writ's release tarball ships (see scripts/static-cc.sh). Built from
# `build`, so it exists only if every proof checked; a dynamic link fails here.

FROM build AS static
COPY scripts/static-cc.sh ./scripts/
# lake does not treat LEAN_CC as a link input, so remove the dynamic binary
# from the build stage or it counts as up to date.
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
