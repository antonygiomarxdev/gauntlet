# Gates

## Where gauntlet runs

| Where | Runs | Purpose |
|---|---|---|
| `pre-commit` hook | `gauntlet check --staged`: `stage: commit` rules on the staged files | fast feedback, under 5 s |
| `pre-push` hook | `gauntlet check --ci --pre-push`, plus your declared checks | your guarantee before sending |
| CI | `gauntlet check --ci`, plus the declared checks with `ci=on` | a second run of the same gate, for a push that skipped the hooks. It runs the runner the branch carries, so it cannot stop a change to that runner: see [who CI trusts](#who-ci-trusts) |

**Nothing should be pushed without knowing it passes CI.** That is why pre-push runs the same gate CI runs, from the same tree: the branch's own vendored runner. Local and CI judge the same way. Pre-push adds one check of its own, that you push what it checked: see [The pre-push gate](#the-pre-push-gate).

## What `check --ci` verifies

1. **No new violations.** A `block` violation whose fingerprint appears more often than at the base fails, unless its path is waived.
2. **No rule total rises.** The total of a `block` rule that exists at the base must not go up.
3. **Touched files go down** (optional). Every changed file must come out with fewer `block` violations than it went in with. A file that was added must come out at zero. A file with no debt at the base must stay at zero.
   - Paying down one `block` violation in the file is enough.
   - Renames are followed (see [Renames](#renames)).
   - The gate is **off by default in an existing repo**. Turn it on with `touched=on` when you decide to start paying debt.
4. **The baseline is exact.** The committed baseline must equal what the code measures.
5. **No loosening.** These changes fail without a matching exception: a rule removed, a severity lowered, `paths` narrowed or `exclude` widened, `engine` or `detector` changed, a detector file it names changed, the `format` of a `block` rule changed, or `.gauntlet/config` loosened (a different `base=`, `touched` turned off, a declared check removed, its `ci` turned off, its `paths` narrowed, or its command changed). The full list is in [Exceptions](exceptions.md#what-counts-as-a-loosening).
6. **Rule tests pass**, when a file under `.gauntlet/rules/` or `.gauntlet/formats/` changed since the base.
7. **Declared checks pass**: tests, build, type-check, … each scoped by path.

Every check runs every time; there is no fail-fast. All violations are reported together, each with its fix line, so you or your agent can fix everything in one pass. Wall time is printed per rule and per check.

The report prints its sections in this order, and only the ones with something to say: `[new]`, `[global]`, `[touched]`, `[baseline]`, `[loosened]`, `[rule-tests]`, `[checks]`, then `[shadow] would have failed` and `[track]`. `[time]` always comes last, before the verdict line, `gauntlet: ok` or `gauntlet: FAIL (<n> problems)`.

`note:` lines are not problems. Two come before `[new]`: `note: the vendored runner changed in this branch (.gauntlet/bin or .gauntlet/lib differ from the base); review it`, and, on a branch whose base has no baseline yet (onboarding), `note: no baseline at base; new, global, shadow and track checks skipped`. A loosening that an exception row covers prints `note: loosened <rule>: <what>; covered by "<reason>"` just before `[loosened]`.

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

`master` is not in the list. A repo whose default branch is `master` resolves it only through `origin/HEAD`; where that is not set, put `base=` in `.gauntlet/config` (every branch and clone) or run `gauntlet base <ref>` (this branch, this clone).

`gauntlet base <ref>` writes `branch.<name>.gauntletBase` into the clone's git config. That is local state: it is not committed, a fresh CI checkout does not have it, and CI's `--base` beats it. Use `base=` for a base the whole team shares.

An `origin/` base is fetched first, with prompts off. If the fetch fails, gauntlet warns (`gauntlet: fetch of <ref> failed; using the local ref`) and uses the local ref. A base that does not exist exits 2, and the message says how to set one: `gauntlet: unknown ref: <ref>; set base=<ref> in .gauntlet/config (all branches), or run gauntlet base <ref> (this branch only)`. For a ref given with `--base`: `gauntlet: base <ref> given with --base does not resolve`.

A branch can edit `base=` itself, for example to `HEAD`, and then nothing differs from its own base. So a changed `base=` is judged twice: against the selected base, and against the base the run would pick without any `base=` (items 1, 2, 4 and 5 above). That second base is fetched the same way. A layout where this asks for an exception row is described under [Exceptions](exceptions.md#a-changed-base-and-the-default-branch).

Stacked PRs are therefore never charged with the whole stack.

CI must check out the full history. In a shallow clone that has no common history with the base, gauntlet exits 2 with `shallow clone: fetch full history`. Reproduce the condition, not just the command.

`check --ci` checks what you push, so it refuses a tree with uncommitted changes to tracked files: exit 2, `gauntlet checks what you push; commit or stash first`. Untracked files do not count.

## The commit gate

`pre-commit` runs `check --staged`. It reads the working-tree content of the staged files, and runs only the `stage: commit` rules:
- new `block` violations among the staged files block the commit;
- touched files block the commit when `touched=on`;
- `shadow` and `track` lines are printed, and never block.

It does not check that the baseline is exact, loosening, rule totals or declared checks. Push and CI own those, so a commit can pass that a push then refuses. The first commit of a repo has no `HEAD` to compare with, so it passes with a note.

## The pre-push gate

Git sends a `pre-push` hook one line per ref it is about to push, on stdin: `<local ref> <local sha> <remote ref> <remote sha>`. `check --ci --pre-push` reads those lines before it checks anything. gauntlet judges the checked-out commit, so a push of any other commit to a branch is refused with exit 1:

```
gauntlet checks the checked-out branch; check out <branch> and push again
```

`<branch>` is the local branch that is being pushed. When the local ref is not a branch (`HEAD~1`, a sha), the line is `gauntlet checks the checked-out commit; check out the commit you are pushing and push again`. Every offending ref is listed.

- **Refused:** a pushed `refs/heads/*` ref, or a Gerrit `refs/for/*` ref, whose local commit is not HEAD.
- **Skipped:** a delete (git sends an all-zero local sha) and every ref outside those two namespaces: tags, notes, `refs/pull/*`. The gate still judges HEAD for such a push.
- **Not read:** stdin that is a terminal, or empty. HEAD is judged as always. A line with fewer than four fields is not git's: `gauntlet: unexpected pre-push input`, exit 2.
- `git push --no-verify` skips the hook, as it does for any hook. CI is the backup for that.

### The hook line

The hook must hand the same stdin to the gate and to the commands your own hook runs after it (`git lfs pre-push` reads the ref lines too). So the line that `install-hooks` writes copies stdin to a temp file, runs the gate on it, gives stdin back as that file, and removes it. This is the line, as one line, in a created hook:

```sh
_gauntlet_in=$(mktemp) || { echo "gauntlet: cannot create a temp file; check TMPDIR" >&2; exit 2; }; [ -t 0 ] || cat >"$_gauntlet_in" || { rm -f "$_gauntlet_in"; echo "gauntlet: cannot buffer git's stdin; check TMPDIR" >&2; exit 2; }; .gauntlet/bin/gauntlet check --ci --pre-push <"$_gauntlet_in" || { _gauntlet_rc=$?; rm -f "$_gauntlet_in"; exit "$_gauntlet_rc"; }; [ -t 0 ] || exec <"$_gauntlet_in" || { rm -f "$_gauntlet_in"; exit 2; }; rm -f "$_gauntlet_in"  # gauntlet
```

It fails closed. No temp file: `gauntlet: cannot create a temp file; check TMPDIR`, exit 2. Stdin cannot be copied: `gauntlet: cannot buffer git's stdin; check TMPDIR`, exit 2. A failing gate: the hook exits with the gate's status and removes the file. Stdin cannot be handed back: the hook stops (status 2 in dash, 1 in the POSIX modes of bash, ash and zsh). A terminal on stdin is not read and is kept for your commands.

Limits:
- **prek** runs hooks with stdin on `/dev/null`, so a branch that is not checked out cannot be refused there. The gate judges the checked-out branch, as it would without `--pre-push`.
- **lefthook** passes stdin to a command only with `use_stdin: true`. `doctor` fails a lefthook pre-push command without it, and the snippet `install-hooks` prints has it. Any other hook runner has to pass git's stdin to the pre-push command, or the gate judges the checked-out branch whatever git pushes.
- A hook run by hand from a pipe that never closes blocks on it, waiting for the end of the input. From a terminal it does not; from a script, use `< /dev/null`.
- A push interrupted during the gate (Ctrl-C), or a process killed between `mktemp` and the end of the line, can leave the temp file (`mktemp` names it `tmp.` and random characters) in `$TMPDIR`. It holds only git's ref lines.
- An old vendored runner under this hook line does not know `--pre-push` and prints its own old usage, `gauntlet: usage: gauntlet check --ci [--base <ref>]`, with exit 2. Run `gauntlet install` from a current checkout, which re-vendors the runner.

## Auto-tighten

When a commit lowers the debt, `pre-commit` rewrites `baseline.tsv` and stages it into that same commit. The fix and its lower number always travel together. It starts from the baseline as the index holds it, and it runs only when the commit passes.

It is skipped, with a note, in four cases:
- a staged file also has unstaged changes: `note: partially staged; run gauntlet baseline before pushing`;
- the working-tree `baseline.tsv` has unstaged changes: `note: baseline.tsv has unstaged changes; run gauntlet baseline before pushing`;
- the commit is `git commit <path>`: `note: partial commit by path; run gauntlet baseline before pushing`;
- `baseline.tsv` is not in the index, for example because it was removed from it: `note: baseline.tsv is not in the index; nothing tightened`.

A skipped tighten does not skip the check: new violations still block the commit. Run `gauntlet baseline`, commit the result, and then push.

Two things to know:
- A baseline you raise by hand passes the commit gate, because the commit gate does not check exactness. `check --ci` on push and in CI refuses it.
- Deleting a rule leaves its baseline rows in place until `gauntlet baseline` runs. `check --ci` reports those rows under `[baseline]`, and the removal under `[loosened]` unless you record a `remove` row.

## Renames

`git diff -M` reports a rename when enough of the content is unchanged. When it does, the file's baseline rows move to its new path, in `check --ci` and at commit, so a moved file is not new debt. That includes the rows of `stage: push` rules. Limits:
- A move that git reports as a delete plus an add (a move with heavy edits, for example) is new debt at its new path. So is a move over an existing file, which git reports as a modification plus a delete. `waive` is the escape.
- Swapping two files that have debt (`A` ↔ `B`) is new debt at both paths.
- The commit gate measures only `stage: commit` rules. Besides moving the rows of a renamed file, it never changes a `stage: push` row. After you edit a line that carries `stage: push` debt, run `gauntlet baseline` before you push: `check --ci` reports the stale row under `[baseline]` until you do.
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
| husky (`core.hooksPath` is `.husky` or `.husky/_`) | puts the gate first in `.husky/pre-commit` and `.husky/pre-push`, creating either file if it is missing |
| lefthook or prek config (`lefthook.*`, `.pre-commit-config.yaml`, `prek.toml`) | prints a snippet for you to paste. It does not edit the config, and `doctor` fails until the snippet is there. For lefthook the pre-push command also needs `use_stdin: true` |
| an existing shell hook, in `.git/hooks` or in a `core.hooksPath` inside the repo | puts the gate first in it, right after the shebang line |
| one script linked as both `pre-commit` and `pre-push` | prints two guarded blocks to add by hand: one line cannot be right for both hooks |
| a `core.hooksPath` shared outside the repo | prints the guarded lines, `if [ -d .gauntlet ]; then <gate>; fi`. The directory is not yours to change |
| no hooks at all | creates its own `pre-commit` and `pre-push` |

`core.hooksPath` is never written.

### Where the gate line goes

In a hook gauntlet may edit, the gate goes on the line right after the shebang (line 1 when there is no shebang), in this form:

```sh
.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet
```

The pre-push hook gets the buffering line shown [above](#the-hook-line) in the same place.

It runs before anything your hook does, so no early `exit`, `exec`, line continuation or failing last command can skip it. If the gate passes, your hook runs unchanged and keeps its own exit status. The gate runs first, so your own steps run after it. A formatter in lint-staged, for example, runs after the gate has checked the staged files as they were. A created hook gets the plain form, `.gauntlet/bin/gauntlet check --staged  # gauntlet`.

A line that ends in `# gauntlet` and runs the gate of its stage is gauntlet's, and a hook should have exactly one. `install-hooks` never deletes a line from a hook. It says what it did:
- `already present in <file>`: the one line is the current form;
- `updated gauntlet line in <file>`: the hook had one marked line that differed from the current form, and it was replaced where it stood;
- `added gauntlet line to <file>` and `created <file>`.

A hook with two or more marked lines is not edited, because deleting a line can break the hook around it (the only command of an `if`, a function body) and can delete a command of yours that happens to end in `# gauntlet`. `install-hooks` prints what it found and the current line, and you keep one line, in the current form, and remove the others by hand (see below).

`install-hooks` overwrites a marked line you customised, for example one with `--base origin/develop` added. Put the base in `base=` of `.gauntlet/config` instead. A commented-out line, in a hook or in a hook manager's config, counts for nothing.

### When install-hooks only prints

`install-hooks` prints the line instead of editing a hook it cannot change safely, and leaves the edit to you: the gate line goes in as the first command. It exits 0 in these cases; `doctor` is what fails until the hook is right. Those cases are:
- a shebang that is not a shell (`sh`, `bash`, `dash`, `zsh`, `ksh` or `ash`, directly or through `env`);
- CRLF line endings, or a NUL byte in the file;
- a dangling symlink, or a symlink to a file outside the repo;
- a shared hooks directory outside the repo and its git dir;
- one script that serves both hooks;
- a hook with two or more lines ending in `# gauntlet`.

The words say which edit is needed. `ACTION NEEDED: add to <file>:` when the hook has no gauntlet line; `ACTION NEEDED: replace the line ending in "# gauntlet" in <file> with:` when it has one that differs from the current form; `gauntlet: <file> has N lines ending in "# gauntlet" (lines a, b, ...); keep one, the current form, and remove the others` when it has several, with the current line after it. In a shared hooks directory the advice is printed on every run, even for a line that is already there, and `doctor` says whether it is. A hook that cannot be written at all (permissions) is an error, `gauntlet: cannot write <path>: <reason>; fix the permissions or add the line by hand`, and the exact lines follow on stderr, led by a shebang when the file is new.

In a shared hooks directory the guarded line is the only form `doctor` accepts. Where there is no `.gauntlet/` directory, it does nothing, so other repos sharing the directory are not blocked. Where `.gauntlet/` exists and `.gauntlet/bin/gauntlet` is missing or not executable, it fails the commit or push loudly, as CI would.

The line calls `.gauntlet/bin/gauntlet` from the repo root, so `install-hooks` writes no hook where that is not an executable file. It exits 2 with `gauntlet: no runner at <path>/.gauntlet/bin/gauntlet; run gauntlet install first`, or `gauntlet: runner at <path> is not executable; run chmod +x '<path>'`. For a layout where it only prints, it warns with the same words. Running `gauntlet install` from the vendored copy gives a runner without the exec bit its mode back and says `updated mode of .gauntlet/bin/gauntlet; commit the mode change: git add --chmod=+x .gauntlet/bin/gauntlet`.

An existing hook that is not executable gets a warning on stderr, and its mode is never changed. Git ignores a hook without the exec bit, so `doctor` fails until you run `chmod +x`. The exception is husky v9's `.husky/_` layout, which runs the hook through its wrapper.

### What `doctor` checks, and what it does not

`doctor` checks that each hook holds exactly one gauntlet line and that it is the current form of its stage; that a lefthook pre-push command has `use_stdin: true`; and that the vendored runner is complete and loads. It checks that a gate line is present, not that it is reached. A current gate line that sits after an early `exit`, or inside a here-doc, counts as present, and `doctor` says ok. A line that someone appends by hand to the end of an existing hook also counts as present, and `install-hooks` does not move it to the top: it reports `already present`. The full list is in the [reference](reference.md#doctor).

Some hook setups have their own quirks:
- **husky v8** runs the hook file a second time through its `husky.sh`. The gate therefore runs twice per commit. It also runs before husky's `HUSKY=0` check, so `HUSKY=0` does not skip it. Both were checked with husky 8.0.3.
- **One script linked as both `pre-commit` and `pre-push`** cannot take one gate line: at commit, `check --ci` would refuse every commit with staged changes, because it wants a clean tree. `install-hooks` leaves such a script alone and prints the lines to add inside `if [ "${0##*/}" = pre-commit ]; then … fi` and the same for `pre-push`. `doctor` checks that each gate sits inside the block of its own hook. A block that holds a bare `fi` of its own ends the guard early and is not recognised. Or give each hook its own script.

To remove gauntlet from a repo, see [Uninstall](reference.md#uninstall).

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

Run the job on `pull_request`, never on `pull_request_target`. `pull_request_target` runs in the context of the base repository, with its secrets and a token that can write, even for a pull request from a fork. The gate runs code from the pull request: the vendored runner, the detector commands in the rules, the declared checks. Under `pull_request_target` that code gets the base repository's access.

### Who CI trusts

This job runs the runner the branch carries, `.gauntlet/bin` and `.gauntlet/lib`, as the hooks do. That is deliberate: local and CI must judge the same way, or a push would pass the hook and fail in CI. The price is a limit. A runner cannot judge a change to itself, so a pull request that edits the runner can make its own run pass. gauntlet cannot close that with the runner alone.

What it does is say so. When `.gauntlet/bin` or `.gauntlet/lib` differ from the base, `check --ci` prints this, in the hook and in CI:

```
note: the vendored runner changed in this branch (.gauntlet/bin or .gauntlet/lib differ from the base); review it
```

It is a note, not a failure, and no exception row clears it. It is skipped when the base has no runner, as on the first install. Read it, and put the directory under review. With a `CODEOWNERS` file, GitHub asks the owners of the changed paths to review the pull request, and branch protection can require their approval:

```
# .github/CODEOWNERS
/.gauntlet/ @your-team
```

#### Optional: judge the PR with the base's runner

To make a pull request unable to vouch for its own runner, run the runner the base branch has against the pull request's tree:

```yaml
name: gauntlet
on: pull_request
jobs:
  gauntlet:
    runs-on: ubuntu-latest
    env:
      BASE: ${{ github.base_ref }}
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: Take the runner from the base
        run: |
          mkdir -p "$RUNNER_TEMP/g"
          git archive "origin/$BASE" .gauntlet/bin .gauntlet/lib | tar -x -C "$RUNNER_TEMP/g"
      - name: Run the gate with it
        run: |
          "$RUNNER_TEMP/g/.gauntlet/bin/gauntlet" check --ci --base "origin/$BASE"
```

The cost: this CI run no longer matches the hook. A pull request that upgrades gauntlet is judged by the old runner in CI, and can pass locally and fail only there. On the pull request that first installs gauntlet the base has no runner, so the step that takes it fails: use the default job for that one. The `note:` about a changed runner still prints.

## Performance

- **Commit-time budget: under 5 s.** A slow commit hook is how people learn `--no-verify`. Put whole-program detectors at `stage: push`, so they run at push and in CI only.
- **Each rule runs its own detector today.** A linter run shared by several rules is planned (IS-03). In the origin project, one push ran ESLint three times, about 140 s in total.
- **Per-rule timings** show which detector to rewrite. The report's `[time]` section lists them. `status` lists the commit rules at or over the budget as `slow:`, from the times of the last commit run, which the commit gate keeps in `.git/gauntlet-time.tsv`. That file is local and never committed.
- **The budget warning** is a `[slow]` line in the commit gate's report when the run took longer than the budget: `[slow] over the 5 s commit budget`. `GAUNTLET_COMMIT_BUDGET_MS` changes the budget, and the line then names it (`over the 1500 ms commit budget`). It only warns and never changes the exit code.
