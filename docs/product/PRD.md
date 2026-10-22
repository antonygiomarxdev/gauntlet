# PRD — gauntlet

**Status:** Draft
**Key:** GT
**Owner:** Antony Giomar Hernández
**Target stage:** v0.1 (runner usable by hand), then v0.2 (agent onboarding)

## 1. Product thesis

An agent that writes code in a repository must not be able to make that repository worse. With gauntlet, every rule the owner agreed to is counted, existing debt can only go down, and a new violation is caught at commit, at push and in CI, whoever wrote it. That holds in any language, any agent harness and any model.

## 2. Problem and evidence

Rules written in prose get forgotten. Agents read `AGENTS.md`, standards pages and ADRs, agree with them, and break them three PRs later while every test stays green. In the origin project, a PR passed review, lint, type-check and 1,105 tests, and still shipped two defects that reproduced a production outage. None of the rules it broke had a detector.

The hand-built answer, per-rule ratchets plus a local pre-push gate, worked. Over six weeks it cut debt by 22–85 % per rule while merged PRs per week went up (see the [case study](../guide/case-study.md)). It also leaked:

- **Bespoke scripts.** They grew from 16 to 41 check and ratchet scripts, each with its own format and no guide for adding one.
- **A routine escape hatch.** A waiver trailer agents could write themselves appeared in up to 17 % of a week's commits.
- **Thirteen baseline rises.** One came from a tool bug, and three added debt with no reason given.
- **Lowered baselines that had to be remembered.** When debt fell, someone had to remember to commit the new number.
- **A diff gate keyed on line numbers.** A reformat made old violations look new.

Existing tools each cover part of the engine. None has a touched-file gate, rules as files with a rationale, onboarding that researches and proposes rules, or rules learned from an agent's repeated mistakes ([comparison](../guide/comparison.md)).

## 3. Users and jobs to be done

| User | Job |
|---|---|
| **Owner** of a repository where agents write much of the code | "Make the rules I agreed to bite, without me reviewing every line and without breaking what my repo already runs." |
| **Contributor**, human or agent | "Tell me exactly what I broke, where, and how to fix it, before I push." |
| **Adopter** with an existing codebase and existing debt | "Start today without known debt failing CI, then pay it down at my own pace." |

## 4. Goals

1. Onboard any repository, existing or empty, into a set of owner-approved rules with a measured baseline.
2. Back every rule with a deterministic, declarative detector. A rule that cannot be counted is not admitted.
3. Catch new violations at commit, push and CI, and let debt only fall.
4. Work with any language, any agent harness and any model.
5. Learn: when an agent keeps making the same mistake, propose a rule.
6. Coexist with whatever the project already has.
7. Replace the origin project's hand-built ratchets and pre-push gate completely.

## 5. Non-goals

- Orchestrating coordinator and worker agents. That is a separate project.
- Imposing standards, ADRs or an architecture. gauntlet enforces what the owner agrees to.
- Dashboards or HTML reports. State lives in markdown in the repository.
- Publishing to a package registry. Distribution is this public git repository.

## 6. Anti-goals

Any of these is a failure, even if everything else works:

- **The gate is slow, so people reach for `--no-verify`.** The commit-time check stays under 5 s.
- **False positives make people hate the gate.**
- **Known debt suddenly breaks CI.**
- **gauntlet breaks the project's existing hooks or tooling.**
- **The agent loosens the rules it is bound by.**
- **Onboarding buries the owner** in rules, or activates any rule without asking.
- **Two ways do the same thing.** A rule lives in the linter or in gauntlet, never both.
- **Everyone writes detectors their own way.**

## 7. Product capabilities

| Capability | FRD |
|---|---|
| Onboard a repository by agreeing rules with the owner | [FRD-01](frd/FRD-01-onboarding.md) |
| Define rules with declarative, tested detectors | [FRD-02](frd/FRD-02-rules-and-detectors.md) |
| Gate commits, pushes and CI | [FRD-03](frd/FRD-03-gates.md) |
| Grant exceptions, by humans only | [FRD-04](frd/FRD-04-exceptions.md) |
| Bind agents in any harness | [FRD-05](frd/FRD-05-agent-integration.md) |
| Evolve rules: status, promotion, proposals, graduation | [FRD-06](frd/FRD-06-rule-lifecycle.md) |

