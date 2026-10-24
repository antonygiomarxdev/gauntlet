# FRD — Push and CI gate

**Status:** Approved by Antony Giomar Hernández on 2026-10-22
**Key:** GATE
**Parent PRD:** [PRD — I-01 Core](../PRD.md)
**Owner:** Antony Giomar Hernández

## 1. Functional problem

Rules only matter if they bite, and if the bite cannot be argued with:
- A **fixed threshold** fails on day one and gets turned off.
- A **diff filter** forgets moved or reformatted code.
- A **hand-built ratchet** passed locally and failed in CI, because of a shallow checkout.

`gauntlet check --ci` accepts today's debt as the floor, refuses any new violation, lets debt only fall, and runs identically at push and in CI. The commit-time check and the hooks that call both gates are in [FRD-07](FRD-07-commit-gate-and-hooks.md).

## 2. Actors and situations

| Actor | Situation |
|---|---|
| Contributor / Agent | Pushes a branch, often stacked on another branch. |
| Owner | Configures declared checks, the touched gate and the CI scope. |
| CI | Runs on every PR against its target branch, with full history. |

## 3. Preconditions

- gauntlet is installed and onboarded: the rules exist and `baseline.tsv` is measured.
- Hooks are wired ([FRD-07](FRD-07-commit-gate-and-hooks.md)).
- CI checks out the full history.

## 4. Business rules

1. **One command at push and in CI.**
   - **`pre-push`** runs `gauntlet check --ci --pre-push` plus every declared check. The flag makes it read the refs git is pushing (rule 11).
   - **CI** runs `gauntlet check --ci --base origin/<target>`, plus the declared checks the Owner enabled for CI.
   - Both run the branch's own vendored runner, so local and CI judge the same way. That runner is part of the branch it judges and cannot protect against its own author. `check --ci` prints `note: the vendored runner changed in this branch (.gauntlet/bin or .gauntlet/lib differ from the base); review it` when the runner differs from the base. It is a note, never a failure. CODEOWNERS on `.gauntlet/` routes a change to a reviewer. A project may instead have CI run the base's runner against the PR tree, at the cost that a PR that upgrades gauntlet is judged by the old runner and can fail only in CI.
2. **What `check --ci` verifies:**
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
   6. **Rule tests pass** when any rule or output format changed (RULE).
   7. **Declared checks pass,** each scoped by path prefixes.
3. **A fingerprint** is rule + path + the flagged line's text, with whitespace collapsed. Line numbers never count. Moving lines, inserting lines and reformatting change no verdict.
4. **No fail-fast.** Every check runs, and every violation is reported together as `path:line  rule  message`, followed by the rule's `fix` line.
5. **Wall time** is printed per rule and per check.
6. **Existing debt never fails the gate by itself.** Only these fail it:
   - a new violation;
   - a rising total;
   - an untouched-down file, with the touched gate on;
   - a lying baseline;
   - an unexcepted loosening;
   - a failing rule test or declared check.
7. **`shadow` rules** print "would have failed" with the details and never fail.
8. **`track` rules** never fail. When a `track` total rises, the output shows the delta and suggests promotion.
9. **The base is the branch's target.**
   - In CI, it is the PR's target branch.
   - Locally, it is `branch.<name>.gauntletBase`, set by `gauntlet base <ref>` or by a stack tool.
   - Otherwise it is `origin/<default>`.

   The gate compares against the merge-base with that target, so a stacked PR is never charged with the whole stack.
10. **A new rule is not judged by checks 1–3 on its introduction branch.** A rule that does not exist at the base is exempt. When the base has no baseline at all (the onboarding branch), checks 1–3 are skipped with a note.
11. **A dirty tree is refused.** `check --ci` refuses to run when tracked files differ from `HEAD`, with `gauntlet checks what you push; commit or stash first`. Untracked files do not count. What is checked must be exactly what is pushed.
    - **The pushed refs.** `pre-push` reads the ref lines git sends. When a pushed branch tip (`refs/heads/*`, or a Gerrit `refs/for/*`) is not the checked-out `HEAD`, it refuses with exit 1 and `gauntlet checks the checked-out branch; check out <branch> and push again`. Deletes and refs in any other namespace (tags, notes) are skipped.
    - **Limit.** A hook manager that does not pass git's stdin to the command hides the refs: prek does not pass it, and lefthook passes it only with `use_stdin: true`. The gate then judges the checked-out branch, and `doctor` fails a lefthook config without `use_stdin: true`.
12. **Declared checks** live in `config`, one per name, with an optional path-prefix scope and a CI opt-in (default off).
    - Pre-push runs every declared check whose scope matches the changed files.
    - CI runs only those opted in.
