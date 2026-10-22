# ADR-0003: The baseline is derived; only the runner writes it

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0002](0002-fingerprints-not-line-numbers.md), [ADR-0005](0005-exceptions-are-human-only-rows.md), [ADR-0007](0007-commit-time-check-in-pre-commit.md), [case study](../guide/case-study.md)

## Context

In the origin project, every rise of every baseline was inspected: the count went up 13 times.
- One rise was a tool bug: the diff gate overwrote the repo-wide lock with the diff's own count, and main sat 7 above the lock without anyone noticing.
- Three rises were new debt with no reason given.
- Lowered baselines depended on an agent remembering to commit them. A gate step existed only to catch the times nobody did.

A baseline that a person or an agent can edit is a number anyone can move.

## Decision

1. `.gauntlet/baseline.tsv` holds the fingerprints present in the repo, with their counts. It is **derived**: only the runner writes it.
2. Push and CI re-measure the code, and fail unless the committed baseline equals the measurement exactly. A baseline that is higher is loose; one that is lower means the code is above the baseline.
3. **Auto-tighten:** when a commit lowers the debt, the commit-time check rewrites the baseline and stages it into that same commit.
4. Whether a change is allowed is judged against the baseline **at the merge-base**, never against the branch's own baseline. Regenerating the baseline cannot absorb new debt.
5. A rule added in a branch brings its own entries. Its debt is never mixed into an existing rule's total.

## Consequences

- A hand edit, by an agent or a human, fails CI. So does a tool bug that writes a wrong number.
- A fix and its lower number always travel together.
- Rules that run only at push (whole-program detectors) are not re-measured at commit. When their counts change, push asks for `gauntlet baseline` and a commit.
- New debt can enter only through a human exception ([ADR-0005](0005-exceptions-are-human-only-rows.md)).

## Alternatives considered

- **A hand-maintained lock file,** as the origin project had: it rose 13 times, including through a tool bug.
- **Global totals only:** one number per rule hides which debt is new, and lets new debt hide behind old debt that was paid.
- **Asking the developer to commit lowered numbers:** that relies on memory, and it failed in practice.
