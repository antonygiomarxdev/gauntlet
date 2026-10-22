# Vision — gauntlet

**Owner:** Antony Giomar Hernández

This document does not change from one initiative to the next. Each [initiative](initiatives/README.md)'s PRD states how it serves the vision, and a PRD that drifts from it needs an explicit decision by the owner.

## Thesis

An agent that writes code in a repository must not be able to make that repository worse. With gauntlet:
- every rule the owner agreed to is counted;
- existing debt can only go down;
- a new violation is caught at commit, at push and in CI, whoever wrote it, in any language, any agent harness and any model.

## The problem

Rules written in prose get forgotten. Agents read `AGENTS.md`, standards pages and ADRs, agree with them, and break them three PRs later while every test stays green. In the origin project, a PR passed review, lint, type-check and 1,105 tests, and still shipped two defects that reproduced a production outage. None of the rules it broke had a detector. **A rule nobody counts is a suggestion.**

The process was first built by hand in that project ([case study](guide/case-study.md)). It worked: debt fell 22–85 % per rule in six weeks while merged PRs per week went up. It also leaked:

- **Bespoke scripts.** They grew from 16 to 41 check and ratchet scripts, each with its own format and no guide for adding one.
- **A routine escape hatch.** A waiver trailer agents could write themselves appeared in up to 17 % of a week's commits.
- **Thirteen baseline rises.** One came from a tool bug, and three added debt with no reason given.
- **Lowered baselines that had to be remembered.** When debt fell, someone had to remember to commit the new number.
- **A diff gate keyed on line numbers.** A reformat made old violations look new.

Existing tools each cover part of the engine. None has a touched-file gate, rules as files with a rationale, onboarding that researches and proposes rules, or rules learned from an agent's repeated mistakes ([comparison](guide/comparison.md)).

## Users

| User | Job |
|---|---|
| **Owner** of a repository where agents write much of the code | "Make the rules I agreed to bite, without reviewing every line and without breaking what my repo already runs." |
| **Contributor**, human or agent | "Tell me exactly what I broke, where, and how to fix it, before I push." |
| **Adopter** with an existing codebase and existing debt | "Start today without known debt failing CI, then pay it down at my own pace." |

## Principles

1. **Nothing is pushed without knowing it passes CI.** Pre-push runs what CI runs, under the same conditions.
2. **Existing debt never fails the gate by itself.**
3. **Nothing starts blocking without the owner's yes.** New blocking rules start in shadow, and promotion is manual ([ADR-0009](adr/0009-shadow-first-manual-promotion.md)).
4. **The agent can propose; only a human can loosen** ([ADR-0005](adr/0005-exceptions-are-human-only-rows.md)).
5. **Every rule has a declarative detector** ([ADR-0004](adr/0004-declarative-detectors-only.md)). A rule that cannot be counted is not admitted.
6. **Fail closed.** Nothing is skipped silently.
7. **Report everything at once,** each finding with its fix line.
8. **Coexist.** Never break the hooks, linters or CI a project already has ([ADR-0006](adr/0006-coexist-with-existing-hooks.md)).
9. **Agnostic** to language, harness and model. The runner needs only bash, awk and git ([ADR-0001](adr/0001-runner-is-bash-awk-git.md)).

## Constraints

- The runner needs only bash, awk and git ([ADR-0001](adr/0001-runner-is-bash-awk-git.md)).
- No commit trailers are used for any purpose.
- No telemetry. Nothing leaves the machine.

## Non-goals

- Orchestrating coordinator and worker agents. That is a separate project.
- Imposing standards, ADRs or an architecture. gauntlet enforces what the owner agrees to.
- Dashboards or HTML reports. State lives in markdown in the repository.
- Publishing to a package registry. Distribution is this public git repository.

## Anti-goals

Any of these is a failure, even if everything else works:

- **The gate is slow, so people reach for `--no-verify`.** The commit-time check stays under 5 s.
- **False positives make people hate the gate.**
- **Known debt suddenly breaks CI.**
- **gauntlet breaks the project's existing hooks or tooling.**
- **The agent loosens the rules it is bound by.**
- **Onboarding buries the owner** in rules, or activates any rule without asking.
- **Two ways do the same thing.** A rule lives in the linter or in gauntlet, never both.
- **Everyone writes detectors their own way.**
