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
| `loosen` | a rule, plus what changes | permanent, recorded |
| `remove` | a rule | permanent, recorded |
| `script` | a custom detector | permanent, recorded. Added by hand: no command writes it. |

A path waiver exempts that path from the new-violation and touched-file checks. The rule's total still applies, so a waiver cannot hide a rise in the rule's total. A waived file that adds a violation still fails `[global]`.

## Written by command

```sh
gauntlet waive  <path> "<reason>"
gauntlet loosen <rule> "<what changes>" "<reason>"
gauntlet remove <rule> "<reason>"
```

- Each command appends one row, dated today. Commit the file on the branch: `check --ci` refuses a dirty tree, and a `loosen` or `remove` row counts only once it is in the base-to-HEAD history.
- The runner does not check who wrote a row. A row written by hand works the same way, so review the diff of `exceptions.tsv` like any other change.
- An agent may **propose** the exact command, with its reason. The runner cannot stop an agent from writing a row. Keeping agents from writing rows is the skill's job and the Claude Code adapter's, and the PR diff and a CI comment on each new row are planned (IS-02; FRD-04 §4, rule 10).

## What counts as a loosening

When `check --ci` finds one of these since the merge-base, the rule needs a `loosen` row. A rule file deleted needs a `remove` row.
- severity lowered (`block` → `shadow` → `track`);
- `paths` narrowed, or `exclude` widened;
- `engine` or `detector` changed, or a file the detector names changed;
- for a `block` rule, its `format` changed, or its format file changed.

A `loosen` row must be new on the branch. A row already in the merge-base does not count. One row covers every loosening of its rule found since the merge-base, not only the one its text describes. The text is a note for reviewers.

**Not detected yet, and not decided.** Changes to `.gauntlet/config` are not judged as loosening. Today a branch can set `touched=off`, or change `base=` so that the checks compare against another base. The new, global and touched checks then stop judging it, and no exception row is needed. A `stage:` change in a rule file is not flagged either: changing `commit` to `push` takes the rule out of the commit gate. A detector file that is named inside quotes with spaces is not recognised as changed. The owner needs to decide how config and `stage:` changes should be judged.

## Waivers

- The path must exist in git or in the working tree, and it is matched literally. A `./` prefix, a trailing `/` and globs are refused.
- A waiver needs a branch. It is refused on a detached HEAD. In CI the branch is `GITHUB_HEAD_REF`. The commit gate applies no waivers on a detached HEAD.
- The reason must not be empty, and must not contain a tab or a newline. The same goes for the reasons of `loosen` and `remove`.

## Why not commit trailers?

The hand-built version of this process used a commit trailer (`Standards-waiver: <path> — <reason>`). Agents could write it themselves, so they did: up to 17 % of a week's commits carried one. Trailers also clutter history, and some teams forbid them outright. A file is reviewable, diffable and protectable. A trailer is none of those.