13. **Push owns the whole-repo checks:** global, exact, rule tests and declared checks. The commit gate runs only the new and touched checks on staged files (FRD-07).
14. **The CI job.** Onboarding writes a CI job (GitHub Actions first) that runs `gauntlet check --ci` on every PR, with no opt-in label. When branch protection is off, the job also comments the violations and the new exceptions on the PR, using `GITHUB_TOKEN` with `pull-requests: write`.

## 5. Functional flows

### Flow A — push

1. `pre-push` runs `gauntlet check --ci` against the merge-base with the branch's target, plus the declared checks.
2. Any failure blocks the push, and every problem is reported together.

### Flow B — CI

1. On a PR, CI fetches the full history and runs `gauntlet check --ci --base origin/<target>`.
2. Without branch protection, it comments the violations and the new exceptions on the PR.

### Flow C — paying debt

1. The Contributor removes a violation and commits; the commit carries the lowered `baseline.tsv` (FRD-07).
2. At push, the exact check passes.

## 6. Edge cases and failure behavior

- **A stacked branch** is compared with its own target, not with `main`.
- **A shallow CI checkout** cannot compute the merge-base. The gate fails rather than guess.
- **A renamed and edited file** is compared old path against new path. A pure rename is skipped.
- **A hand-edited baseline** fails the exact check, whether it was edited lower or higher.
- **A failed fetch of the base when offline** warns and uses the local ref.

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

- **GATE-AC1:** Given a violation that moved to another line of the same file, or a reformatted file, when any gate runs, then nothing is reported as new.
- **GATE-AC2:** Given two problems (a new violation and a lying baseline), when `check --ci` runs, then both are reported in one run and the summary counts 2 problems.
- **GATE-AC3:** Given a `block` rule whose total rose, when `check --ci` runs, then it fails, showing the base total and the new total.
- **GATE-AC4:** Given a `baseline.tsv` edited by hand, lower or higher, when `check --ci` runs, then it fails and says to run `gauntlet baseline` and commit.
- **GATE-AC5:** Given `touched=off` (the default in an existing repo), when a changed file keeps its debt, then the gate passes.
- **GATE-AC6:** Given `touched=on`, when a changed file with debt does not go down by at least one `block` violation of any rule, then the gate fails for that file; and when it does go down by one, then the gate passes.
- **GATE-AC7:** Given branch `b` stacked on `a` with base `a`, when `check --ci` runs on `b`, then only `b`'s own changes are judged.
- **GATE-AC8:** Given a new `shadow` violation, when any gate runs, then it prints "would have failed" and does not fail.
- **GATE-AC9:** Given a `track` total that rose, when any gate runs, then it prints the delta with a promotion suggestion and does not fail.
- **GATE-AC10:** Given a rule added on this branch with existing debt and an exact baseline, when `check --ci` runs, then checks 1–3 do not fail on that rule.
- **GATE-AC11:** Given uncommitted changes to tracked files, when `check --ci` runs, then it exits 2 with `commit or stash first`.
- **GATE-AC12:** Given a declared check scoped to `src/` and a change only under `docs/`, when pre-push runs, then that check is skipped; and given `CI=true` and a check with CI opt-in off, when CI runs, then that check is skipped.
- **GATE-AC13:** Given any gate run, when it finishes, then the wall time of each rule and each check is printed.
- **GATE-AC14:** Given a PR with a new violation and branch protection off, when the CI job runs, then it comments the violation on the PR; and given branch protection on, then it does not comment.

## 10. Out of scope

- The commit-time check and hook installation (FRD-07).
- Creating exceptions (EXC).
- Write-time warnings inside an agent harness (AGENT).
- CI providers other than GitHub Actions, until a consumer needs one.

## 11. Dependencies on other FRDs

| FRD | Why |
|---|---|
| FRD-02 Rules and detectors (RULE) | The gate runs the rules and their tests. |
| FRD-04 Exceptions (EXC) | Waivers exempt paths; loosening needs rows. |
| FRD-06 Rule lifecycle (LIFE) | Shadow and track rules feed promotion. |
| FRD-07 Commit gate and hooks (HOOK) | Hooks call this gate; commits carry the lowered baseline it verifies. |

## 12. Decisions

Decided by the owner on 2026-10-22.

1. **A dirty tree stays refused.** Parity with what is pushed is non-negotiable. Revisited only if checking `HEAD` in a temporary worktree proves fast enough.
2. **The CI PR comment** uses `GITHUB_TOKEN` with `pull-requests: write`, and only when branch protection is off.
3. **The former single gates FRD was split** into this FRD and FRD-07, to keep each under about 15 acceptance criteria.
