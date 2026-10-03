# Shortcuts over docker compose. Lean is never run on the host.
#
#   make build            lake build: the checker, every proof, the examples
#   make check F=FILE     writ-cert on a certificate
#   make test             the fixtures certify, and every tampered certificate is refused
#   make corpus           every model in ../tests and the sibling repositories
#   make tampered         regenerate test/tampered/ from test/runs (needs python3)
#   make image            writ-cert alone, in an image that exists only if every proof checked
#   make clean
#
# `test` and `corpus` run writ, from the image `make image` builds in the
# directory above (WRIT_IMAGE=… to use another).

.SILENT:
COMPOSE := docker compose run --rm

.PHONY: build check test corpus tampered image clean help

help:
	sed -n '2,13p' $(MAKEFILE_LIST) | sed 's/^# \{0,1\}//'

build:
	$(COMPOSE) build

check:
	test -n "$(F)" || { echo "usage: make check F=FILE.json"; exit 2; }
	$(COMPOSE) cert $(F)

test:
	$(COMPOSE) test

corpus: build
	$(COMPOSE) corpus

tampered:
	python3 test/tamper.py Examples/runs.cert.json test/tampered

image:
	docker build --target dist -t writ-cert:latest .
	docker run --rm writ-cert:latest --help

clean:
	rm -rf .lake
