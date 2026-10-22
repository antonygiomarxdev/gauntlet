# Architecture decision records

ADRs record durable decisions. The [PRD](../product/PRD.md), the FRDs, the [Technical Proposal](../technical/TP-01-gauntlet.md) and the Implementation Specs apply them. An ADR exists when a decision outlives one implementation slice or sets a rule other work must follow.

## Adding one

1. Copy [`../process/templates/adr.md`](../process/templates/adr.md) to `NNNN-<slug>.md`, using the next free number.
2. Fill in its context, decision, consequences and the alternatives considered.
3. Never edit the decision of an accepted ADR. Write a new ADR that supersedes it, and set the old one's status to `Superseded by ADR-NNNN`.

## Index

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-runner-is-bash-awk-git.md) | The runner is bash 3.2 + POSIX awk + git, vendored with a pinned version. | Accepted |
| [0002](0002-fingerprints-not-line-numbers.md) | A violation is rule + path + normalized line text, never a line number. | Accepted |
| [0003](0003-baseline-is-derived.md) | Only the runner writes the baseline; CI requires it to equal the code. | Accepted |
| [0004](0004-declarative-detectors-only.md) | Detectors are linter, ast-grep or rg; scripts only by human exception; fail closed. | Accepted |
| [0005](0005-exceptions-are-human-only-rows.md) | Exceptions are human-only rows in `exceptions.tsv`, never commit trailers. | Accepted |
| [0006](0006-coexist-with-existing-hooks.md) | Add one line to existing hooks; never set `core.hooksPath`. | Accepted |
| [0007](0007-commit-time-check-in-pre-commit.md) | The commit-time check runs in `pre-commit`, so auto-tighten lands in the commit. | Accepted |
| [0008](0008-base-is-the-branch-target.md) | New and touched are measured against the merge-base with the branch's target. | Accepted |
| [0009](0009-shadow-first-manual-promotion.md) | New blocking rules start in shadow; only the owner promotes them. | Accepted |
| [0010](0010-a-rule-lives-in-one-place.md) | A rule lives in the linter or in gauntlet, never both; graduation keeps a guard. | Accepted |
| [0011](0011-changelog-fragments-with-changie.md) | Changelog entries are changie fragments; `CHANGELOG.md` is generated. | Accepted |
