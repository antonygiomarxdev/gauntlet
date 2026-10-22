# ADR-0010: A rule lives in exactly one place

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0004](0004-declarative-detectors-only.md), [ADR-0009](0009-shadow-first-manual-promotion.md)

## Context

"Two ways do the same thing" is an anti-goal. A rule enforced by both the linter and gauntlet gives two verdicts, two places to configure it, and two places to loosen it. The origin project settled the criterion by hand: a linter rule with zero violations stayed at `error` in the linter with no ratchet, while linter rules that carried debt were ratcheted.

## Decision

1. **A linter rule with zero violations** stays in the linter at `error`. gauntlet does not duplicate it.
2. **A linter rule with debt** becomes a gauntlet rule whose detector runs that linter rule.
3. **A ratcheted linter rule that reaches zero** graduates back to the linter at `error`, and gauntlet keeps a **guard**: a `block` rule at zero. The guard fails if either of these happens:
   - the linter's effective config no longer has the rule at `error` (`eslint --print-config`, `ruff check --show-settings`, …);
   - new inline suppressions of that rule appear.
4. `add-rule` checks a new rule for conflict or overlap with existing rules and with linter-owned rules.

## Consequences

- One verdict per rule, and one place to change it.
- Graduation keeps the linter fast for clean rules. The guard stops the linter config from becoming a back door for loosening.
- Guards need a config fixture as their test case, rather than a bad/good source file.

## Alternatives considered

- **Keep every rule in gauntlet:** it duplicates the linter, and gives slower feedback in editors.
- **Keep every rule in the linter with bulk suppressions:** no fingerprints, no touched gate, and the suppressions file is easy to regenerate wholesale.
- **Graduate without a guard:** the linter config could quietly downgrade the rule, or suppressions could reappear.
