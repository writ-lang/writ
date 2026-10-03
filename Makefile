# writ — Partial Olog: an abstract language for modelling real-world domains,
#       with an interrogator over the finite state space a model generates.
#
#   make build     # compile the engine
#   make test      # run the test suite
#   make lint      # format check + warnings-as-errors typecheck
#   make run FILE=tests/models/any_model.writ
#   make image     # the runtime image, tagged writ:latest
#   make downstream  # this checkout against every repository that uses it
#
#   make install-writ   # this checkout -> ~/.local (plain cp; no opam needed)
#   make opam-install  # the opam package: `opam install .` (needs a switch)
#   make release       # a portable tarball: binary + stdlib + install.sh
#
# The version is the one line in dune-project. Before tagging a release:
#   make check-versions          # the files that keep their own copy agree
#   sh scripts/check-release-tag.sh v0.2.0    # the tag agrees with dune-project
#
# The toolchain is resolved by scripts/with-ocaml.sh: dune on PATH, else $SWITCH,
# else a local ./_opam. Set SWITCH=/path/to/switch to force one.

DUNE = scripts/with-ocaml.sh dune

.PHONY: build dev test lint fmt run image downstream check-versions \
        writ-cert-bin install-writ uninstall-writ opam-install opam-uninstall release \
        clean
build:
	$(DUNE) build

# Build, test and install in one step, so the `writ` on PATH is the one just
# tested. A symlinked dev install does not work: the stdlib is found relative to
# the resolved binary, which lands inside _build. Separate $(MAKE) lines because
# prerequisite order is not guaranteed under -j.
dev:
	$(MAKE) build
	$(MAKE) test
	$(MAKE) install-writ

test:
	$(DUNE) runtest --force

# The dev profile already makes warnings errors (warning 8, partial match, is how
# the engine finds gaps); @fmt adds the formatting check.
lint:
	$(DUNE) build @fmt

fmt:
	$(DUNE) build @fmt --auto-promote

# writ.opam, the Claude plugin's manifest and its image tag keep hand-written
# copies of the version; this checks they agree with dune-project, as CI does.
check-versions:
	sh scripts/check-versions.sh

run:
	$(DUNE) exec tooling/cli/writ.exe -- $(FILE)

# Install under PREFIX in the resolver's layout (bin/../share/writ/lib).
PREFIX ?= $(HOME)/.local
# writ-cert, the Lean certificate checker, is built in lean/Dockerfile (stage
# `static`) and copied out. It is the only thing here that needs docker.
CERT     ?= 1
CERT_BIN  = _build/writ-cert/writ-cert

writ-cert-bin:
	mkdir -p _build/writ-cert
	docker build --target static -t writ-cert-static lean
	id=$$(docker create writ-cert-static) \
	  && docker cp "$$id:/writ-cert" "$(CERT_BIN)"; \
	  st=$$?; docker rm "$$id" > /dev/null; exit $$st

install-writ: build
# Replace the library directory, not merge into it, so a file removed from the
# stdlib does not linger on the search path.
	rm -rf "$(PREFIX)/share/writ/lib"
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/share/writ/lib"
# The editor client and MCP clients find writ-lsp and writ-mcp on PATH by name.
	for exe in writ writ-lsp writ-mcp; do \
	  rm -f "$(PREFIX)/bin/$$exe"; \
	  cp -fL "_build/install/default/bin/$$exe" "$(PREFIX)/bin/$$exe"; \
	  chmod u+w "$(PREFIX)/bin/$$exe"; \
	done
	cp -f core/stdlib/* "$(PREFIX)/share/writ/lib/"
# writ-cert only if already built, so this target never needs docker.
	@if [ -x "$(CERT_BIN)" ]; then \
	  rm -f "$(PREFIX)/bin/writ-cert"; cp -f "$(CERT_BIN)" "$(PREFIX)/bin/writ-cert"; \
	else echo "note: no writ-cert installed — run \`make writ-cert-bin\` first to certify every check"; fi
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; \
	  *) printf 'note: add %s to your PATH to run `writ`\n' "$(PREFIX)/bin" ;; esac

uninstall-writ:
	rm -f "$(PREFIX)/bin/writ" "$(PREFIX)/bin/writ-lsp" "$(PREFIX)/bin/writ-mcp" "$(PREFIX)/bin/writ-cert"
	rm -rf "$(PREFIX)/share/writ"

# ── Packaging ────────────────────────────────────────────────────────────────
# Installs into the current opam switch. opam builds from git HEAD, so commit
# first (or pass --working-dir) or you install a stale tree.
opam-install:
	scripts/with-ocaml.sh opam install . --yes

opam-uninstall:
	scripts/with-ocaml.sh opam remove writ --yes

# A tarball with the binaries, the stdlib and install.sh, installable with no
# OCaml and no network.
#
#   make release                 # -> dist/writ-<version>-<os>-<arch>.tar.gz
#   make release VERSION=1.2.3   # override the label for a one-off build
#   make release STATIC=0        # dynamically linked (required on macOS)
#   make release CERT=0          # without writ-cert (built in docker)
#
# STATIC=1 uses the `static` profile from dune-project, so the binary runs on
# any Linux of the same architecture; the recipe prints what it links against.
VERSION  ?= $(shell sed -n 's/^(version \(.*\))/\1/p' dune-project)
STATIC   ?= 1
RELPROF   = $(if $(filter 0,$(STATIC)),release,static)
RELOS     = $(shell uname -s | tr 'A-Z' 'a-z')
RELARCH   = $(shell uname -m)
RELNAME   = writ-$(VERSION)-$(RELOS)-$(RELARCH)
DIST      = dist

release: $(if $(filter 1,$(CERT)),writ-cert-bin)
	$(DUNE) build --profile $(RELPROF) @install
	rm -rf "$(DIST)/$(RELNAME)"
	mkdir -p "$(DIST)/$(RELNAME)/bin" "$(DIST)/$(RELNAME)/share/writ/lib"
	cp -L _build/install/default/bin/writ "$(DIST)/$(RELNAME)/bin/writ"
	cp -L _build/install/default/bin/writ-lsp "$(DIST)/$(RELNAME)/bin/writ-lsp"
	cp -L _build/install/default/bin/writ-mcp "$(DIST)/$(RELNAME)/bin/writ-mcp"
	$(if $(filter 1,$(CERT)),cp "$(CERT_BIN)" "$(DIST)/$(RELNAME)/bin/writ-cert")
	chmod 755 "$(DIST)/$(RELNAME)/bin/"*
	cp core/stdlib/* "$(DIST)/$(RELNAME)/share/writ/lib/"
	cp scripts/release-install.sh "$(DIST)/$(RELNAME)/install.sh"
	chmod 755 "$(DIST)/$(RELNAME)/install.sh"
	cp README.md LICENSE CHANGELOG.md "$(DIST)/$(RELNAME)/"
	tar czf "$(DIST)/$(RELNAME).tar.gz" -C "$(DIST)" "$(RELNAME)"
	rm -rf "$(DIST)/$(RELNAME)"
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

# The runtime image; github.com/writ-lang/writ-problems builds FROM writ:latest.
image:
	docker build -t writ:$(VERSION) -t writ:latest .
	@echo
	@echo "built writ:$(VERSION) (also tagged writ:latest)"
	@echo "  try it:  docker run --rm writ:latest --version"

# Builds and tests this working tree (uncommitted changes included), then runs
# every downstream repository's suite against it. Pin one with e.g.
# VSCODE_REF=my-branch; see downstream/Dockerfile.
downstream:
	sh downstream/build.sh

clean:
	$(DUNE) clean
