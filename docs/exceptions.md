# Exceptions

Some debt can't be paid in this branch. gauntlet lets a human say so, in writing, in one place.

## The file

`.gauntlet/exceptions.tsv`, versioned, one row per exception:

```
type	target	reason	date	branch
waive	src/legacy/report.ts	rewrite scheduled in #123; this PR only renames	2026-10-22	feat/rename-reports
loosen	raw-status: exclude += src/generated/**	generated code, regenerated on build	2026-10-22	-
```

| Type | Target | Lifetime |
|---|---|---|
| `waive` | one path | this branch only; removed when the branch merges |
| `loosen` | a rule, plus what changed | permanent, recorded |
| `remove` | a rule | permanent, recorded |
| `script` | a custom detector | permanent, recorded |

A path waiver exempts that path from the new-violation and touched-file checks. The rule's total still applies.

## Only humans create exceptions

```sh
gauntlet waive  <path> "<reason>"
gauntlet loosen <rule> "<what changes>" "<reason>"
gauntlet remove <rule> "<reason>"
```

- The agent may **propose** the exact command, with its reason. It never writes the file.
- The Claude Code adapter denies agent edits to `exceptions.tsv`. In that harness you run the command yourself with `! gauntlet waive …`, which is your own shell command and not an agent tool call.
- In every harness, the runner fails any loosening that has no matching row, and CI comments each new exception on the PR.
- **When the agent is blocked and you are away**, it stops, leaves the command ready with its reason, and notifies you. It does not route around the gate.

## Why not commit trailers?

The hand-built version of this process used a commit trailer (`Standards-waiver: <path> — <reason>`). Agents could write it themselves, so they did: up to 17 % of a week's commits carried one. Trailers also clutter history, and some teams forbid them outright. A file is reviewable, diffable and protectable. A trailer is none of those.
