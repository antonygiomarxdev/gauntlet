# FRD — Rule lifecycle

**Status:** Draft
**Key:** LIFE
**Parent PRD:** [PRD — gauntlet](../PRD.md)
**Owner:** Antony Giomar Hernández

## 1. Functional problem

A rule set that never changes rots, and one that changes on an agent's whim stops meaning anything. Rules must evolve deliberately:
- new rules come from concrete signals;
- shadow rules get promoted by a person;
- debt is visible;
- a rule that reaches zero goes back to the linter without being forgotten.

## 2. Actors and situations

| Actor | Situation |
|---|---|
| Owner | Reviews status, promotes rules, and approves new rules. |
| Agent | Notices repeated mistakes and proposes rules. Writes approved rules. Reminds the Owner of rules due for promotion. |
| Contributor | Reads status to pick debt to pay. |

## 3. Preconditions

- gauntlet is installed and onboarded.

## 4. Business rules

1. **`gauntlet status`** regenerates `.gauntlet/STATUS.md` and summarizes it. It shows:
   - counts per rule;
   - the files with the most debt;
   - the trend against earlier baselines in git history;
   - shadow rules due for promotion.
2. **Promotion is manual.** A `shadow` rule stays in shadow until the Owner promotes it with `gauntlet promote <id>`, which sets its severity to `block`.
3. **Reminders after 7 days.** Once a shadow rule is 7 days or more past its `since`, `status` and the Agent remind the Owner to promote it. The reminder includes how often the rule would have failed and any false positives reported.
4. **A rising `track` total** makes the Agent propose promoting that rule.
5. **When the Agent proposes a rule.** `propose-rule` runs only on a concrete signal:
   - the Owner corrected the Agent for a pattern;
   - the Agent fixed the same kind of mistake twice in a session;
   - a `track` rule rose.

   A proposal always carries a working detector and the current count. Nothing is added without the Owner's yes.
6. **`add-rule` follows `.gauntlet/HOW-TO-WRITE-A-RULE.md`.** The rule must have:
   - a rationale and a primary source;
   - evidence in this repo (the count and the worst files);
   - the most declarative detector that works;
   - a one-line fix hint;
   - a check for conflict or overlap with existing rules and with linter-owned rules;
   - `bad` and `good` cases;
   - a measured baseline.

   It starts in shadow.
7. **Linter-owned rules.**
   - A linter rule with 0 violations stays in the linter at `error`, and gauntlet does not duplicate it.
   - A linter rule with debt becomes a gauntlet rule that runs that linter rule.
   - When it reaches 0, it graduates back to the linter at `error`, and gauntlet keeps a **guard**.
8. **A guard is a `block` rule at zero.** It fails if the linter's effective config no longer has the rule at `error`, or if new inline suppressions of the rule appear.
9. **`gauntlet doctor`** checks:
   - the tools are installed;
   - the hooks are wired, or the snippet is present in lefthook or prek;
   - the baseline is exact;
   - the config keys are known;
   - every rule is valid.

   It also lists stale waivers. It prints one line per check with how to fix it, and exits 1 on any failure.

## 5. Functional flows

### Flow A — promote

1. `status` shows `promote due: <id> (shadow since <date>, <n> days)`.
2. The Owner runs `gauntlet promote <id>` and commits.

### Flow B — learning from a mistake

1. The Owner corrects the Agent twice for the same pattern.
2. The Agent runs `propose-rule`: it writes a candidate detector, measures the count, and presents the proposal.
3. With a yes, `add-rule` writes it in shadow. With a no, it goes to `PROPOSALS.md`.

### Flow C — graduation

1. A ratcheted linter rule reaches 0.
2. The rule is set to `error` in the linter config, and the gauntlet rule becomes a guard.
3. Later, someone adds an `eslint-disable` for that rule, and the guard fails.

## 6. Edge cases and failure behavior

- **`promote` on a rule that is not `shadow`** is rejected with exit 2.
- **A proposal whose detector flags nothing in the repo** is still allowed when the signal came from the current session's diff. It must still pass its cases.
- **No git history yet:** the trend is empty, not an error.
- **The linter config changes the rule from `error` to `warn`:** the guard fails.

## 7. Permissions

| Action | Owner | Agent |
|---|---|---|
| Run `status` and `doctor` | yes | yes |
| `promote` | yes | no; it reminds the Owner |
| Propose a rule | yes | yes, only on the signals in §4.5 |
| Approve a rule | yes | no |
| Write an approved rule (`add-rule`) | yes | yes, after an explicit yes |

## 8. Data semantics

- **`.gauntlet/STATUS.md`:** generated and overwritten by `status`. Never edited by hand.
- **`.gauntlet/PROPOSALS.md`:** rules that were not accepted or that lack a detector, each with its reason and date.
- **`.gauntlet/HOW-TO-WRITE-A-RULE.md`:** the checklist in §4.6, installed with v0.1.
- **The rule's `since` key:** the date the rule entered shadow, which drives the 7-day reminder.

## 9. Functional acceptance criteria

- **LIFE-AC1:** Given rules with debt, when `status` runs, then `STATUS.md` lists each rule's severity and total, and the top 5 files by `block` total.
- **LIFE-AC2:** Given a shadow rule with `since` 8 days ago, when `status` runs, then it lists `promote due` for that rule; and given one 6 days old, then it does not.
- **LIFE-AC3:** Given a shadow rule, when the Owner runs `gauntlet promote <id>`, then its severity becomes `block`.
- **LIFE-AC4:** Given a `block` rule, when `gauntlet promote <id>` runs, then it exits 2 and nothing changes.
- **LIFE-AC5:** Given a `track` rule whose total rose, when the Agent sees the gate output, then it proposes promoting that rule.
- **LIFE-AC6:** Given the Owner corrected the same pattern twice, when the Agent proposes a rule, then the proposal contains a working detector, its cases and the current count.
- **LIFE-AC7:** Given a proposal the Owner rejects, when it is closed, then it is in `PROPOSALS.md` and no rule file exists.
- **LIFE-AC8:** Given a ratcheted linter rule at 0 that has graduated, when the linter config lowers it below `error`, then the guard fails.
- **LIFE-AC9:** Given a graduated rule, when a new inline suppression of it appears, then the guard fails.
- **LIFE-AC10:** Given a missing hook line, when `doctor` runs, then it prints a FAIL line with how to fix it, and exits 1.
- **LIFE-AC11:** Given an unknown config key, when `doctor` runs, then it fails and names the key.
- **LIFE-AC12:** Given git history with earlier baselines, when `status` runs, then each rule shows its trend.

## 10. Out of scope

- Automatic promotion, of any kind.
- Dashboards or HTML reports. State lives as markdown in the repo.

## 11. Dependencies on other FRDs

| FRD | Why |
|---|---|
| FRD-02 Rules and detectors (RULE) | The rule format and cases that `add-rule` writes. |
| FRD-03 Gates (GATE) | Shadow and track reporting feeds promotion. |
| FRD-05 Agent integration (AGENT) | Agent-side reminders and proposals. |

## 12. Open questions

1. **How far back does the trend look?** Proposed default: the last 8 commits that changed `baseline.tsv`, shown as first and last counts plus the change.
2. **How are "false positives reported" counted for a shadow rule?** Proposed default: the number of false-positive discussions that name the rule id, entered by hand in the rule body. There is no automatic tracking in v0.1.
3. **Does guard support ship in v0.1?** Proposed default: no. It is planned with the shared linter cache in a later spec. The FRD stays as written.
