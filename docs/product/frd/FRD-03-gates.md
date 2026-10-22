# FRD — Gates

**Status:** Draft
**Key:** GATE
**Parent PRD:** [PRD — gauntlet](../PRD.md)
**Owner:** Antony Giomar Hernández

## 1. Functional problem

Rules only matter if they bite at the moment a mistake is made, and if the bite cannot be argued with:
- A **fixed threshold** fails on day one and gets turned off.
- A **diff filter** forgets moved or reformatted code.
- A **hand-built ratchet** depended on people remembering to commit the lowered baseline. Its diff gate also passed locally and failed in CI, because of a shallow checkout.

The gate accepts today's debt as the floor, refuses any new violation, lets debt only fall, and runs identically at commit, at push and in CI.

## 2. Actors and situations

| Actor | Situation |
|---|---|
| Contributor / Agent | Commits and pushes on a branch, often stacked on another branch. |
| Owner | Configures declared checks, the touched gate and the CI scope. |
| CI | Runs on every PR against its target branch, with full history. |

## 3. Preconditions

- gauntlet is installed and onboarded: the rules exist and `baseline.tsv` is measured.
- Hooks are wired (see §4.17).
- CI checks out the full history.

## 4. Business rules

1. **Three gate points, one runner.**
   - **`pre-commit`** runs `stage: commit` rules on staged files, with a target under 5 s.
   - **`pre-push`** runs `gauntlet check --ci` plus every declared check.
   - **CI** runs `gauntlet check --ci`, plus the declared checks the Owner enabled for CI.
2. **Why `pre-commit` and not `commit-msg`.** The commit-time check runs in `pre-commit`, because a baseline staged in `commit-msg` is left out of the commit. A spike on git 2.43 showed it ([ADR-0007](../../adr/0007-commit-time-check-in-pre-commit.md)).
3. **What `check --ci` verifies:**
   1. **No new violations.** A `block` fingerprint absent from the base baseline fails, unless its path is waived.
   2. **Global.** A `block` rule's total must not rise.
   3. **Touched** (optional, off by default in an existing repo):
      - every file the branch changed comes out with a strictly lower `block` total, summed across rules;
      - a file at 0 stays at 0;
      - an added file comes out at 0;
      - renames are followed, and pure renames are skipped;
      - waived paths are skipped;
      - `shadow` and `track` rules never count.
   4. **The baseline is exact.** The committed `baseline.tsv` equals what the code measures.
   5. **No loosening without an exception** (EXC).
   6. **Rule tests pass** when any rule changed (RULE).
   7. **Declared checks pass,** each scoped by path prefixes.
4. **A fingerprint** is rule + path + the flagged line's text, with whitespace collapsed. Line numbers never count. Moving lines, inserting lines and reformatting change no verdict.
5. **No fail-fast.** Every check runs, and every violation is reported together as `path:line  rule  message`, followed by the rule's `fix` line.
6. **Wall time** is printed per rule and per check.
7. **Existing debt never fails the gate by itself.** Only these fail it:
   - a new violation;
   - a rising total;
   - an untouched-down file, with the touched gate on;
   - a lying baseline;
   - an unexcepted loosening;
   - a failing rule test or declared check.
8. **Auto-tighten.** When a commit lowers the counts, `pre-commit` rewrites `baseline.tsv` and stages it into that same commit. The `shadow` and `track` rows it rewrites may rise, so the baseline stays exact.
9. **Partially staged files skip auto-tighten.** When a staged file also has unstaged changes, auto-tighten is skipped with a notice to run `gauntlet baseline` before pushing. The push gate still verifies exactness.
10. **`shadow` rules** print "would have failed" with the details and never fail.
11. **`track` rules** never fail. When a `track` total rises, the output shows the delta and suggests promotion.
12. **The base is the branch's target.**
    - In CI, it is the PR's target branch.
    - Locally, it is `branch.<name>.gauntletBase`, set by `gauntlet base <ref>` or by a stack tool.
    - Otherwise it is `origin/<default>`.

    The gate compares against the merge-base with that target, so a stacked PR is never charged with the whole stack.
