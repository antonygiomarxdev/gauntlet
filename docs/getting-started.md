# Getting started

> gauntlet is pre-release. This page describes the v0.1 interface. Track progress in the [changelog](../CHANGELOG.md).

## Requirements

- `git` and `bash`. On Windows, use the Git Bash that ships with git.
- `awk` (POSIX). It ships everywhere git does.
- `ast-grep` and `rg`, but only if one of your rules uses them. `gauntlet doctor` tells you what is missing and how to install it.

No Node, Python or compiler is needed for gauntlet itself.

## 1. Install

### With an agent

Paste this into your agent (Claude Code, Codex, Command Code or any other):

```text
Install gauntlet from https://github.com/antonygiomarxdev/gauntlet and onboard this repository.
```

The agent reads `skills/gauntlet/SKILL.md` (ships with v0.1) and does the rest.

### By hand

```sh
git clone --depth 1 --branch v0.1.0 https://github.com/antonygiomarxdev/gauntlet ~/.gauntlet
cd your-repo
~/.gauntlet/bin/gauntlet install
```

`install` vendors two things into your repo:
- the runner, as `.gauntlet/bin/gauntlet`;
- the skill, as `.agents/skills/gauntlet/` (with a symlink for Claude Code).

Your repo is then self-contained: a teammate who clones it gets gauntlet without installing anything.

## 2. Onboard

Ask your agent to run the gauntlet **onboard** skill. It works in seven steps:

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
6. **Install** the hooks next to your existing ones, plus the CI job and a block in `AGENTS.md`.
7. **Record** everything it inferred and everything you answered in `.gauntlet/ONBOARDING.md`.

Nothing is activated without your yes. New `block` rules start in shadow. The touched-file gate stays off until you turn it on.

## 3. Live with it

```sh
gauntlet status          # debt per rule, worst files, trend, shadow rules due for promotion
gauntlet check --ci      # exactly what CI runs
gauntlet fix             # apply linter / ast-grep autofixes
gauntlet promote <id>    # shadow → block
gauntlet doctor          # tools present, hooks wired, baseline exact, config valid
```

When the gate blocks you, the output names the file, the line, the rule and the fix. If the debt really cannot be paid in this branch, a human runs:

```sh
gauntlet waive src/legacy/report.ts "rewrite scheduled in #123; this PR only renames"
```

Then commit as usual.

## 4. Grow the rules

- **When you notice a pattern:** ask the agent to `add-rule`.
- **When the agent notices one**, for example because you corrected it twice for the same thing, it runs `propose-rule`, with a working detector and the current count. You decide.
