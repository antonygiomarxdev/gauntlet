# Contributing

Thanks for helping. gauntlet is a small tool with strong opinions; this page saves us both time.

## Discussions first, then issues

Nobody opens an issue directly. Everything starts as a [discussion](https://github.com/antonygiomarxdev/gauntlet/discussions); when it is confirmed and actionable, a maintainer turns it into an issue. Issues are the work queue, not the inbox.

- **Bugs:** the *Bug reports* category.
- **False positives:** the *False positives* category. This is the most important kind of bug: a gate that cries wolf gets disabled.
- **New detector engines, adapters for other agent harnesses, recipes for a stack, changes to the specification** ([docs/](docs/README.md)): the *Ideas* category, before writing code. The anti-goals in the [vision](docs/VISION.md#anti-goals) are firm.
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

## Prerequisites

- `git`. The suite builds real repositories and runs the runner against them.
- `rg` (ripgrep). The rules use it, and the suite's rule tests call it.
- `ast-grep`. CI installs 0.51.0. Most of the suite runs a stub; the two tests that run the real tool skip when it is missing.
- `shellcheck`. `shellcheck -x bin/gauntlet lib/*.sh test/*.sh` must print nothing.
- `bash` 3.2 or later. macOS ships 3.2, and the runner and the suite must run on it.
- A POSIX `awk`. BWK awk (macOS), mawk and gawk all work.
- `busybox`, `zsh` and util-linux `script`, optional. The tests of the hook lines run them under every shell found, and give a hook a terminal, and skip what is missing.
- `changie`, optional: only for the changelog fragments below.

## Running the tests

```sh
test/run.sh              # the whole suite: over a thousand tests; a run takes about a quarter of an hour
test/run.sh check        # one group: test/check.test.sh, the quick way to work
```

The groups are the files `test/*.test.sh`: `base`, `cases`, `check`, `core`, `detect`, `e2e`, `escape`, `exceptions`, `harness`, `hooks`, `measure`, `paths`, `rules`, `staged` and `status`.

On macOS, Homebrew's bash often comes first on `PATH`. The runner and the tests start with `env bash`, so put the system bash (3.2) first:

```sh
shim=$(mktemp -d)
ln -s /bin/bash "$shim/bash"
PATH="$shim:$PATH" test/run.sh
rm -rf "$shim"
```

macOS's `date` has no `%N`, so the runner's clock falls back to whole seconds there. To run the suite with that clock on any machine, set `GAUNTLET_TEST_BSD_DATE=1`; the suite then puts `test/bsd-date` first on `PATH`, a `date` that behaves like macOS's:

```sh
GAUNTLET_TEST_BSD_DATE=1 test/run.sh
```

CI runs the suite on Ubuntu with the GNU clock and with the BSD double, and on macOS with bash 3.2, whose clock is BSD's.

## Releases

The maintainer tags semver versions (`vX.Y.Z`) and publishes a GitHub Release with checksums. The changelog is generated from the fragments:

```sh
changie batch auto   # folds .changes/unreleased/ into .changes/vX.Y.Z.md
changie merge        # regenerates CHANGELOG.md
```