13. **A new rule is not judged by checks 1–3 on its introduction branch.** A rule that does not exist at the base is exempt. When the base has no baseline at all (the onboarding branch), checks 1–3 are skipped with a note.
14. **A dirty tree is refused at push.** `check --ci` refuses to run when tracked files differ from `HEAD`, with `gauntlet checks what you push; commit or stash first`. Untracked files do not count.
15. **Declared checks** live in `config`, one per name, with an optional path-prefix scope and a CI opt-in (default off).
    - Pre-push runs every declared check whose scope matches the changed files.
    - CI runs only those opted in.
16. **Push owns the whole-repo checks.** The commit gate runs the new and touched checks on staged files only. Global, exact, rule tests and declared checks belong to push and CI.
17. **Hooks coexist, never take over.**
    - With husky, lefthook, the `pre-commit` framework (prek) or custom hooks, gauntlet adds one line inside the existing hook and touches nothing else.
    - It never changes an existing `core.hooksPath`.
    - It installs its own hooks only when the project has none.
    - Installation is wired into the project's existing setup step, so a fresh clone is protected.
18. **The CI job.** Onboarding writes a CI job (GitHub Actions first) that runs `gauntlet check --ci` on every PR, with no opt-in label. When branch protection is off, the job also comments the violations and the new exceptions on the PR.

## 5. Functional flows

### Flow A — commit

1. The Contributor commits.
2. `pre-commit` runs the commit-stage rules on the staged files.
3. If there is a new `block` violation, the commit is blocked, with every violation and its fix line.
4. Otherwise, any lowered counts are written to `baseline.tsv` and staged into the same commit.

### Flow B — push

1. `pre-push` runs `gauntlet check --ci` against the merge-base with the branch's target, plus the declared checks.
2. Any failure blocks the push, and every problem is reported together.

### Flow C — CI

1. On a PR, CI fetches the full history and runs `gauntlet check --ci --base origin/<target>`.
2. Without branch protection, it comments the violations and the new exceptions on the PR.

### Flow D — paying debt

1. The Contributor removes a violation and commits.
2. The commit carries the lowered `baseline.tsv`.
3. At push, the exact check passes.

## 6. Edge cases and failure behavior

- **A stacked branch** is compared with its own target, not with `main`.
- **A shallow CI checkout** cannot compute the merge-base. The gate fails rather than guess.
- **The first commit (no `HEAD`)** has nothing to compare at commit time, so the commit gate passes with a note.
- **A deleted file** loses its baseline rows at commit.
- **A renamed and edited file** is compared old path against new path. A pure rename is skipped.
- **A hand-edited baseline** fails the exact check, whether it was edited lower or higher.
- **A commit gate run over 5 s** passes or fails on its merits, and prints that it exceeded the budget.
- **A failed fetch of the base when offline** warns and uses the local ref.
- **lefthook or prek configs.** Install prints the exact snippet to add instead of editing the YAML, and `doctor` fails until the snippet is present.
- **A hook file that ends in `exit 0`.** The gauntlet line is inserted before the `exit`.

## 7. Permissions

| Action | Owner | Contributor | Agent |
|---|---|---|---|
| Turn the touched gate on or off; declare checks and CI scope | yes | no | no |
| Set a branch's base (`gauntlet base`) | yes | yes | yes |
| Run `gauntlet baseline` to re-measure | yes | yes | yes. It cannot lower the merge-base reference, so it cannot absorb new debt. |
| Skip hooks (`--no-verify`) | never, by policy | never | never; the adapters deny it (AGENT) |

## 8. Data semantics

- **`.gauntlet/baseline.tsv`:** one row per `rule	path	fingerprint	count`, sorted, with no header. It is derived: only the runner writes it. It always equals what the code measures, and nobody edits it by hand.
- **`.gauntlet/config`:** flat `key=value`.
  - `base=<ref>`, optional;
  - `touched=on|off`;
  - `check.<name>=<command>`, `check.<name>.paths=<prefixes>` and `check.<name>.ci=on|off`.
