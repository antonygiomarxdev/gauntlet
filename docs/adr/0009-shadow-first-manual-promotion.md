# ADR-0009: New blocking rules start in shadow; promotion is manual

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0003](0003-baseline-is-derived.md), [ADR-0010](0010-a-rule-lives-in-one-place.md), [PRD](../product/PRD.md)

## Context

Two anti-goals pull in the same direction: false positives make people hate a gate, and known debt must never suddenly break CI. A new detector has not yet met the repo's real code, and a rule that blocks on day one with a false positive gets turned off. The owner judged automatic promotion not viable: it costs money and makes people hate the tool.

## Decision

1. Severities:
   - **`block`** is fully gated.
   - **`shadow`** reports "would have failed", with details, and never fails.
   - **`track`** is counted and shown, and never fails.
2. A new `block` rule enters as `shadow`, unless the owner explicitly skips the shadow period.
3. A shadow rule stays in shadow **until the owner promotes it** with `gauntlet promote <id>`. Promotion is never automatic.
4. After 7 days in shadow, `status` and the agent remind the owner. The reminder shows how often the rule would have failed and any false positives reported.
5. When a `track` rule's count rises, the output shows the delta, and the agent proposes promoting the rule.
6. Existing debt never fails the gate by itself. Only these fail it:
   - a new violation;
   - a touched file that did not go down, when that gate is on;
   - a loosened rule;
   - a baseline that lies.

## Consequences

- Owners see a rule's real behaviour before it can block anyone.
- A rule can sit in shadow indefinitely if the owner ignores the reminders. That is accepted: the owner decides.
- `since` in the rule file records when shadow began, and drives the reminder.

## Alternatives considered

- **Block on day one:** false positives arrive before trust does.
- **Automatic promotion after N clean days:** the owner rejected it as costly and resented.
- **Fail on existing debt above a threshold:** it fails on day one in a real codebase, then gets disabled.
