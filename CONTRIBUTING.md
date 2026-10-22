# Contributing

Thanks for helping. gauntlet is a small tool with strong opinions; this page saves us both time.

## Discussions first, then issues

Nobody opens an issue directly. Everything starts as a [discussion](https://github.com/antonygiomarxdev/gauntlet/discussions); when it is confirmed and actionable, a maintainer turns it into an issue. Issues are the work queue, not the inbox.

- **Bugs:** the *Bug reports* category.
- **False positives:** the *False positives* category. This is the most important kind of bug: a gate that cries wolf gets disabled.
- **New detector engines, adapters for other agent harnesses, recipes for a stack, changes to the design** ([docs/design.md](docs/design.md)): the *Ideas* category, before writing code. The anti-goals in §4 are firm.
- **Questions:** the *Q&A* category.
- **Vulnerabilities:** never in public; see [SECURITY.md](SECURITY.md).

A PR should reference the issue it implements.

## Ground rules

- **The runner stays bash + awk + git.** No jq, no Node, no Python, no compile step. If something seems to need one, raise it in a discussion.
- **Tests first.** Every behaviour change starts with a failing fixture test under `test/`. The test is a small git repo the suite builds, plus the expected verdict.
- **Fail closed.** Code paths that cannot decide must fail the gate loudly, never skip.
- **Fingerprints, never line numbers.** Nothing may key a violation on its line number.
- **Docs travel with the change.** A PR that changes behaviour updates `docs/` in the same PR.
- **One way to do a thing.** When a new path replaces an old one, the old one is deleted in the same PR.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`. Don't add attribution trailers.

## Changelog entries

A PR that changes what users see adds a [changie](https://github.com/miniscruff/changie) fragment:

```sh
changie new   # pick a kind (Added, Changed, Fixed, ...) and write one line
```

The fragment lands in `.changes/unreleased/`; commit it with the PR. Never edit `CHANGELOG.md` by hand. changie is a maintainer tool; the runner never needs it. Install it with `go install github.com/miniscruff/changie@latest` or a binary from its releases.

Fragment files are named by kind and timestamp, so two `changie new` runs in the same second overwrite each other. Run them a second apart when scripting.

## Running the tests

```sh
test/run.sh            # all fixture tests
test/run.sh fingerprint  # one group
```

## Releases

The maintainer tags semver versions (`vX.Y.Z`) and publishes a GitHub Release with checksums. The changelog is generated from the fragments:

```sh
changie batch auto   # folds .changes/unreleased/ into .changes/vX.Y.Z.md
changie merge        # regenerates CHANGELOG.md
```
