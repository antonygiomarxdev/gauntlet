# ADR-0011: Changelog entries are changie fragments

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0001](0001-runner-is-bash-awk-git.md), [ADR-0004](0004-declarative-detectors-only.md), [CONTRIBUTING](../../CONTRIBUTING.md)

## Context

A hand-edited changelog drifts and conflicts between PRs. The owner wants a human-written note per change, as in the per-PR changeset flow already used elsewhere. The README also promises that gauntlet is bash, awk and git ([ADR-0001](0001-runner-is-bash-awk-git.md)), so the repo should not look as if it needs another runtime.

## Decision

1. A PR that changes what users see adds a [changie](https://github.com/miniscruff/changie) fragment (`changie new`) in `.changes/unreleased/`.
2. `CHANGELOG.md` is generated (`changie batch`, then `changie merge`) and never edited by hand.
3. The format is Keep a Changelog. Version headings drop the `v` prefix, while tags keep it.
4. changie is a maintainer tool. The runner never needs it.

## Consequences

- There is a curated, human-written note per change, with no `package.json` or other runtime in the repo.
- Maintainers install a single Go binary.
- **Known limitation:** fragment files are named by kind and timestamp, so two `changie new` runs in the same second overwrite each other. Scripted runs must be a second apart.
- Requiring a fragment is not enforced yet. It is a candidate for a declared check once the runner exists.

## Alternatives considered

- **changesets:** it needs a `package.json` and Node, which contradicts ADR-0001's promise to readers.
- **towncrier:** the same fragment model, but it needs Python.
- **release-please or git-cliff:** they derive the changelog from commit subjects, so there is no curated note.
- **A bash script of our own:** it is exactly the ad-hoc-script problem gauntlet exists to stop ([ADR-0004](0004-declarative-detectors-only.md)).
