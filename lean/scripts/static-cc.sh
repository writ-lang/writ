#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# LEAN_CC for a fully static writ-cert (the release tarball's rule: every
# binary in it is static, so it runs on any Linux of its architecture).
#
# Lean links its own runtime, libc++, gmp, libuv and OpenSSL statically
# already, from archives in the toolchain's lib directory; only libc, libm,
# libdl and friends come dynamically. Two things stand in the way of `-static`:
#
#   - Lean's own sysroot has no libc.a, so the link uses this machine's gcc and
#     glibc (libc6-dev ships libc.a), with the toolchain's lib directory added
#     for the archives above;
#   - lake's link line says `-rdynamic` and `-Wl,-Bdynamic` after libc++, which
#     a static link cannot honour. They are dropped from the response file.
#
# glibc warns that a static binary calling getaddrinfo or dlopen needs the
# shared library at run time; writ-cert does neither.
set -eu
args=
for a in "$@"; do
  case $a in
    @*) f=${a#@}; sed -i 's/"-rdynamic"//; s/"-Wl,-Bdynamic"//' "$f" ;;
  esac
done
exec gcc -static -L"$(lean --print-prefix)/lib" "$@"
