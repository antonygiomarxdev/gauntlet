# ADR-0004: Detectors are declarative

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0001](0001-runner-is-bash-awk-git.md), [ADR-0005](0005-exceptions-are-human-only-rows.md), [ADR-0010](0010-a-rule-lives-in-one-place.md), [case study](../guide/case-study.md)

## Context

The origin project grew from 16 to 41 bespoke check and ratchet scripts. Each had its own baseline format and its own detector style, most of them regex over TypeScript text, and there was no guide for adding a rule. When everyone writes detectors their own way, the result is dozens of incompatible scripts nobody can audit. A rule nobody can count is not a rule.

## Decision

1. Every rule has a detector, and a detector is declarative. In order of preference:
   1. a rule of the project's own linter;
   2. an `ast-grep` YAML rule, for structural rules in any language;
   3. an `rg` pattern, for rules that really are textual.
2. A custom script detector needs a `script` exception that a human approves. It lives in `.gauntlet/detectors/`, is built from a fixed template, and carries test cases.
3. A detector yields violations as `path:line[: message]`. `ast-grep`'s GitHub output format is also parsed.
4. **Fail closed:**
   - a missing tool fails with its install command;
   - output that cannot be parsed fails;
   - an unexpected exit code fails;
   - nothing is skipped silently.
5. Every rule ships `bad` and `good` cases. When rules change, push and CI run all the cases.

## Consequences

- One rule format, readable by humans and agents, with a known way to test it.
- Some rules are hard to express declaratively. These need the script exception, which is deliberately costly.
- A detector that crashes blocks the gate until it is fixed. That is preferable to a gate that quietly passes.

## Alternatives considered

- **Free-form scripts per rule:** that is what the origin project had, and it ended with 41 incompatible scripts.
- **A plugin API in a general-purpose language:** it needs a runtime ([ADR-0001](0001-runner-is-bash-awk-git.md)), and it is still code everyone writes differently.
- **Fail open on detector errors:** a gate that passes when its detector breaks protects nothing.
