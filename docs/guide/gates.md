# Gates

## Where gauntlet runs

| Where | Runs | Purpose |
|---|---|---|
| `pre-commit` hook | `gauntlet check --staged`: `stage: commit` rules on the staged files | fast feedback, under 5 s |
| `pre-push` hook | `gauntlet check --ci`, plus your declared checks | your guarantee before sending |
| CI | `gauntlet check --ci`, plus the declared checks with `ci=on` | catches anyone who skipped the hooks |

**Nothing should be pushed without knowing it passes CI.** That is why pre-push runs the same command CI runs, under the same conditions.

## What `check --ci` verifies

1. **No new violations.** A `block` violation whose fingerprint appears more often than at the base fails, unless its path is waived.
2. **No rule total rises.** The total of a `block` rule that exists at the base must not go up.
3. **Touched files go down** (optional). Every changed file must come out with fewer `block` violations than it went in with. A file that was added must come out at zero. A file with no debt at the base must stay at zero.
   - Paying down one `block` violation in the file is enough.
   - Renames are followed (see [Renames](#renames)).
   - The gate is **off by default in an existing repo**. Turn it on with `touched=on` when you decide to start paying debt.
4. **The baseline is exact.** The committed baseline must equal what the code measures.
5. **No loosening.** These changes fail without a matching exception: a rule removed, a severity lowered, `paths` narrowed or `exclude` widened, `engine` or `detector` changed, a detector file it names changed, or the `format` of a `block` rule changed. The full list is in [Exceptions](exceptions.md#what-counts-as-a-loosening).
6. **Rule tests pass**, when a file under `.gauntlet/rules/` or `.gauntlet/formats/` changed since the base.
7. **Declared checks pass**: tests, build, type-check, … each scoped by path.

Every check runs every time; there is no fail-fast. All violations are reported together, each with its fix line, so you or your agent can fix everything in one pass. Wall time is printed per rule and per check.

The report prints its sections in this order, and only the ones with something to say. On a branch whose base has no baseline yet (onboarding), a `note:` line comes first: `[new]`, `[global]`, `[touched]`, `[baseline]`, `[loosened]`, `[rule-tests]`, `[checks]`, then `[shadow] would have failed` and `[track]`. `[time]` always comes last, before the verdict line, `gauntlet: ok` or `gauntlet: FAIL (<n> problems)`.

A problem is one `[new]` line; one `[global]` rule whose rise its `[new]` lines do not already explain; one `[touched]` line that no `[new]` line explains; the `[baseline]`; one `[loosened]` line; one `[rule-tests]` line; or one failed check. `[shadow]` and `[track]` lines are never problems.

**Existing debt never fails the gate by itself.** Only these things fail it:
- a new violation;
- a rule total that rises;
- a touched file that did not go down, when you enabled that gate;
- a loosened rule;
- a failed rule test or declared check;
- a baseline that lies.

## The base

New and touched are measured against the merge-base of HEAD and the **base**. The first of these that is set wins:
1. `--base <ref>` on the command line (CI passes `origin/<target>`);
2. `branch.<name>.gauntletBase`, which `gauntlet base <ref>` sets;
3. `base=` in `.gauntlet/config`;
4. `origin/HEAD`, the remote's default branch as the clone recorded it;
5. `main`.

An `origin/` base is fetched first, with prompts off. If the fetch fails, gauntlet warns and uses the local ref. A base that does not exist exits 2.

Stacked PRs are therefore never charged with the whole stack.

CI must check out the full history. In a shallow clone that has no common history with the base, gauntlet exits 2 with `shallow clone: fetch full history`. Reproduce the condition, not just the command.

`check --ci` checks what you push, so it refuses a tree with uncommitted changes to tracked files: exit 2, `gauntlet checks what you push; commit or stash first`. Untracked files do not count.

## The commit gate

`pre-commit` runs `check --staged`. It reads the working-tree content of the staged files, and runs only the `stage: commit` rules:
- new `block` violations among the staged files block the commit;
- touched files block the commit when `touched=on`;
- `shadow` and `track` lines are printed, and never block.

It does not check that the baseline is exact, loosening, rule totals or declared checks. Push and CI own those, so a commit can pass that a push then refuses. The first commit of a repo has no `HEAD` to compare with, so it passes with a note.

## Auto-tighten

When a commit lowers the debt, `pre-commit` rewrites `baseline.tsv` and stages it into that same commit. The fix and its lower number always travel together. It starts from the baseline as the index holds it, and it runs only when the commit passes.

It is skipped, with a note, in three cases:
- a staged file also has unstaged changes: `note: partially staged; run gauntlet baseline before pushing`;
- the working-tree `baseline.tsv` has unstaged changes: `note: baseline.tsv has unstaged changes; run gauntlet baseline before pushing`;
- the commit is `git commit <path>`: `note: partial commit by path; run gauntlet baseline before pushing`.

A skipped tighten does not skip the check: new violations still block the commit. Run `gauntlet baseline`, commit the result, and then push.

Two things to know:
- A baseline you raise by hand passes the commit gate, because the commit gate does not check exactness. `check --ci` on push and in CI refuses it.
- Deleting a rule leaves its baseline rows in place until `gauntlet baseline` runs. `check --ci` reports those rows under `[baseline]`, and the removal under `[loosened]` unless you record a `remove` row.

## Renames

`git diff -M` reports a rename when enough of the content is unchanged. When it does, the file's baseline rows move to its new path, in `check --ci` and at commit, so a moved file is not new debt. Limits:
- A move that git reports as a delete plus an add (a move with heavy edits, for example) is new debt at its new path. So is a move over an existing file, which git reports as a modification plus a delete. `waive` is the escape.
- Swapping two files that have debt (`A` ↔ `B`) is new debt at both paths.
- The commit gate checks only `stage: commit` rules, so it does not move the rows of `stage: push` debt. After such a rename, run `gauntlet baseline` before you push: `check --ci` reports the old rows under `[baseline]` until you do.
- On a branch with many renamed or added files, git can skip rename detection when the count passes `diff.renameLimit`. Git's default is 1000. It then prints `warning: exhaustive rename detection was skipped` on stderr, and the renames show as new debt. Raise `diff.renameLimit` with `git config` to keep them.

## Declared checks

Declared checks run your project's own commands. Each is a line in `.gauntlet/config`. The commands below are examples, to be replaced with yours:

```
check.tests=npm test --silent
check.tests.paths=src/ tests/
check.types=npx tsc --noEmit
check.types.ci=on
```

- A check runs when a changed file (against the base, deletions included) starts with one of its `paths`. With no `paths`, it always runs.
- Under `CI=true`, a check runs only when `ci=on`. Locally every check in scope runs. `ci` defaults to `off`, so a heavy check stays out of CI unless you turn it on.
- It runs as `bash -c` from the repo root, with stdin from `/dev/null`.
- A failure prints `<name>  exit <code>` and the last 20 lines of the output, indented. Each failed check is one problem. Its time appears under `[time]` as `check:<name>`.
- A file that a branch moves away counts at its old path, so a check scoped to that path still runs.

Pre-push runs every declared check in scope. CI runs the `ci=on` ones.

## Hooks: coexist, never take over

| Your repo has | gauntlet does |
|---|---|
| husky (`core.hooksPath` is `.husky` or `.husky/_`) | adds the gate to `.husky/pre-commit` and `.husky/pre-push`, creating either file if it is missing |
| lefthook or prek config (`lefthook.*`, `.pre-commit-config.yaml`, `prek.toml`) | prints a snippet for you to paste. It does not edit the config, and `doctor` fails until the snippet is there |
| an existing shell hook, in `.git/hooks` or in a `core.hooksPath` inside the repo | puts the gate first in it, right after the shebang line |
| a `core.hooksPath` shared outside the repo | prints the lines. The directory is not yours to change |
| no hooks at all | creates its own `pre-commit` and `pre-push` |

`core.hooksPath` is never written.

### Where the gate line goes

In a hook gauntlet may edit, the gate goes on the line right after the shebang (line 1 when there is no shebang), in this form:

```sh
.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet
```

It runs before anything your hook does, so no early `exit`, `exec`, line continuation or failing last command can skip it. If the gate passes, your hook runs unchanged and keeps its own exit status. The gate runs first, so your own steps run after it. A formatter in lint-staged, for example, runs after the gate has checked the staged files as they were. A created hook gets the plain form, `.gauntlet/bin/gauntlet check --staged  # gauntlet`.

`install-hooks` prints the line instead of editing a hook it cannot change safely, and you add it by hand as the first command. Those cases are:
- a shebang that is not a shell (`sh`, `bash`, `dash`, `zsh`, `ksh` or `ash`, directly or through `env`);
- CRLF line endings, or a NUL byte in the file;
- a dangling symlink, or a symlink to a file outside the repo;
- a shared hooks directory outside the repo and its git dir.

An existing hook that is not executable gets a warning on stderr, and its mode is never changed. Git ignores a hook without the exec bit, so `doctor` fails until you run `chmod +x`. The exception is husky v9's `.husky/_` layout, which runs the hook through its wrapper.

### What `doctor` checks, and what it does not

`doctor` checks that the gate line is in each hook, in either form, and that the vendored runner loads. It does not check that the gate runs. A gate line that sits after an early `exit` counts as present, and `doctor` says ok. A line that someone appends by hand to the end of an existing hook also counts as present, and `install-hooks` does not move it to the top: it reports `already present`.

Some hook setups have their own quirks:
- **husky v8** runs the hook file a second time through its `husky.sh`. The gate therefore runs twice per commit. It also runs before husky's `HUSKY=0` check, so `HUSKY=0` does not skip it. Both were checked with husky 8.0.3.
- **One script linked as both `pre-commit` and `pre-push`** gets both gate lines. At commit, `check --ci` then refuses every commit with staged changes, because it wants a clean tree. Give each hook its own script.

## CI

Add a CI job by hand. Its one step is the whole gate:

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

The rules take seconds, so the job runs on every PR. Declared checks run here only when they set `ci=on`, because CI minutes cost money. Pre-push runs all of them in scope.

Without branch protection, a red check does not stop a merge. Turn branch protection on if you can. Generating this job during onboarding, and commenting new exceptions on the PR, are planned (IS-02).

## Performance

- **Commit-time budget: under 5 s.** A slow commit hook is how people learn `--no-verify`. Put whole-program detectors at `stage: push`, so they run at push and in CI only.
- **Each rule runs its own detector today.** A linter run shared by several rules is planned (IS-03). In the origin project, one push ran ESLint three times, about 140 s in total.
- **Per-rule timings** show which detector to rewrite. The report's `[time]` section lists them. `status` lists the commit rules at or over the budget as `slow:`, from the times of the last commit run, which the commit gate keeps in `.git/gauntlet-time.tsv`. That file is local and never committed.
- **The budget warning says 5 s.** The `[slow]` line keeps saying `over the 5 s commit budget` even when `GAUNTLET_COMMIT_BUDGET_MS` is set. The override changes when the line appears, not its text.
