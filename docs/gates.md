# Gates

## Where gauntlet runs

| Where | Runs | Purpose |
|---|---|---|
| `pre-commit` hook | `stage: commit` rules on staged files | fast feedback, under 5 s |
| `pre-push` hook | `gauntlet check --ci`, plus your declared checks | your guarantee before sending |
| CI | `gauntlet check --ci`, plus whichever declared checks you enable there | catches anyone who skipped the hooks |

**Nothing should be pushed without knowing it passes CI.** That is why pre-push runs the same command CI runs, under the same conditions.

## What `check --ci` verifies

1. **No new violations.** A `block` fingerprint that is absent from the base fails, unless the path is waived.
2. **No rule total rises.**
3. **Touched files go down** (optional). Every changed file must come out with a strictly lower `block` total than it went in with, and every added file must come out at zero.
   - Paying down one violation of any rule is enough.
   - Renames are followed.
   - The gate is **off by default in an existing repo**. Turn it on when you decide to start paying debt.
4. **The baseline is exact.** The committed baseline must equal what the code measures.
5. **No loosening.** These changes fail without a matching exception:
   - a rule removed;
   - a severity lowered;
   - `paths` narrowed or `exclude` widened;
   - a detector changed.
6. **Rule tests pass**, when any rule changed.
7. **Declared checks pass**: tests, build, type-check, … each scoped by path.

Every check runs every time; there is no fail-fast. All violations are reported together, each with its fix line, so you or your agent can fix everything in one pass. Wall time is printed per rule and per check.

**Existing debt never fails the gate by itself.** Only these things fail it:
- a new violation;
- a touched file that did not go down, when you enabled that gate;
- a loosened rule;
- a baseline that lies.

## The base

New and touched are measured against the merge-base with the branch's **target**:
- **In CI**, the target is the PR's target branch.
- **Locally**, it is `git config branch.<name>.gauntletBase`, which you set with `gauntlet base <ref>` or which a stack tool sets for you. Without it, gauntlet uses `origin/<default>`.

Stacked PRs are therefore never charged with the whole stack.

CI must check out the full history. A shallow checkout computes a different diff from the one you ran locally. Reproduce the condition, not just the command.

## Auto-tighten

When a commit lowers the debt, `pre-commit` rewrites `baseline.tsv` and stages it into that same commit. The fix and its lower number always travel together.

## Hooks: coexist, never take over

| Your repo has | gauntlet does |
|---|---|
| husky, lefthook, prek / pre-commit, custom hooks | adds **one line** calling gauntlet inside the existing hook |
| `core.hooksPath` already set | leaves it alone |
| no hooks at all | installs its own `pre-commit` and `pre-push` |

`core.hooksPath` does not travel with a clone. To cover that, onboarding wires `gauntlet install-hooks` into the setup step your project already has (`prepare`, `make setup`, …), so a teammate who clones is protected without remembering.

## CI

Onboarding writes a CI job; GitHub Actions comes first:

```yaml
name: gauntlet
on: pull_request
jobs:
  gauntlet:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - run: .gauntlet/bin/gauntlet check --ci --base "origin/${{ github.base_ref }}"
```

The rules take seconds, so the job runs on every PR without an opt-in label.

Heavy checks such as full test suites run in CI only if you enable them, because CI minutes cost money. Pre-push always runs them.

Without branch protection, a red check does not stop a merge. In that case the job comments the violations and any new exceptions on the PR. Turn branch protection on if you can.

## Performance

- **Commit-time budget: under 5 s.** A slow commit hook is how people learn `--no-verify`. Whole-program detectors therefore run at push only.
- **One linter run feeds every rule that needs it.** In the origin project, one push ran ESLint three times, about 140 s in total.
- **Per-rule timings** show which detector to rewrite.
