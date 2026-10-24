# Exceptions

Some debt can't be paid in this branch. gauntlet records that decision in one place: a row in `.gauntlet/exceptions.tsv`, written by a command.

## The file

`.gauntlet/exceptions.tsv`, versioned, one row per exception:

```
type	target	reason	date	branch
waive	src/legacy/report.ts	rewrite scheduled in #123; this PR only renames	2026-10-22	feat/rename-reports
loosen	raw-status: exclude += src/generated/**	generated code, regenerated on build	2026-10-22	-
```

| Type | Target | Lifetime |
|---|---|---|
| `waive` | one path | applies on its own branch only. The row stays in the file. On any other branch `doctor` lists it as stale, and a stale waiver never fails. |
| `loosen` | a rule, plus what changes. `@config` stands for `.gauntlet/config` | permanent, recorded |
| `remove` | a rule | permanent, recorded |
| `script` | a custom detector | permanent, recorded. Added by hand: no command writes it. |

A path waiver exempts that path from the new-violation and touched-file checks. The rule's total still applies, so a waiver cannot hide a rise in the rule's total. A waived file that adds a violation still fails `[global]`.

## Written by command

```sh
gauntlet waive  <path> "<reason>"
gauntlet loosen <rule> "<what changes>" "<reason>"
gauntlet loosen @config "<what changes>" "<reason>"
gauntlet remove <rule> "<reason>"
```

- Each command appends one row, dated today. Commit the file on the branch: `check --ci` refuses a dirty tree, and a `loosen` or `remove` row counts only once it is in the base-to-HEAD history.
- All three exit 2 without a `.gauntlet/` directory (`gauntlet: no .gauntlet/ directory; run gauntlet install`). `loosen` and `remove` also exit 2 for a rule that exists nowhere (`gauntlet: no rule <id>`): in the working tree, in HEAD or at the merge-base. A case file such as `todo.bad.md` is not a rule. `remove @config` is refused: `gauntlet: no rule @config`.
- The runner does not check who wrote a row. A row written by hand works the same way, so review the diff of `exceptions.tsv` like any other change.
- An agent may **propose** the exact command, with its reason. The runner cannot stop an agent from writing a row. Keeping agents from writing rows is the skill's job and the Claude Code adapter's, and the PR diff and a CI comment on each new row are planned (IS-02; FRD-04 §4, rule 10).

## What counts as a loosening

When `check --ci` finds one of these since the merge-base, the rule needs a `loosen` row. A rule file deleted needs a `remove` row.
- severity lowered (`block` → `shadow` → `track`);
- `paths` narrowed, or `exclude` widened;
- `engine` or `detector` changed, or a file the detector names changed;
- for a `block` rule, its `format` changed, or its format file changed.

