# pol — Partial Olog: an abstract language for modelling real-world domains,
#       with an interrogator over the finite state space a model generates.
#
#   make build     # compile the engine
#   make test      # run the test suite
#   make lint      # format check + warnings-as-errors typecheck
#   make run FILE=tests/models/any_model.pol
#   make examples             # run every worked example scenario
#   make example T=river      # run one scenario by name …
#   make example T=3          # … or by number (see: make examples-list)
#   make extension            # install .pol language support into VS Code
#
# Three ways to get a `pol` you can run anywhere:
#   make install-pol   # this checkout -> ~/.local (plain cp; no opam needed)
#   make opam-install  # the opam package: `opam install .` (needs a switch)
#   make release       # a portable tarball: binary + stdlib + install.sh
#
# The toolchain is resolved by scripts/with-ocaml.sh: dune on PATH, else $SWITCH,
# else a local ./_opam. Set SWITCH=/path/to/switch to force one.

DUNE = scripts/with-ocaml.sh dune

.PHONY: build test lint fmt run examples example examples-list \
        install-pol uninstall-pol opam-install opam-uninstall release \
        extension clean
build:
	$(DUNE) build

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
	$(DUNE) exec tooling/cli/pol.exe -- $(FILE)

# Install the standalone binary and the .pol libraries under ~/.local, matching
# the resolver's installed layout (bin/../share/pol/lib). No sudo, no npm, no
# opam — a plain POSIX cp/mkdir. PREFIX overrides the default ~/.local.
PREFIX ?= $(HOME)/.local
install-pol: build
# The library directory is REPLACED, not merged into: a file dropped from the
# standard library must disappear on upgrade, or an old copy lingers on the
# search path and keeps resolving after it has been removed from the project.
	rm -rf "$(PREFIX)/share/pol/lib"
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/share/pol/lib"
	rm -f "$(PREFIX)/bin/pol"
	cp -f _build/default/tooling/cli/pol.exe "$(PREFIX)/bin/pol"
	chmod u+w "$(PREFIX)/bin/pol"
	cp -f core/stdlib/*.pol "$(PREFIX)/share/pol/lib/"
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; \
	  *) printf 'note: add %s to your PATH to run `pol`\n' "$(PREFIX)/bin" ;; esac

uninstall-pol:
	rm -f "$(PREFIX)/bin/pol"
	rm -rf "$(PREFIX)/share/pol"

# ── Packaging ────────────────────────────────────────────────────────────────
# `pol` is an opam package (see the (package) stanza in dune-project, from which
# pol.opam is generated). This installs it into the CURRENT opam switch, which
# puts `pol` and `pol-lsp` on the switch's PATH and the .pol stdlib in the
# switch's share/pol/lib — the same layout the resolver expects.
#
# Note opam builds from the sources it copies out of the checkout's git HEAD, so
# COMMIT your changes first (or pass --working-dir) or you will install a stale
# tree. `opam pin add pol .` then tracks this directory.
opam-install:
	scripts/with-ocaml.sh opam install . --yes

opam-uninstall:
	scripts/with-ocaml.sh opam remove pol --yes

# A portable release: one tarball holding the binary, the language server, the
# .pol stdlib and an install.sh — enough to install `pol` on a machine with no
# OCaml, no opam and no network.
#
#   make release                 # -> dist/pol-<version>-<os>-<arch>.tar.gz
#   make release VERSION=1.2.3   # override the label for a one-off build
#   make release STATIC=0        # dynamically linked (see below)
#
# VERSION comes from dune-project — the same number opam publishes and
# `pol --version` prints, so a tarball can always be traced to a release. It is
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
RELNAME   = pol-$(VERSION)-$(RELOS)-$(RELARCH)
DIST      = dist

release:
	$(DUNE) build --profile $(RELPROF) @install
	rm -rf "$(DIST)/$(RELNAME)"
	mkdir -p "$(DIST)/$(RELNAME)/bin" "$(DIST)/$(RELNAME)/share/pol/lib"
	cp -L _build/install/default/bin/pol "$(DIST)/$(RELNAME)/bin/pol"
	cp -L _build/install/default/bin/pol-lsp "$(DIST)/$(RELNAME)/bin/pol-lsp"
	chmod 755 "$(DIST)/$(RELNAME)/bin/"*
	cp core/stdlib/*.pol "$(DIST)/$(RELNAME)/share/pol/lib/"
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
	@if ldd _build/install/default/bin/pol 2>&1 | grep -q 'not a dynamic'; \
	 then echo "    nothing — statically linked; any $(RELARCH) $(RELOS) will run it"; \
	 else ldd _build/install/default/bin/pol | sed 's/^/    /'; \
	      echo "    (dynamic: the target needs a glibc at least as new as this host's)"; \
	 fi

# Example scenario tests (tests/examples/run-tests.sh): solve the worked problems
# with `pol` and check the answers. They use the freshly built binary by ABSOLUTE
# path (so scenarios that cd into temp dirs — control, gitcompare — still find it),
# and POL_LIB points at the repo stdlib so `(load "stdlib.pol")` resolves without
# install.
POLBIN = $(CURDIR)/_build/default/tooling/cli/pol.exe
POLENV = POL=$(POLBIN) POL_LIB=$(CURDIR)/core/stdlib

examples: build
	$(POLENV) ./tests/examples/run-tests.sh all

examples-list:
	@./tests/examples/run-tests.sh list

# Run ONE scenario by name or number:  make example T=river   |   make example T=3
example: build
	@test -n "$(T)" || { echo "usage: make example T=<name|number>  (see: make examples-list)"; exit 2; }
	$(POLENV) ./tests/examples/run-tests.sh $(T)

# Builds the server, installs the VS Code client, and verifies the two talk.
extension:
	./tooling/vscode/install.sh

clean:
	$(DUNE) clean
