# PRD — I-01 Core

**Status:** Draft
**Key:** CORE
**Owner:** Antony Giomar Hernández
**Target stage:** v0.1 (runner usable by hand), then v0.2 (agent onboarding)
**Vision:** [VISION](../../VISION.md). The thesis, problem, users, principles, constraints, non-goals and anti-goals live there and are not repeated here.

## 1. What this initiative delivers

The first usable gauntlet: a runner that measures owner-approved rules and gates commits, pushes and CI, then the agent skill that onboards a repository and evolves its rules.

## 2. Goals

1. Onboard any repository, existing or empty, into a set of owner-approved rules with a measured baseline.
2. Back every rule with a deterministic, declarative detector.
3. Catch new violations at commit, push and CI, and let debt only fall.
4. Work with any language, any agent harness and any model.
5. Learn: when an agent keeps making the same mistake, propose a rule.
6. Coexist with whatever the project already has.

## 3. Capabilities

| Capability | FRD |
|---|---|
| Onboard a repository by agreeing rules with the owner | [FRD-01](frd/FRD-01-onboarding.md) |
| Define rules with declarative, tested detectors | [FRD-02](frd/FRD-02-rules-and-detectors.md) |
| Gate pushes and CI | [FRD-03](frd/FRD-03-push-and-ci-gate.md) |
| Grant exceptions, by humans only | [FRD-04](frd/FRD-04-exceptions.md) |
| Bind agents in any harness | [FRD-05](frd/FRD-05-agent-integration.md) |
| Evolve rules: status, promotion, proposals, graduation | [FRD-06](frd/FRD-06-rule-lifecycle.md) |
| Gate commits and wire into existing hooks | [FRD-07](frd/FRD-07-commit-gate-and-hooks.md) |

## 4. Release criteria

- **CORE-PA1:** A repository adopts gauntlet by hand (install, write a rule, baseline) without breaking its existing hooks. The full lifecycle runs green on Linux and macOS.
- **CORE-PA2:** In a test repo, an agent cannot get a new violation, a lowered severity or an edited baseline past `check --ci` without a human-created exception row.
- **CORE-PA3:** A second repository in another language (Python) is onboarded by the skill, with every rule accepted by its owner.

## 5. Success metrics

- **Debt trend:** per-rule totals in adopting repos fall over time and never rise without an exception.
- **Escape-hatch rate:** the share of commits that need an exception stays well below the 7–17 % the hand-built trailer reached.
- **Commit-time latency:** p90 under 5 s.
- **False-positive reports:** each one is resolved by a detector fix or a case, not by a waiver.

I-01 reads these by hand from `status`, the baseline history and the discussions. Measuring them systematically, and telling which rules work and which do not, is [I-03](../README.md).

## 6. Assumptions to validate

- **Declarative detectors (linter, ast-grep, rg) are enough for most rules.** Falsified if more than about 1 in 5 rules needs a `script` exception, here or in [I-02](../README.md).
- **Fingerprints by normalized line text are stable enough.** Falsified if reformat-driven false "new" reports show up in practice.
- **Agents follow a gate that explains the fix.** Falsified if agents keep proposing waivers instead of fixing.

## 7. Release strategy

1. **v0.1, runner core:** usable by hand, for the owner's own repos. Proves CORE-PA1 and CORE-PA2.
2. **v0.2, skill and agent integration:** onboarding, propose-rule and add-rule, plus the Claude Code adapter. Proves CORE-PA3.

Replacing the origin project's hand-built ratchets is initiative [I-02](../README.md), which starts once v0.1 ships.

## 8. Risks

- **The gate is too slow on large repos,** so `--no-verify` becomes a habit.
- **False positives in the first rules** burn trust before shadow mode can show its value.
- **Hook managers vary widely,** and one unhandled layout breaks a team's setup.

## 9. Open questions

None blocking. The FRDs carry their own questions, each with a proposed default.

## 10. Documents

| Document | Status |
|---|---|
| [FRD-01](frd/FRD-01-onboarding.md) Onboarding | Draft |
| [FRD-02](frd/FRD-02-rules-and-detectors.md) Rules and detectors | Draft |
| [FRD-03](frd/FRD-03-push-and-ci-gate.md) Push and CI gate | Draft |
| [FRD-04](frd/FRD-04-exceptions.md) Exceptions | Draft |
| [FRD-05](frd/FRD-05-agent-integration.md) Agent integration | Draft |
| [FRD-06](frd/FRD-06-rule-lifecycle.md) Rule lifecycle | Draft |
| [FRD-07](frd/FRD-07-commit-gate-and-hooks.md) Commit gate and hooks | Draft |
| [TP-01](../../architecture/TP-01-gauntlet.md) System technical proposal (parent; this initiative has no local proposal yet) | Draft |
| [IS-01](specs/IS-01-runner-core.md) Runner core | Draft |
