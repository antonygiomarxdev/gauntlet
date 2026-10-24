# FRD — Commit gate and hooks

**Status:** Approved by Antony Giomar Hernández on 2026-10-22
**Key:** HOOK
**Parent PRD:** [PRD — I-01 Core](../PRD.md)
**Owner:** Antony Giomar Hernández

## 1. Functional problem

A mistake is cheapest when it is caught at the commit that makes it. Two things went wrong in the hand-built process:
- When debt fell, someone had to remember to commit the lowered baseline.
- A gate wired by replacing a project's hooks breaks what the project already runs.

The commit gate checks staged files in under 5 s, carries a lowered baseline into the same commit, and is wired into the project's existing hooks without taking them over. What `check --ci` verifies at push and in CI is in [FRD-03](FRD-03-push-and-ci-gate.md).

## 2. Actors and situations

| Actor | Situation |
|---|---|
| Contributor / Agent | Commits, by `git commit` or `git commit -a`. |
| Owner | Installs gauntlet into a repo that may already use husky, lefthook, prek or custom hooks. |

## 3. Preconditions

- gauntlet is installed and onboarded: the rules exist and `baseline.tsv` is measured.

## 4. Business rules

1. **`pre-commit` runs `stage: commit` rules on staged files,** with a target under 5 s. It runs only the new and touched checks; the whole-repo checks belong to push and CI (GATE).
2. **Why `pre-commit` and not `commit-msg`.** A baseline staged in `commit-msg` is left out of the commit. A spike on git 2.43 showed it ([ADR-0007](../../../adr/0007-commit-time-check-in-pre-commit.md)).
3. **Reporting** follows the gate's rules: fingerprints, no fail-fast, the `fix` line under each violation and wall time per rule (GATE §4.3–4.5).
4. **Auto-tighten.** When a commit lowers the counts, `pre-commit` rewrites `baseline.tsv` and stages it into that same commit. The `shadow` and `track` rows it rewrites may rise, so the baseline stays exact.
5. **Partially staged files skip auto-tighten.** When a staged file also has unstaged changes, auto-tighten is skipped with a notice to run `gauntlet baseline` before pushing. The push gate still verifies exactness.
6. **The 5 s budget warns, never fails.** A run over budget passes or fails on its merits and prints that it exceeded the budget; `status` lists the slow rules so they can move to `stage: push`.
7. **Hooks coexist, never take over.**
   - With husky, lefthook, the `pre-commit` framework (prek) or custom hooks, gauntlet adds one line inside the existing hook and touches nothing else.
   - It never changes an existing `core.hooksPath`.
   - It installs its own hooks only when the project has none.
   - Installation is wired into the project's existing setup step, so a fresh clone is protected.

## 5. Functional flows

### Flow A — commit

1. The Contributor commits.
2. `pre-commit` runs the commit-stage rules on the staged files.
3. If there is a new `block` violation, the commit is blocked, with every violation and its fix line.
4. Otherwise, any lowered counts are written to `baseline.tsv` and staged into the same commit.

### Flow B — install hooks

1. `gauntlet install-hooks` detects the hook layout.
2. It adds its line to each existing hook, creates hooks only where none exist, or prints the snippet for a YAML-configured hook manager.

## 6. Edge cases and failure behavior

- **The first commit (no `HEAD`)** has nothing to compare, so the commit gate passes with a note.
- **A deleted file** loses its baseline rows at commit.
- **lefthook or prek configs.** Install prints the exact snippet to add instead of editing the YAML, and `doctor` fails until the snippet is present.
- **A hook file that ends in `exit 0`.** The gauntlet line goes first in an existing hook, right after the shebang line, not before the `exit`. An early `exit`, an `exec` or a failing last command cannot skip it, and the project's own hook then runs unchanged.

## 7. Permissions

| Action | Owner | Contributor | Agent |
|---|---|---|---|
| Install or reinstall hooks | yes | yes | yes |
| Skip hooks (`--no-verify`) | never, by policy | never | never; the adapters deny it (AGENT) |

## 8. Data semantics

- **Hook line:** one line, marked so a second install finds it and adds nothing.
- **`.gauntlet/baseline.tsv`:** as in GATE §8; at commit it only ever loses rows or lowers counts for `block` rules.

## 9. Functional acceptance criteria

- **HOOK-AC1:** Given a staged file with a new `block` violation, when the Contributor commits, then the commit is blocked and the output shows `path:line  rule  message` and the `fix` line.
- **HOOK-AC2:** Given a commit that removes a violation, when it completes, then that same commit contains the lowered `baseline.tsv` and the working tree is clean. This holds both for `git commit` and for `git commit -a`.
- **HOOK-AC3:** Given a staged file with unstaged changes, when the Contributor commits, then auto-tighten is skipped and the output says `partially staged`.
- **HOOK-AC4:** Given existing husky hooks, when hooks are installed twice, then each hook contains its original lines plus exactly one gauntlet line, and `core.hooksPath` is unchanged.
- **HOOK-AC5:** Given a repo with no commits, when the first commit is made, then the commit gate passes with a note.
- **HOOK-AC6:** Given a commit-stage run over the 5 s budget with no new violation, when the Contributor commits, then the commit succeeds and the output says the budget was exceeded.
- **HOOK-AC7:** Given a lefthook config, when hooks are installed, then the config file is unchanged, the output prints the snippet, and `doctor` fails until the snippet is present.
- **HOOK-AC8:** Given a hook file that ends in `exit 0`, when hooks are installed, then the gauntlet line comes before the `exit`.

## 10. Out of scope

- What `check --ci` verifies (GATE).
- Write-time warnings inside an agent harness (AGENT).

## 11. Dependencies on other FRDs

| FRD | Why |
|---|---|
| FRD-02 Rules and detectors (RULE) | The commit gate runs the commit-stage rules. |
| FRD-03 Push and CI gate (GATE) | Shares fingerprints and reporting; verifies at push what the commit carried. |
| FRD-05 Agent integration (AGENT) | The adapters deny `--no-verify`. |

## 12. Decisions

Decided by the owner on 2026-10-22.

1. **The commit gate does not fail over the 5 s budget.** It warns, and `status` lists the slow rules.
2. **Split from the former single gates FRD,** to keep each FRD under about 15 acceptance criteria.
