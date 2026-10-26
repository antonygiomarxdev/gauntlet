# FRD — Onboarding

**Status:** Approved by Antony Giomar Hernández on 2026-10-22
**Key:** ONB
**Parent PRD:** [PRD — I-01 Core](../PRD.md)
**Owner:** Antony Giomar Hernández

## 1. Functional problem

A repository adopting gauntlet needs a set of rules that fit its stack and that its owner actually agreed to. The obvious alternatives both fail:
- **Imposing a standard** gets the gate turned off.
- **Asking the owner to write rules from scratch** never gets done.

Onboarding studies the repo, researches each technology's own guidance, proposes rules one at a time with evidence, and measures the baseline. The owner decides; nothing is activated without a yes.

## 2. Actors and situations

| Actor | Situation |
|---|---|
| Owner | Adopts gauntlet in an existing repo or an empty one, and answers the proposals. |
| Agent | Runs the `onboard` entry point of the skill in any harness, with or without web access. |
| Contributor | Clones the repo after onboarding and must be protected without doing anything. |

## 3. Preconditions

- The repo is a git repository. gauntlet is installed: the runner is vendored at `.gauntlet/bin/gauntlet` and the skill at `.agents/skills/gauntlet/`.
- The Owner is reachable to answer proposals. Onboarding does not activate anything on the Owner's behalf.

## 4. Business rules

1. **Detect first.** Onboarding detects:
   - the stack, the languages and the existing linters with their configs;
   - existing hooks and setup steps;
   - the test and build commands;
   - the architecture and its patterns.

   In an empty repo it asks the Owner for the stack and the architecture instead.
2. **Primary sources only.** Research uses primary sources: official docs, the technology's style guide, or a project ADR. Without web access, a rule may still be proposed, from the catalog and the repo evidence, with `source: pending`.
3. **Catalog needs evidence and a yes.** A catalog rule is never proposed without evidence in the repo, and never activated without the Owner's yes. The catalog is inspiration, not a default set.
4. **What a proposal carries.** Every proposal has a number and carries:
   - why;
   - the source;
   - the current violation count;
   - the worst files;
   - the detector;
   - the fix hint.

   A constraint with no detector is not proposed as a rule. It goes to `PROPOSALS.md`.
5. **The Owner decides each proposal.** The Owner accepts, rejects or adjusts it, and picks a severity: `block`, `track` or reject. An accepted `block` rule enters as `shadow`, unless the Owner explicitly skips the shadow period.
6. **Accepted rules enter on day one.** Every detectable rule the Owner accepts enters immediately. `PROPOSALS.md` holds only rules that were rejected or lack a detector.
7. **Each accepted rule is complete before install.** It gets its detector and its `bad` and `good` cases. The rule tests pass before the baseline is measured.
8. **Checks are confirmed.** The Owner confirms the declared checks: the commands pre-push runs, their path scopes, and which of them CI runs.
9. **Installation coexists with what is there.** Install adds:
   - hook lines that coexist with the existing hooks (see GATE);
   - the setup-step wiring;
   - the CI job;
   - the `AGENTS.md` block;
   - `ONBOARDING.md` and `STATUS.md`.
10. **The touched gate starts off.** In an existing repo it stays off until the Owner turns it on.
11. **Re-runs update in place.** Re-running onboarding updates every artifact in place and never duplicates a rule, a hook line, an `AGENTS.md` block or a CI job.
12. **Onboarding stays small.** Onboarding never buries the Owner. Proposals come one at a time, ordered by evidence. Forty rules on day one, or a rule activated without asking, is a failure.
13. **Detect every tool that will read `.gauntlet/`.** Besides rule 1, onboarding detects:
    - formatters, and linters that run on staged files;
    - the staged-file runner that feeds them (lint-staged or equivalent);
    - commit-message and identity hooks;
    - project gates that ask for files with a change (changesets, coverage of the diff).

    Install makes each formatter and linter skip `.gauntlet/`, with the project's own ignore mechanism. A runner that passes file names explicitly bypasses ignore files, so its own filter is changed too. Left alone, a formatter rewrites the vendored runner and a linter fails on the `bad` cases, which are bad code on purpose.
