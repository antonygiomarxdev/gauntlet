# FRD — Exceptions

**Status:** Approved by Antony Giomar Hernández on 2026-10-22
**Key:** EXC
**Parent PRD:** [PRD — I-01 Core](../PRD.md)
**Owner:** Antony Giomar Hernández

## 1. Functional problem

Some debt cannot be paid in this branch, and some rules need to change. The hand-built version used a commit trailer as the escape hatch. Agents could write it themselves, so they did: it appeared in up to 17 % of a week's commits.

An exception must be explicit, reviewable and written only by a human. An agent must never be able to grant itself one.

## 2. Actors and situations

| Actor | Situation |
|---|---|
| Owner / human Contributor | Decides an exception is justified and creates it. |
| Agent | Is blocked by the gate. It may only propose the exact command and its reason, then stop and notify. |
| CI | Comments every new exception on the PR. |

## 3. Preconditions

- gauntlet is installed. `.gauntlet/exceptions.tsv` exists, with its header.

## 4. Business rules

1. **Four types of exception:**
   - `waive` a path;
   - `loosen` a rule;
   - `remove` a rule;
   - `script` approves a custom detector.
2. **Created only by a command, and only by a human.** An exception is created only by `gauntlet waive <path> "<reason>"`, `gauntlet loosen <rule> "<what changes>" "<reason>"`, `gauntlet remove <rule> "<reason>"` or the `script` equivalent, run by a human. In Claude Code the human runs it as `! gauntlet …`, which is their own shell command.
3. **A reason is required.** An empty reason is rejected.
4. **There are no commit trailers.** Commit messages grant nothing.
5. **A `waive` exempts one path** from the new-violation and touched checks, on its own branch only. The rule's global total still applies. In CI, the current branch is the PR's head branch (`GITHUB_HEAD_REF`), not the detached HEAD.
6. **A waive from another branch has no effect.** Rows left over from merged branches are listed by `gauntlet doctor` as stale.
7. **A `loosen` or `remove` counts only if it is new since the merge-base.** It must be present now and absent at the base, so an old row never covers a new loosening.
8. **What counts as loosening** (each one fails without a matching new row):
   - removing a rule file;
   - lowering its severity (`block` > `shadow` > `track`);
   - narrowing `paths`;
   - widening `exclude`;
   - changing its engine, its detector, or its detector file;
   - changing its `format`, or changing or adding a project format file (`.gauntlet/formats/`) that a `block` rule reads through, since a format decides which output lines count;
   - changing `.gauntlet/config` so that a gate relaxes: a different `base=` (judged against the base the branch selects and against the default base); `touched` going from on to off, where deleting the line of an enabled gate counts; a declared check removed, its CI opt-in turned off, its path scope narrowed, or its command changed. One row for the pseudo-rule `@config` covers them: `gauntlet loosen @config "<what changes>" "<reason>"`.

   Widening `paths`, raising a severity or changing a rule's `stage` is not loosening: a rule moved to `push` is still enforced at push and in CI.
9. **When the Agent is blocked**, it proposes the exact command with its reason, stops, and notifies the human. It never routes around the gate.
10. **CI comments every new exception on the PR.**

## 5. Functional flows

### Flow A — waive a path

1. The gate blocks a branch because of debt that cannot be paid now.
2. The human runs `gauntlet waive src/legacy/report.ts "rewrite scheduled in #123"`.
3. They commit `exceptions.tsv`.
4. The gate passes for that path on that branch.

### Flow B — loosen a rule

1. The human runs `gauntlet loosen raw-status "exclude += src/generated/**" "generated code"`.
2. They edit the rule and commit both.
3. The loosening check passes.

### Flow C — agent blocked

1. The Agent hits a block it cannot fix.
2. It prints the exact `gauntlet waive …` command and its reason.
3. It notifies the human and stops.

## 6. Edge cases and failure behavior

