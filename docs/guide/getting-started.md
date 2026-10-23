# Getting started

> gauntlet is pre-release. The runner works by hand today. The agent skill is planned, so the onboarding steps below are manual for now. Track progress in the [changelog](../../CHANGELOG.md). Every command and flag is in the [command reference](reference.md).

## Requirements

- `git` and `bash`. bash 3.2 (the one macOS ships) is supported. Windows is not in the test matrix yet, so Git Bash is untested.
- `awk`, POSIX only. gauntlet uses no GNU-only awk features.
- `ast-grep` and `rg`, but only if one of your rules uses them. `gauntlet doctor` tells you what is missing and how to install it.

No Node, Python or compiler is needed for gauntlet itself. gauntlet's own test suite runs on Ubuntu and on macOS with the system bash 3.2 in CI (see `.github/workflows/test.yml`).

## 1. Install

### With an agent (planned)

The agent skill (`skills/gauntlet/SKILL.md`) is planned for IS-02. It does not exist yet, so there is no agent install path today.

### By hand

The clone must be a checkout that has `bin/gauntlet`. The runner is not on `main` until it is merged, so clone the branch that has it.

```sh
git clone --depth 1 https://github.com/antonygiomarxdev/gauntlet ~/.gauntlet
cd your-repo
~/.gauntlet/bin/gauntlet install
```

`install` copies the runner from the checkout it runs in into your repo, as two folders:
- `.gauntlet/bin/`, with the `gauntlet` script;
- `.gauntlet/lib/`, with its libraries and the built-in output formats.

It then creates what is missing (`.gauntlet/rules/`, an empty `baseline.tsv`, `exceptions.tsv` with its header, and `config` with `touched=off`), and adds the gate to your hooks. Running it again replaces both folders, so a later install upgrades the runner. Anything you put inside them by hand is removed.

You can also link the script onto your `PATH` (`ln -s ~/.gauntlet/bin/gauntlet ~/bin/gauntlet`) and run `gauntlet install` from your repo. The link is followed back to the checkout.

Commit `.gauntlet/`, so teammates and CI run the same runner. The hooks that `install` writes into `.git/hooks` are not shared by a clone. If teammates need them, add `gauntlet install-hooks` to the setup step your project already has (`prepare`, `make setup`, …). See [hooks](gates.md#hooks-coexist-never-take-over).

## 2. Onboard

Planned: the **onboard** skill (IS-02) works in seven steps:

1. **Detect** the stack, languages, linters, existing hooks, test and build commands, and the architecture. In an empty repo, it asks you instead.
2. **Research** each technology's own guidance, from primary sources only.
3. **Propose** rules one at a time, each numbered, each with:
   - why it matters;
   - its source;
   - the current count;
   - the worst files;
   - the detector;
   - the fix hint.

   You accept, adjust or reject each one, and pick its severity.
4. **Write** the detectors and their test cases, then measure the baseline.
5. **Confirm** which project checks (tests, build, type-check) pre-push and CI should run.
6. **Install** the hooks next to your existing ones, plus the CI job.
7. **Record** what it inferred and what you answered.

Until the skill exists, do the same steps by hand:

1. **Write the rules.** One file per rule, in `.gauntlet/rules/<id>.md`, with its detector and fix hint. Start with `severity: shadow`. See [Rules & detectors](rules-and-detectors.md).
2. **Write the cases.** `<id>.bad.<ext>` must be flagged and `<id>.good.<ext>` must not. Run `gauntlet test-rules`.
3. **Measure the baseline.** Only tracked files are measured, so `git add` the new files first. Then run `gauntlet baseline`, `git add .gauntlet/baseline.tsv`, and commit.
4. **Check the setup.** `gauntlet doctor` should print only `ok` lines. A stale waiver shows as `stale waive` and never fails.
5. **Declare the project checks** (tests, build, type-check) in `.gauntlet/config`. See [Gates](gates.md#declared-checks).
6. **Add the CI job.** See [Gates](gates.md#ci).
7. **Promote** each shadow rule with `gauntlet promote <id>` once `gauntlet status` lists it as due.

Nothing blocks until its rule is `block`. The touched-file gate stays off until you set `touched=on`.

## 3. Live with it

```sh
gauntlet status          # debt per rule, worst files, shadow rules due for promotion
gauntlet check --ci      # exactly what CI runs
gauntlet promote <id>    # shadow → block
gauntlet doctor          # tools present, hooks wired, baseline exact, config valid
```

When the gate blocks you, the output names the file, the line, the rule and the fix. If the debt really cannot be paid in this branch, a human runs:

```sh
gauntlet waive src/legacy/report.ts "rewrite scheduled in #123; this PR only renames"
```

Then commit `.gauntlet/exceptions.tsv` on the same branch. A waiver applies only on its own branch. See [Exceptions](exceptions.md).

## 4. Grow the rules

- **When you notice a pattern:** write the rule by hand, following [Writing a good rule](rules-and-detectors.md#writing-a-good-rule). An `add-rule` step in the agent skill is planned.
- **When an agent notices one**, for example because you corrected it twice for the same thing, a `propose-rule` step is planned. Until then, write the rule yourself.