`.gauntlet/config` is judged the same way, under the name `@config`: see [Config changes](#config-changes).

A `loosen` row must be new on the branch. A row already in the merge-base does not count. One row covers every loosening of its rule found since the merge-base, not only the one its text describes. The text is a note for reviewers.

A loosening that a row covers passes, and `check --ci` says so, locally and in CI: `note: loosened <rule>: <what>; covered by "<reason>"`. A change in a rule that did not exist at the base is never a loosening.

## Config changes

`.gauntlet/config` decides what the gate checks, so loosening it is loosening a rule. These changes need a `loosen` row whose rule is `@config`, and the report names each one under `[loosened]` as `@config  <change>`:

| Change | Reported as |
|---|---|
| `base=` set, changed or removed, so that the run selects another base | `base (unset) → develop`, `base main → develop` |
| `touched` from on to off. A deleted `touched=on` line counts, because the default is off | `touched on → off` |
| a declared check removed | `check <name> removed` |
| a declared check's `ci` from on to off. A deleted `.ci=on` line counts, because the default is off | `check <name> ci on → off` |
| a declared check's `paths` narrowed: an old prefix that no new prefix covers (`src/api/` becoming `src/` is wider, `src/` becoming `src/api/` is narrower), or a check that ran always and now has a list | `check <name> paths narrowed: <prefix>`, `check <name> paths narrowed: all files → <paths>` |
| a declared check's command changed | `check <name> command changed` |

Not loosening: a check added, `ci` turned on, `paths` widened, `touched` turned on, and comments, blank lines, spacing or CRLF. A `stage:` change in a rule file is not a loosening either. A rule that moves from `commit` to `push` leaves the commit hook, but it still runs at push and in CI, where it blocks as before.

```sh
gauntlet loosen @config "touched off while we migrate" "agreed in review"
```

One `@config` row covers every config change found since the merge-base, as a row for a rule does.

## A changed base and the default branch

A branch can edit `base=` to aim the run at itself (`base=HEAD`), and then no comparison shows anything. So `check --ci` judges a changed `base=` against two bases: the one the run selected, and the one it would have selected without any `base=` (the `--base` flag, `branch.<name>.gauntletBase`, `origin/HEAD`, then `main`; see [the base](gates.md#the-base)). If either comparison finds a change, it is a loosening. The second base is fetched like the first; if that fetch fails, gauntlet warns and uses the local ref.

The second comparison can ask for a row where CI would not. Take a repo whose default branch is `main`, with `base=develop` committed on `develop` only, and a feature branch cut from `develop`. CI passes `--base origin/develop`, and `develop` already has the line, so CI sees no change. A local `check --ci` cannot know which branch the PR will target, so it also compares with `origin/main`, which lacks the line:

```
[loosened]
  @config  base (unset) → develop
gauntlet: base= is also judged against origin/main (the base without it); add a row with gauntlet loosen @config "base (unset) → develop" "<reason>", or run gauntlet base develop on this branch
```

That is deliberate: a local run that is stricter than CI costs one command, and a looser one would pass what CI refuses. There are two ways out, and the message names both. Record the base with `gauntlet loosen @config "base=develop" "features are cut from develop"` and commit the row. Or run `gauntlet base develop` on the branch, which makes `develop` the selected base, and so the default one too. The extra line is not counted as a problem.

`gauntlet base <ref>` writes `branch.<name>.gauntletBase` into the clone's git config. gauntlet trusts it as local state, like the developer's own checkout: a local run honours it, and CI, which has no such setting, judges with its `--base`.

## Which detector files the check sees

A rule's `detector` is a command, and a script it runs can change without the rule file changing. So the check reads the detector the way the shell cuts a command line, with nothing expanded, and judges every word that names a tracked file by its content at the merge-base and at HEAD: `detector file <path> changed`, or `format file <path> changed`.

How the words are cut:
- A word ends at an unquoted space, tab, newline, or one of `; & | < > ( )`. So `tools/find.sh;true`, `(tools/find.sh)` and `x=$(bash tools/find.sh)` all name `tools/find.sh`.
- `'single quotes'` keep everything. `"double quotes"` keep everything but a backslash before `"`, `\`, `$` or a backtick. Outside quotes a backslash makes the next character literal. The quotes come off, so `bash "tools/my script.sh"` names `tools/my script.sh`.
- A word that starts with `-` and holds `=` (`--pre=tools/pre.sh`) is also read as the text after the first `=`. An option with no `=`, and a word with a `{` (`{files}`), name nothing.
- For `engine: ast-grep` the rule file is one word, spaces included.
- A directory is not a file. A symlink is judged by its own text and by the file it points to inside the repo, up to ten links deep; a link that leaves the repo is judged by its text alone.

What it does not follow. A change in any of these passes without a row, so keep such detectors simple, or review them by hand:
- `cd dir && ./x`: the word `./x` is read from the repo root, not from `dir`;
- brace expansion (`tools/{a,b}.sh`), `$VAR`, globs and `~`;
- a quoted `-c` string (`bash -c "bash tools/find.sh"`) and backtick substitution: a quoted string is one word, and is not cut again;
- helpers that a script `source`s or calls, and scripts inside a submodule (the gitlink hides the path);
- `.ignore` and `.rgignore` files that a search tool reads;
- a mode change (`chmod`) and a directory component that is a symlink.

## Waivers

- The path must exist in git or in the working tree, and it is matched literally. A `./` prefix, a trailing `/` and globs are refused.
- A waiver needs a branch. It is refused on a detached HEAD. In CI the branch is `GITHUB_HEAD_REF`. The commit gate applies no waivers on a detached HEAD.
- The reason must not be empty, and must not contain a tab or a newline. The same goes for the reasons of `loosen` and `remove`.

## Why not commit trailers?

The hand-built version of this process used a commit trailer (`Standards-waiver: <path> — <reason>`). Agents could write it themselves, so they did: up to 17 % of a week's commits carried one. Trailers also clutter history, and some teams forbid them outright. A file is reviewable, diffable and protectable. A trailer is none of those.
