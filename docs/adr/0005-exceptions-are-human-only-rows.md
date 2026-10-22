# ADR-0005: Exceptions are human-only rows in a file, never commit trailers

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0003](0003-baseline-is-derived.md), [ADR-0004](0004-declarative-detectors-only.md), [ADR-0008](0008-base-is-the-branch-target.md), [case study](../guide/case-study.md)

## Context

Some debt cannot be paid in the branch at hand, so a gate needs an escape. In the origin project, the escape was a commit trailer naming a path and a reason. Agents could write it themselves, so they did: 38 commits carried one (136 waiver lines), up to 17 % of a week's commits. Trailers also clutter history, and the owner forbids trailers in commits.

## Decision

1. Exceptions are rows in `.gauntlet/exceptions.tsv`, with the columns `type`, `target`, `reason`, `date` and `branch`.
2. Types:
   - `waive`: a path, exempt from the new-violation and touched checks. The rule's total still applies. A waiver applies only on the branch it names.
   - `loosen`: a rule, plus what changed. It permits a lowered severity, narrowed `paths`, a widened `exclude`, or a changed detector.
   - `remove`: a rule's removal.
   - `script`: approval for a custom script detector.
3. A `loosen` or `remove` row counts only if it is **new since the merge-base**. An old row never permits a new loosening.
4. Only a human creates a row, with `gauntlet waive`, `loosen` or `remove`. An agent may propose the exact command and its reason. It never writes the file. When an agent is blocked and the owner is away, it stops, leaves the command ready, and notifies the owner.
5. CI comments every new exception on the PR.

## Consequences

- Exceptions are reviewable, diffable and protectable in one place.
- The runner cannot tell a human from an agent. Enforcement relies on harness adapters denying agent edits and agent runs of these commands, on CI comments, and on review.
- Waiver rows from merged branches stay in the file until they are cleaned up. They apply nowhere, and `doctor` lists them.

## Alternatives considered

- **Commit trailers:** agents write them freely, the owner forbids them, and they cannot be protected.
- **Inline suppression comments:** they scatter exceptions across the code, and agents add them as easily as trailers.
- **No escape at all:** a gate with no legitimate escape gets bypassed with `--no-verify`.
