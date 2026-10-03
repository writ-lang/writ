#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# LEAN_CC for a fully static writ-cert, as writ's release tarball requires.
# Lean's sysroot has no libc.a, so this links with the system gcc and glibc
# plus the toolchain's lib directory, and drops lake's `-rdynamic` and
# `-Wl,-Bdynamic`, which a static link cannot honour. (glibc's static
# getaddrinfo/dlopen warning does not apply: writ-cert uses neither.)
set -eu
args=
for a in "$@"; do
  case $a in
    @*) f=${a#@}; sed -i 's/"-rdynamic"//; s/"-Wl,-Bdynamic"//' "$f" ;;
  esac
done
exec gcc -static -L"$(lean --print-prefix)/lib" "$@"