## 8. Product principles

1. **Nothing is pushed without knowing it passes CI.** Pre-push runs what CI runs, under the same conditions.
2. **Existing debt never fails the gate by itself.** Only new violations, a lying baseline, loosened rules and, when the owner has enabled it, untouched debt in touched files can fail it.
3. **Nothing starts blocking without the owner's yes.** New blocking rules start in shadow, and promotion is manual ([ADR-0009](../adr/0009-shadow-first-manual-promotion.md)).
4. **The agent can propose; only a human can loosen** ([ADR-0005](../adr/0005-exceptions-are-human-only-rows.md)).
5. **Fail closed.** A broken detector or a missing tool fails loudly. Nothing is skipped silently.
6. **Report everything at once,** each finding with its fix line, so it can all be fixed in one pass.

## 9. Release criteria

- **GT-PA1:** A repository adopts gauntlet by hand (install, write a rule, baseline) without breaking its existing hooks. The full lifecycle runs green on Linux and macOS.
- **GT-PA2:** In a test repo, an agent cannot get a new violation, a lowered severity or an edited baseline past `check --ci` without a human-created exception row.
- **GT-PA3:** The origin project replaces every hand-built ratchet and its pre-push gate with gauntlet, keeping the same counts.
- **GT-PA4:** A second repository in another language (Python) is onboarded by the skill, with every rule accepted by its owner.

## 10. Success metrics

- **Debt trend:** per-rule totals in adopting repos fall over time and never rise without an exception.
- **Escape-hatch rate:** the share of commits that need an exception stays well below the 7–17 % the hand-built trailer reached.
- **Commit-time latency:** p90 under 5 s.
- **False-positive reports:** each one is resolved by a detector fix or a case, not by a waiver.

## 11. Constraints

- The runner needs only bash, awk and git ([ADR-0001](../adr/0001-runner-is-bash-awk-git.md)).
- No commit trailers are used for any purpose.
- No telemetry. Nothing leaves the machine.

## 12. Assumptions to validate

- **Declarative detectors (linter, ast-grep, rg) are enough for most rules.** Falsified if more than about 1 in 5 rules in the origin project's migration needs a `script` exception.
- **Fingerprints by normalized line text are stable enough.** Falsified if reformat-driven false "new" reports show up in practice.
- **Agents follow a gate that explains the fix.** Falsified if agents keep proposing waivers instead of fixing.

## 13. Release strategy

1. **v0.1, runner core:** usable by hand, for the owner's own repos. Proves GT-PA1 and GT-PA2.
2. **v0.2, skill and agent integration:** onboarding, propose-rule and add-rule, plus the Claude Code adapter. Proves GT-PA4.
3. **Origin-project migration,** one ratchet per PR. Proves GT-PA3.

## 14. Risks

- **The gate is too slow on large repos,** so `--no-verify` becomes a habit.
- **False positives in the first rules** burn trust before shadow mode can show its value.
- **Hook managers vary widely,** and one unhandled layout breaks a team's setup.

## 15. Open questions

None blocking. The FRDs carry their own questions, each with a proposed default.

## 16. FRD index

| FRD | Capability | Status |
|---|---|---|
| [FRD-01](frd/FRD-01-onboarding.md) | Onboarding | Draft |
| [FRD-02](frd/FRD-02-rules-and-detectors.md) | Rules and detectors | Draft |
| [FRD-03](frd/FRD-03-gates.md) | Gates | Draft |
| [FRD-04](frd/FRD-04-exceptions.md) | Exceptions | Draft |
| [FRD-05](frd/FRD-05-agent-integration.md) | Agent integration | Draft |
| [FRD-06](frd/FRD-06-rule-lifecycle.md) | Rule lifecycle | Draft |