14. **Count before proposing.** Every candidate rule is measured in the repo first. A rule the project's own linter or ratchet already counts is not proposed again (see LIFE). A candidate with almost no matches is said to be weak, with its count, and left to the Owner.
15. **Prove the coexistence before the Owner relies on it.** In a throwaway worktree, onboarding:
    - commits through the real hooks;
    - pushes twice to a throwaway local remote, and checks that the project's pre-push still receives the pushed refs;
    - commits a new violation and sees it refused;
    - pays one violation down and sees the baseline update in the same commit.

    It removes the throwaway remote afterwards and never uses `--no-verify`.
16. **Say what the first PR cannot check.** Until the base branch has `baseline.tsv`, CI skips the new, global, shadow and track checks. Onboarding tells the Owner, so a green first PR is not read as a full check.
17. **The project's own gates apply to the onboarding change.** Commit-message and identity rules, changesets and diff coverage are met, not bypassed. Onboarding does not edit the shared git identity to pass them.

## 5. Functional flows

### Flow A — existing repo

1. The Agent detects the stack, tools, hooks, checks and patterns, and writes what it inferred to `ONBOARDING.md`.
2. The Agent researches each detected technology, from primary sources.
3. The Agent asks whether the Owner wants catalog patterns considered. With a no, it skips the catalog.
4. The Agent presents proposal 1 with its evidence. The Owner answers: accept with a severity, adjust, or reject. Then proposal 2, and so on.
5. For each accepted rule, the Agent writes the rule, its detector and its cases, and runs the rule tests.
6. The runner measures `baseline.tsv`.
7. The Owner confirms the declared checks and the CI scope.
8. The Agent installs the hooks, the setup wiring, the CI job and the `AGENTS.md` block, and makes the project's formatters and linters skip `.gauntlet/`. It writes `STATUS.md` and records every answer in `ONBOARDING.md`.
9. The Agent proves the coexistence in a throwaway worktree and reports what the first PR cannot check.

### Flow B — empty repo

1. The Agent asks for the stack and the architecture.
2. Research and proposals run as in Flow A. Counts are 0, so any accepted rule starts clean.

### Flow C — re-run

1. The Agent reads `ONBOARDING.md` and the existing rules.
2. It proposes only what changed: a new stack component, a rule whose `source` is still `pending` now that web access exists, or a new catalog pattern with evidence.
3. It updates artifacts in place.

## 6. Edge cases and failure behavior

- **No web access.** Proposals carry `source: pending`. A later session with web access confirms or replaces each source.
- **A required tool is missing** (for example `ast-grep`). The proposal names the install command. The rule is not written until the tool runs.
- **The Owner adjusts a detector** so that it no longer catches the evidence. The rule tests fail and the Agent reports it before measuring.
- **A linter rule already has 0 violations.** It stays in the linter at `error`, and onboarding does not duplicate it (see LIFE).
- **The project already uses husky, lefthook, prek or custom hooks.** Install adds one line and never takes over (see GATE).
- **A formatter or linter touches `.gauntlet/`.** `doctor` does not notice a changed vendored file. Onboarding compares `.gauntlet/bin` and `.gauntlet/lib` with the checkout they came from after the first commit, adds the ignore entry if they differ, and re-installs.
- **A project hook refuses the onboarding commit** (identity, message format, changeset). The Agent fixes the commit to meet it, and reports a rule it cannot meet.
- **The Owner stops halfway.** Accepted rules stay; the unanswered proposals are listed in `ONBOARDING.md` for the next run.

## 7. Permissions

| Action | Owner | Agent |
|---|---|---|
| Run detection and research | yes | yes |
| Propose a rule | yes | yes |
| Accept, reject or adjust a rule; pick its severity | yes | no |
| Skip the shadow period | yes | no |
| Write accepted rules, detectors and cases | yes | yes, after the Owner's yes |
| Turn on the touched gate | yes | no |

## 8. Data semantics

