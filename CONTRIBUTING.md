# Contributing to writ

Bug reports, questions and patches are welcome. For anything larger than a
fix, open an issue first so we can agree on the shape before the code exists.

## Before your first pull request: sign the CLA

Contributions are accepted under the Contributor License Agreement in
[CLA.md](CLA.md). Open a pull request and a bot comments with a link; signing
is one click and covers everything you contribute from then on.

You keep the copyright in what you write. You grant the project's owner a
licence to ship your patch under the current licence and to change that licence
later, so that a licence change does not need every past contributor's
agreement. It is not a copyright assignment, gives nobody rights to your other
work, and does not stop you using your contribution anywhere else. If your
employer owns what you write at work, you need their sign-off (section 4).

## Sending a patch

- Work on a branch; one concern per pull request.
- Run the tests before you open it (`make test` and `make lint`).
- New source files need the two-line header every other file carries — a
  copyright line and an `SPDX-License-Identifier`. Copy them from a neighbour.
- Write the commit message for someone reading it in a year: what changed, and
  why.

## Releasing

The version lives in one place, `(version …)` in `dune-project`; the tag only
starts the release workflows. Bump first, then tag:

```sh
$EDITOR dune-project                       # (version 0.4.0)
make build                                 # regenerates writ.opam
sh scripts/check-versions.sh               # the plugin's copies must agree
git commit -am "writ 0.4.0"
sh scripts/check-release-tag.sh v0.4.0
git tag -a v0.4.0 -m "what this release is for, in one line"
git push origin main v0.4.0
```

The tag builds and tests the tarballs (x86_64, aarch64) and publishes them as a
GitHub release, and pushes the image to `ghcr.io/writ-lang/writ`.