- **Exit codes:** 0 passes, 1 means the gate failed, 2 means broken setup or wrong usage.

## 9. Functional acceptance criteria

- **GATE-AC1:** Given a staged file with a new `block` violation, when the Contributor commits, then the commit is blocked and the output shows `path:line  rule  message` and the `fix` line.
- **GATE-AC2:** Given a commit that removes a violation, when it completes, then that same commit contains the lowered `baseline.tsv` and the working tree is clean. This holds both for `git commit` and for `git commit -a`.
- **GATE-AC3:** Given a violation that moved to another line of the same file, or a reformatted file, when any gate runs, then nothing is reported as new.
- **GATE-AC4:** Given two problems (a new violation and a lying baseline), when `check --ci` runs, then both are reported in one run and the summary counts 2 problems.
- **GATE-AC5:** Given a `block` rule whose total rose, when `check --ci` runs, then it fails, showing the base total and the new total.
- **GATE-AC6:** Given a `baseline.tsv` edited by hand, lower or higher, when `check --ci` runs, then it fails and says to run `gauntlet baseline` and commit.
- **GATE-AC7:** Given `touched=off` (the default in an existing repo), when a changed file keeps its debt, then the gate passes.
- **GATE-AC8:** Given `touched=on`, when a changed file with debt does not go down by at least one `block` violation of any rule, then the gate fails for that file; and when it does go down by one, then the gate passes.
- **GATE-AC9:** Given branch `b` stacked on `a` with base `a`, when `check --ci` runs on `b`, then only `b`'s own changes are judged.
- **GATE-AC10:** Given a new `shadow` violation, when any gate runs, then it prints "would have failed" and does not fail.
- **GATE-AC11:** Given a `track` total that rose, when any gate runs, then it prints the delta with a promotion suggestion and does not fail.
- **GATE-AC12:** Given a rule added on this branch with existing debt and an exact baseline, when `check --ci` runs, then checks 1–3 do not fail on that rule.
- **GATE-AC13:** Given uncommitted changes to tracked files, when `check --ci` runs, then it exits 2 with `commit or stash first`.
- **GATE-AC14:** Given a staged file with unstaged changes, when the Contributor commits, then auto-tighten is skipped and the output says `partially staged`.
- **GATE-AC15:** Given a declared check scoped to `src/` and a change only under `docs/`, when pre-push runs, then that check is skipped; and given `CI=true` and a check with CI opt-in off, when CI runs, then that check is skipped.
- **GATE-AC16:** Given any gate run, when it finishes, then the wall time of each rule and each check is printed.
- **GATE-AC17:** Given existing husky hooks, when hooks are installed twice, then each hook contains its original lines plus exactly one gauntlet line, and `core.hooksPath` is unchanged.

## 10. Out of scope

- Creating exceptions (EXC).
- Write-time warnings inside an agent harness (AGENT).
- CI providers other than GitHub Actions, until a consumer needs one.

## 11. Dependencies on other FRDs

| FRD | Why |
|---|---|
| FRD-02 Rules and detectors (RULE) | The gate runs the rules and their tests. |
| FRD-04 Exceptions (EXC) | Waivers exempt paths; loosening needs rows. |
| FRD-06 Rule lifecycle (LIFE) | Shadow and track rules feed promotion. |

## 12. Open questions

1. **Refusing a dirty tree at push is strict.** Proposed default: keep the refusal, since parity with what is pushed is non-negotiable. Revisit if checking `HEAD` in a temporary worktree proves fast enough.
2. **Should the commit gate fail when it goes over the 5 s budget?** Proposed default: no. It prints a warning and `status` lists the slow rules, so they can be moved to `stage: push`.
3. **The CI PR comment needs a token with PR write permission.** Proposed default: the generated job uses `GITHUB_TOKEN` with `pull-requests: write`. It comments only when branch protection is off.
