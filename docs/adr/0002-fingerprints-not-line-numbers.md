# ADR-0002: A violation is identified by its fingerprint, never its line number

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0003](0003-baseline-is-derived.md), [ADR-0008](0008-base-is-the-branch-target.md), [case study](../guide/case-study.md)

## Context

To tell new debt from old, the gate needs a stable identity for each violation. Diff-filter tools ("only flag added lines") forget: reformatting a file makes every old violation look new, and moving code lets new debt slip in looking old. The origin project's diff gate judged "new" by added lines, and reformatting produced false failures.

## Decision

1. A violation's identity is its **fingerprint**: rule id, path, and the normalized text of the flagged line.
2. Normalization strips `\r`, collapses runs of spaces and tabs to one space, and trims both ends.
3. Line numbers are never stored. They appear only in output, to point at the code.
4. A fingerprint may appear several times in a file. The baseline stores its count.
5. gauntlet's own test suite includes "reformatting a whole file changes no verdict".

## Consequences

- Inserting lines, moving a violation within its file, re-indenting, and switching between CRLF and LF change nothing.
- Moving a violation to **another file** counts as new, because the path is part of the identity.
- **Known ceiling:** a reformat that splits one flagged line into several produces a new fingerprint. The gate reports it as new. That fails closed, never open.
- Two different violations on identical lines in the same file are indistinguishable. The count covers them.

## Alternatives considered

- **Line numbers,** or added lines in the diff: these break on every edit above the violation, and on reformatting.
- **Hashing the surrounding context:** more robust to splits, but opaque in diffs, harder to explain, and the tools that compute it differ by platform.
- **AST node identity:** precise, but language-specific. It cannot back `rg` or generic linter rules.
