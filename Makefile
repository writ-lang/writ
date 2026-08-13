# writ — Partial Olog: an abstract language for modelling real-world domains,
#       with an interrogator over the finite state space a model generates.
#
#   make build     # compile the engine
#   make test      # run the test suite
#   make lint      # format check + warnings-as-errors typecheck
#   make run FILE=tests/models/any_model.writ
#   make image     # the runtime image, tagged writ:latest
#
# The worked scenarios and the editor client are their own repositories now —
# github.com/writ-lang/writ-problems and .../writ-vscode — so there is no target
# here that runs them; each needs an installed writ, or the image above.
#
# Three ways to get a `writ` you can run anywhere:
#   make install-writ   # this checkout -> ~/.local (plain cp; no opam needed)
#   make opam-install  # the opam package: `opam install .` (needs a switch)
#   make release       # a portable tarball: binary + stdlib + install.sh
#
# The toolchain is resolved by scripts/with-ocaml.sh: dune on PATH, else $SWITCH,
# else a local ./_opam. Set SWITCH=/path/to/switch to force one.

DUNE = scripts/with-ocaml.sh dune

.PHONY: build dev test lint fmt run image \
        install-writ uninstall-writ opam-install opam-uninstall release \
        clean
build:
	$(DUNE) build

# The edit loop, in one command. `build` deliberately does NOT touch $(PREFIX)
# — a build should not install — and that is exactly how the `writ` on PATH
# comes to be a different program from the one just tested: you rebuild, the
# suites pass, and then you type at yesterday's binary and read its answer as
# today's. That failure is silent, which is what makes it expensive; this
# target exists to be the one worth typing.
#
# A symlinked dev install would need no remembering at all. It does not work
# here, and the reason is worth recording so nobody re-tries it: dune's
# _build/install/default/bin/writ is ITSELF a symlink into
# _build/default/tooling/cli/writ.exe, OCaml's Sys.executable_name resolves
# through it, and the `(load …)` search order looks for the stdlib relative to
# the binary (design D3, candidate 3) — so `../share/writ/lib` lands inside
# _build, in a directory dune owns and will clobber. Checked, not assumed.
#
# Separate $(MAKE) lines rather than prerequisites: prerequisite order is not
# guaranteed under -j, and installing a binary whose suites have not run yet is
# the thing being avoided.
dev:
	$(MAKE) build
	$(MAKE) test
	$(MAKE) install-writ

test:
	$(DUNE) runtest --force

# Dune already compiles with warnings-as-errors in the dev profile; @fmt adds
# formatting. Warning 8 (partial-match) failing the build is the point — it is
# the same mechanism the engine uses to find gaps in a model.
lint:
	$(DUNE) build @fmt

fmt:
	$(DUNE) build @fmt --auto-promote

run:
	$(DUNE) exec tooling/cli/writ.exe -- $(FILE)

