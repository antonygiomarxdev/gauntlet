# ADR-0007: The commit-time check runs in pre-commit

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0003](0003-baseline-is-derived.md), [ADR-0006](0006-coexist-with-existing-hooks.md)

## Context

Auto-tighten ([ADR-0003](0003-baseline-is-derived.md)) needs the lowered baseline to land in the same commit as the fix. The design draft put the commit-time check in `commit-msg`, on the assumption that a file staged there would be included in the commit.

A spike on git 2.43 disproved that:
- A file staged from `commit-msg` was left out of the commit and stayed staged afterwards.
- The same file staged from `pre-commit` landed in the commit, both with `git commit` and with `git commit -a`. Git re-reads the index after `pre-commit`, not after `commit-msg`.

## Decision

1. The commit-time check runs in the `pre-commit` hook. This supersedes the `commit-msg` choice in the design draft.
2. It runs only rules with `stage: commit`, on staged files, and it must finish in under 5 s. A slow commit hook is how people learn `--no-verify`.
3. Whole-program detectors (type-check, dependency graph, duplicate definitions) set `stage: push`. They run at pre-push and in CI, never at commit.
4. When a staged file also has unstaged changes, the check still runs, but auto-tighten is skipped with a notice. Push verifies the exact baseline anyway.

## Consequences

- A fix and its lowered baseline travel in one commit, with nobody having to remember.
- The commit check reads the working tree. With partial staging (`git add -p`) it can judge code that is not exactly what gets committed. The push gate catches any difference.
- The commit message is not available to the check. Nothing in the design needs it, since exceptions are not trailers ([ADR-0005](0005-exceptions-are-human-only-rows.md)).

## Alternatives considered

- **`commit-msg`:** the spike showed that staged changes there miss the commit.
- **`post-commit` with an amend:** it rewrites the commit after the fact, and it surprises users and tooling.
- **Push only:** no fast feedback, and a lowered baseline would still need a separate commit.