- **The waived path does not exist.** The command is rejected.
- **A waive created on branch `f` is merged into `main`.** On any other branch it has no effect, and `doctor` lists it as stale.
- **In CI on a detached HEAD**, the branch comes from `GITHUB_HEAD_REF`. Without it, the waiver would never apply.
- **A loosen row was committed on `main` earlier.** It does not cover a new loosening on this branch.
- **The Agent tries to edit `exceptions.tsv` directly.** The adapter denies the edit (AGENT). In other harnesses the edit is visible in the PR diff, and CI comments it.

## 7. Permissions

| Action | Owner / human | Agent |
|---|---|---|
| Create `waive`, `loosen`, `remove` or `script` | yes | no |
| Propose the exact command and its reason | yes | yes |
| Edit `exceptions.tsv` by hand | discouraged; the command is the interface | no |

## 8. Data semantics

`.gauntlet/exceptions.tsv`, versioned, one row per exception, with the header `type	target	reason	date	branch`:

| Type | Target | Branch | Lifetime |
|---|---|---|---|
| `waive` | one path | the branch it was created on | that branch only |
| `loosen` | `<rule>: <what changed>` | `-` | permanent, recorded |
| `loosen` | `@config: <what changed>` | `-` | permanent, recorded |
| `remove` | a rule id | `-` | permanent, recorded |
| `script` | a rule id with a custom detector | `-` | permanent, recorded |

## 9. Functional acceptance criteria

- **EXC-AC1:** Given branch `f` and a new violation in `a.ts`, when a human runs `gauntlet waive a.ts "<reason>"` and commits, then the new-violation check passes for `a.ts`, while the rule's global total is still enforced.
- **EXC-AC2:** Given a waive row for branch `g`, when the gate runs on branch `f`, then that row exempts nothing.
- **EXC-AC3:** Given CI on a detached HEAD with `GITHUB_HEAD_REF=f`, when a waive for `f` exists, then it applies.
- **EXC-AC4:** Given an empty reason, when any exception command runs, then it is rejected with exit 2.
- **EXC-AC5:** Given a rule lowered from `block` to `shadow` with no new `loosen` row, when `check --ci` runs, then it fails and names the rule and the change.
- **EXC-AC6:** Given that loosening plus a new `loosen` row for that rule, when `check --ci` runs, then it passes.
- **EXC-AC7:** Given a `loosen` row that already existed at the merge-base, when a new loosening of that rule happens, then the gate fails.
- **EXC-AC8:** Given a rule file deleted with no new `remove` row, when `check --ci` runs, then it fails.
- **EXC-AC9:** Given `paths` widened from `src/**` to `src/** lib/**`, when `check --ci` runs, then nothing is reported as loosened.
- **EXC-AC10:** Given a commit message that contains a waiver-like trailer, when the gate runs, then nothing is waived.
- **EXC-AC11:** Given a waive row whose branch is not the current one, when `doctor` runs, then the row is listed as stale.
- **EXC-AC12:** Given a PR that adds an exception row, when CI runs, then it comments the new row on the PR.
- **EXC-AC13:** Given `.gauntlet/config` changed so that a gate relaxes (for example `touched` from on to off, or a declared check removed) with no new `loosen @config` row, when `check --ci` runs, then it fails and names the change; and given that change plus a new `gauntlet loosen @config "<what changes>" "<reason>"` row, then it passes.

## 10. Out of scope

- Detecting whether a shell is driven by a human or an agent. The protection is the adapter (AGENT), the PR diff and the CI comment.
- Deleting waive rows automatically when a branch merges. That is deferred; `doctor` lists them meanwhile.

## 11. Dependencies on other FRDs

| FRD | Why |
|---|---|
| FRD-03 Push and CI gate (GATE) | The checks that exceptions relax. |
| FRD-05 Agent integration (AGENT) | Denies agent edits and enforces stop-and-notify. |

## 12. Decisions

Decided by the owner on 2026-10-22, each by accepting the proposed default.

1. **Should merged-branch waivers be removed automatically?** Decision: not in v0.1. `doctor` lists them, and a later version removes them in the CI job on merge.
2. **Should the exception commands refuse to run without a TTY,** as a heuristic against agents? Decision: no. It is unreliable across harnesses, and enforcement belongs to the adapter plus review.