# Install the standalone binary and the .writ libraries under ~/.local, matching
# the resolver's installed layout (bin/../share/writ/lib). No sudo, no npm, no
# opam — a plain POSIX cp/mkdir. PREFIX overrides the default ~/.local.
PREFIX ?= $(HOME)/.local
install-writ: build
# The library directory is REPLACED, not merged into: a file dropped from the
# standard library must disappear on upgrade, or an old copy lingers on the
# search path and keeps resolving after it has been removed from the project.
	rm -rf "$(PREFIX)/share/writ/lib"
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/share/writ/lib"
# All THREE binaries, not just the CLI. The editor client looks for `writ-lsp`
# on PATH when it is not inside a checkout, and an MCP client is pointed at
# `writ-mcp` by name — so installing only `writ` leaves both of them with nothing
# to talk to, which is a confusing way to fail.
	for exe in writ writ-lsp writ-mcp; do \
	  rm -f "$(PREFIX)/bin/$$exe"; \
	  cp -fL "_build/install/default/bin/$$exe" "$(PREFIX)/bin/$$exe"; \
	  chmod u+w "$(PREFIX)/bin/$$exe"; \
	done
	cp -f core/stdlib/* "$(PREFIX)/share/writ/lib/"
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; \
	  *) printf 'note: add %s to your PATH to run `writ`\n' "$(PREFIX)/bin" ;; esac

uninstall-writ:
	rm -f "$(PREFIX)/bin/writ" "$(PREFIX)/bin/writ-lsp" "$(PREFIX)/bin/writ-mcp"
	rm -rf "$(PREFIX)/share/writ"

# ── Packaging ────────────────────────────────────────────────────────────────
# `writ` is an opam package (see the (package) stanza in dune-project, from which
# writ.opam is generated). This installs it into the CURRENT opam switch, which
# puts `writ` and `writ-lsp` on the switch's PATH and the .writ stdlib in the
# switch's share/writ/lib — the same layout the resolver expects.
#
# Note opam builds from the sources it copies out of the checkout's git HEAD, so
# COMMIT your changes first (or pass --working-dir) or you will install a stale
# tree. `opam pin add writ .` then tracks this directory.
opam-install:
	scripts/with-ocaml.sh opam install . --yes

opam-uninstall:
	scripts/with-ocaml.sh opam remove writ --yes

# A portable release: one tarball holding the binary, the language server, the
# .writ stdlib and an install.sh — enough to install `writ` on a machine with no
# OCaml, no opam and no network.
#
#   make release                 # -> dist/writ-<version>-<os>-<arch>.tar.gz
#   make release VERSION=1.2.3   # override the label for a one-off build
#   make release STATIC=0        # dynamically linked (see below)
#
# VERSION comes from dune-project — the same number opam publishes and
# `writ --version` prints, so a tarball can always be traced to a release. It is
# read with sed rather than duplicated here, for the usual reason: two copies of
# a version number are one copy and one lie.
#
# STATIC=1 (the default) builds with the `static` profile from dune-project, so
# the binary carries no libc version floor and runs on any Linux of the same
# architecture. STATIC=0 links dynamically, which is fine for a machine like the
# one that built it and REQUIRED on platforms with no static libc (macOS). The
# recipe prints what the binary actually needs, so the portability claim is
# checked rather than assumed.
VERSION  ?= $(shell sed -n 's/^(version \(.*\))/\1/p' dune-project)
STATIC   ?= 1
RELPROF   = $(if $(filter 0,$(STATIC)),release,static)
RELOS     = $(shell uname -s | tr 'A-Z' 'a-z')
RELARCH   = $(shell uname -m)
RELNAME   = writ-$(VERSION)-$(RELOS)-$(RELARCH)
DIST      = dist

release:
	$(DUNE) build --profile $(RELPROF) @install
	rm -rf "$(DIST)/$(RELNAME)"
	mkdir -p "$(DIST)/$(RELNAME)/bin" "$(DIST)/$(RELNAME)/share/writ/lib"
	cp -L _build/install/default/bin/writ "$(DIST)/$(RELNAME)/bin/writ"
	cp -L _build/install/default/bin/writ-lsp "$(DIST)/$(RELNAME)/bin/writ-lsp"
	cp -L _build/install/default/bin/writ-mcp "$(DIST)/$(RELNAME)/bin/writ-mcp"
	chmod 755 "$(DIST)/$(RELNAME)/bin/"*
	cp core/stdlib/* "$(DIST)/$(RELNAME)/share/writ/lib/"
	cp scripts/release-install.sh "$(DIST)/$(RELNAME)/install.sh"
	chmod 755 "$(DIST)/$(RELNAME)/install.sh"
	cp README.md LICENSE CHANGELOG.md "$(DIST)/$(RELNAME)/"
	tar czf "$(DIST)/$(RELNAME).tar.gz" -C "$(DIST)" "$(RELNAME)"
	rm -rf "$(DIST)/$(RELNAME)"
# A checksum beside the tarball, so whoever downloads it can tell they got the
# bytes that were built. Without one, "verify before you install" is advice
# nobody can act on.
	cd "$(DIST)" && sha256sum "$(RELNAME).tar.gz" > "$(RELNAME).tar.gz.sha256"
	@echo
	@echo "built $(DIST)/$(RELNAME).tar.gz"
	@echo "  sha256: $$(cut -d' ' -f1 "$(DIST)/$(RELNAME).tar.gz.sha256")"
	@echo "  verify with:  sha256sum -c $(RELNAME).tar.gz.sha256"
	@echo "  install it anywhere with:  tar xzf $(RELNAME).tar.gz && $(RELNAME)/install.sh"
	@echo "  the binary needs:"
	@if ldd _build/install/default/bin/writ 2>&1 | grep -q 'not a dynamic'; \
	 then echo "    nothing — statically linked; any $(RELARCH) $(RELOS) will run it"; \
	 else ldd _build/install/default/bin/writ | sed 's/^/    /'; \
	      echo "    (dynamic: the target needs a glibc at least as new as this host's)"; \
	 fi

# The worked scenarios and the VS Code client used to live here, behind
# `make examples` and `make extension`. Both are repositories of their own now:
#
#   github.com/writ-lang/writ-problems   the models, their questions, the runner
#   github.com/writ-lang/writ-vscode     the editor client
#
# Each needs an installed writ rather than this checkout — `make install-writ`, or
# `opam install .`, puts writ, writ-lsp and writ-mcp on PATH — so neither can be a
# target here without this repository reaching into another one.

# The runtime image: `writ` and the stdlib on a slim Debian. writ-problems builds
# FROM it, which is how those scenarios run with nothing installed on the host
# but Docker. Tagged twice — the version for reproducibility, `latest` because
# that is what a downstream Dockerfile defaults to.
image:
	docker build -t writ:$(VERSION) -t writ:latest .
	@echo
	@echo "built writ:$(VERSION) (also tagged writ:latest)"
	@echo "  try it:  docker run --rm writ:latest --version"

clean:
	$(DUNE) clean