- **`.gauntlet/ONBOARDING.md`:** what was inferred and what the Owner answered, proposal by proposal. Rewritten in place on every run. It is the record of consent.
- **`.gauntlet/PROPOSALS.md`:** rules that were rejected or lack a detector, each with its reason.
- **`.gauntlet/rules/<id>.md`:** an accepted rule (see RULE).
- **`.gauntlet/baseline.tsv`:** measured debt (see GATE).
- **`.gauntlet/config`:** flat `key=value`. It holds the base ref, the touched gate (`off` in an existing repo) and the declared checks with their path scopes and CI opt-in.
- **`AGENTS.md`:** the gauntlet block (see AGENT).

## 9. Functional acceptance criteria

- **ONB-AC1:** Given an existing repo, when onboarding runs, then `ONBOARDING.md` lists the detected stack, linters, hooks, setup step, and test and build commands.
- **ONB-AC2:** Given an empty repo, when onboarding runs, then the Agent asks for the stack and the architecture before proposing anything.
- **ONB-AC3:** Given no web access, when a rule is proposed, then its `source` is `pending`.
- **ONB-AC4:** Given a catalog pattern with no evidence in the repo, when onboarding runs, then that pattern is not proposed.
- **ONB-AC5:** Given any proposal, when it is shown, then it carries a number, the why, the source, the count, the worst files, the detector and the fix hint.
- **ONB-AC6:** Given the Owner accepts a rule as `block`, when it is written, then its severity is `shadow`, unless the Owner explicitly skipped the shadow period.
- **ONB-AC7:** Given the Owner rejects a rule, when onboarding finishes, then the rule appears in `PROPOSALS.md` with the reason and not in `.gauntlet/rules/`.
- **ONB-AC8:** Given a constraint with no possible detector, when onboarding finishes, then it is in `PROPOSALS.md` and no rule file exists for it.
- **ONB-AC9:** Given accepted rules, when install runs, then every rule's tests pass and `baseline.tsv` equals the measurement.
- **ONB-AC10:** Given an existing repo, when onboarding finishes, then the touched gate is `off` in `config`.
- **ONB-AC11:** Given existing husky hooks, when install runs, then each hook file gains exactly one gauntlet line and every original line is unchanged.
- **ONB-AC12:** Given a fresh clone by a Contributor, when they run the project's existing setup step, then the gauntlet hooks are active.
- **ONB-AC13:** Given onboarding already ran, when it runs again, then no rule, hook line, `AGENTS.md` block or CI job is duplicated.
- **ONB-AC14:** Given a project that formats or lints staged files, when install runs, then committing `.gauntlet/` leaves every vendored file byte-identical and no `bad` case is linted.
- **ONB-AC15:** Given a candidate rule already counted by the project's linter or ratchet, when onboarding runs, then it is not proposed.
- **ONB-AC16:** Given a project with a pre-push hook that reads the pushed refs, when the coexistence check runs, then a second push shows the hook still received them.
- **ONB-AC17:** Given a base branch with no `baseline.tsv`, when onboarding finishes, then the Owner was told which CI checks are skipped on the first PR.

## 10. Out of scope

- Writing the detector engines themselves, and the rule file format (RULE).
- Gate behaviour after install (GATE).
- Choosing an architecture or a standard for the Owner.

## 11. Dependencies on other FRDs

| FRD | Why |
|---|---|
| FRD-02 Rules and detectors (RULE) | Accepted rules are written in its format, with its cases. |
| FRD-03 Push and CI gate (GATE) | Install wires its hooks, checks and CI job. |
| FRD-05 Agent integration (AGENT) | Install writes the `AGENTS.md` block and the adapters. |
| FRD-06 Rule lifecycle (LIFE) | Shadow promotion, and linter-owned rules. |

## 12. Decisions

Decided by the owner on 2026-10-22, each by accepting the proposed default.

1. **How many proposals per session?** Decision: no cap, but ordered by count × severity, and the Owner may say "stop here" at any point. The rest go to `ONBOARDING.md` as pending.
2. **Does the catalog ship in v0.1?** Decision: yes, with the patterns generalized from the origin project (silent catch, raw string vs enum, missing return type, wrong-way layer imports). Each is used only with evidence and a yes.
