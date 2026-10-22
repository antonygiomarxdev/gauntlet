# ADR-0008: New and touched are measured against the branch's target

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0002](0002-fingerprints-not-line-numbers.md), [ADR-0003](0003-baseline-is-derived.md), [ADR-0005](0005-exceptions-are-human-only-rows.md)

## Context

"New" and "touched" only mean something relative to a base. Measuring against the default branch charges a stacked PR with everything below it in the stack. Measuring differently in CI and locally breaks parity: in the origin project, the diff gate passed locally and failed in CI because CI's checkout was shallow. The non-negotiable is that nothing is pushed without knowing it passes CI.

## Decision

1. The base is the branch's **target**:
   - In CI, it is the PR's target branch.
   - Locally, it is `git config branch.<name>.gauntletBase`, which `gauntlet base <ref>` or a stack tool sets. Without it, gauntlet falls back to `origin/<default>`.
2. The runner fetches the base and compares against the **merge-base**, never the base's tip.
3. CI checks out the full history. Reproduce the condition, not just the command.
4. Pre-push runs exactly what CI runs, from the same vendored runner, against the same base.
5. `check --ci` refuses a working tree whose tracked files differ from `HEAD`, because it must check what is pushed.

## Consequences

- Stacked PRs are judged only on their own changes.
- Local and CI verdicts match.
- A stack tool that does not set `gauntletBase` falls back to the default branch. `gauntlet base` fixes that by hand.
- Pushing with uncommitted changes requires committing or stashing them first.
- When the fetch fails offline, the runner warns and uses the local ref.

## Alternatives considered

- **Always the default branch:** it charges stacked PRs with the whole stack.
- **The previous commit only:** it misses debt added earlier in the same branch.
- **A shallow CI checkout:** this is exactly what made local and CI diverge in the origin project.
