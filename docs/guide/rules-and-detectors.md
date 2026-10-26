# Rules & detectors

## Rule file

Every rule lives in `.gauntlet/rules/<id>.md`:

```markdown
---
id: silent-catch
severity: block                # block | shadow | track
stage: commit                  # commit (default) | push
engine: ast-grep               # linter | ast-grep | rg | script
detector: .gauntlet/rules/silent-catch.yml
paths: src/**
exclude: **/*.test.ts
fix: Log the error with context and rethrow, or handle it; never leave the catch empty.
source: https://… | ADR-0007
since: 2026-10-22
---
Why this rule exists, what to do instead, and the evidence found in this repo.
```

The frontmatter is flat `key: value` pairs, so it parses with awk.

- **Required:** `id` (it must equal the file name), `severity`, `engine`, `detector`, `fix`, `source` and `since` (`YYYY-MM-DD`; only the shape is checked, so `2026-02-30` passes). `source` only has to be non-empty; see below.
- **Optional:** `stage` (default `commit`), `paths` (default: every file), `exclude`, and `format` (default: `path-line`, or `github` for `ast-grep`).
- `gauntlet doctor` checks every rule against this list.
- A rule's `id` must not end in `.bad` or `.good`, and must not contain `.bad.` or `.good.`. Those names are for case files (see [Test cases](#test-cases)), so `loosen` and `remove` do not take them for rules.

Globs in `paths` and `exclude`: `**` matches anything, including `/`; `**/` matches zero or more directories; `*` matches within one directory; `?` matches one character other than `/`.

### `source`

`source` must be a primary source:
- the technology's official documentation;
- its official style guide;
- one of your own ADRs.

A blog post is not enough to block a commit. The runner only checks that `source` is not empty. The onboarding skill, when it ships, may set it to `pending` when it has no web access to confirm a source.

### `stage`

- **`commit`** rules run in `pre-commit`, on staged files only, and must be fast.
- **`push`** is for whole-program detectors (type-check, dependency graph, duplicate definitions). These rules never run at commit. They always run at pre-push and in CI.

## Detectors

### 1. A linter rule

This is the preferred engine. Your linter already knows your code. The detector is the linter command, with `{files}` where the file list goes. This example uses `shellcheck`, which prints `path:line:col: message`:

```yaml
engine: linter
detector: shellcheck --format=gcc {files}
```

Each rule runs its own detector. A linter run shared by several rules is planned (IS-03).

### 2. An `ast-grep` rule

Use this for structural rules in any language `ast-grep` supports. The detector is a YAML rule file, next to the rule:

```yaml
# .gauntlet/rules/silent-catch.yml
id: silent-catch
severity: error
language: typescript
rule:
  kind: catch_clause
  not:
    has:
      stopBy: end
      any:
        - kind: throw_statement
        - pattern: logger.$M($$$)
```

gauntlet runs `ast-grep scan --rule <file> --format github --error`, so a match counts whatever severity the YAML rule sets, or none (checked with ast-grep 0.51.0, the version CI installs). `severity: error` is still the clearest to read. Severity in this file does not decide whether the gate fails: that is the `severity` of the gauntlet rule.

### 3. An `rg` pattern

Use this for rules that really are textual.

```yaml
engine: rg
detector: rg --with-filename --line-number --no-heading 'console\.log\(' {files}
```

### Custom scripts

`engine: script` runs the command in `detector` as written, like `rg`. A script is allowed only by exception: the rule needs a `script` row in `.gauntlet/exceptions.tsv`, and you add that row by hand. No command writes it yet. A `script` rule with no `script` row is refused: `baseline`, `check --ci` and `check --staged` exit 2 with `rule <id>: engine=script needs a script row for [<id>] in .gauntlet/exceptions.tsv; run gauntlet doctor`. The exception keeps the detectors uniform, because a project that lets everyone write detectors "their own way" ends up with dozens of incompatible scripts. A fixed template for detector scripts is planned; the runner does not require one.

## Contract

- **Where it runs.** `bash -o pipefail -c`, from the repo root, with stdin from `/dev/null` and without `RIPGREP_CONFIG_PATH`, so a developer's own ripgrep flags cannot change the rows.
- **Input.** At commit, `{files}` is the staged files that exist on disk and match `paths` minus `exclude`. At push and in CI, it is every tracked file that matches `paths` minus `exclude`. Untracked files are not seen. Files under `.gauntlet/` are never measured, whatever `paths` says, because a rule file contains the pattern it detects.
- **Output.** One violation per line, read through the rule's output format. Rows about files the detector was not given are dropped. A detector without `{files}` runs once, and its rows are filtered by `paths` and `exclude`.
- **Multi-location violations** print one line per location.
- **Exit codes.** `0` and `1` are normal (`rg` exits 1 when nothing matches), but with `1` the output must still parse. `127` means the tool is missing: the message names the install command for `rg` and `ast-grep`. Any other code means a broken detector. A detector's stderr is kept, and its first 5 lines appear with the message. A stage of a pipeline that crashes counts too: in `a | b`, an `a` that exits 2 or more (not 141, which is `a` cut off by a `b` that closed the pipe on purpose) breaks the detector whatever `b` says, so `rg … | grep …` cannot hide an `rg` that did not run. An earlier stage that exits 1 is "no matches" there. This covers the last pipeline of the command text. A subshell `(a | b)`, a `set -e` string and `a | b || true` hide a crash.
- **Long file lists** are split into batches, so each command stays under about 25 KB. A batch that fails with exit 2 or more makes the detector broken.
- **Fail closed.** An output line that the format can neither read nor ignore means a broken detector, and the gate fails. Output is not skipped silently. `baseline`, `check --ci` and `check --staged` also check every rule first: a rule that fails the required-fields check stops the run with exit 2, `rule <id>: <problem>; run gauntlet doctor`.
- **Binary files and NUL bytes.** NUL bytes in a detector's output are removed. The built-in `path-line` format ignores rg's `binary file matches` line, so an `rg` rule does not see binary files. A detector that does flag a source line holding a NUL byte gets a fingerprint that depends on the awk that reads the file: mawk drops the NUL and keeps the line, busybox cuts the line there. A baseline written on one machine can then differ on another. Keep such files out of `paths`.
- **Ignore files.** A detector without `{files}` searches what the tool searches. `rg` honours `.gitignore` and the per-clone ignore files (`.git/info/exclude`, a global ignore), so it can skip a tracked file that another clone sees, and the baseline then differs between clones. Write `--no-ignore` in a whole-program `rg` detector. With `{files}` the files are named on the command line, and ignore files do not apply to them. A `.ignore` or `.rgignore` file that a tool reads can still hide a file, and the loosening check does not see it change.
- **Files never passed to a detector.** Gitlinks, files with the skip-worktree bit and symlinks whose target is missing are never passed to a detector. A staged type change (a symlink that became a file) is measured at commit.
- **Paths with a tab or a newline.** A tab or newline in a tracked path cannot be carried by the tab-separated files, so the run fails closed: exit 2, `gauntlet: path with a tab or newline: <name>; rename the file`, for the first five such names, then `and N more paths; rename them` (`and 1 more path; rename it` for one). The name is printed with `\t` and `\n` spelled out. `baseline`, `check --ci` and `check --staged` stop on it, and `doctor` reports `FAIL baseline cannot be checked: …`; `test-rules` skips an untracked name and refuses a tracked one. A diff or tree listing that names such a path does not stop the run, so a branch can rename or delete the file.

## Output formats

Supporting another linter means describing its output, not changing gauntlet. A format is a small file: frontmatter with the pattern and the positions of the path, the line and the message, then a description and two fenced blocks. `sample` is real output, and `expected` is the rows it must produce, tab-separated. Without a `sample` block, `gauntlet test-rules` fails with `sample  no cases`; without an `expected` block, with `expected  no cases`. Here is a complete format file:

````markdown
---
match: ^([^|]+)\|([0-9]+)\|(.*)$
path: 1
line: 2
message: 3
---
Output of a linter that prints `path|line|message`, one finding per line.

```sample
src/a.ts|12|unused variable
src/b.ts|3|missing return type
```

```expected
src/a.ts	12	unused variable
src/b.ts	3	missing return type
```
````


The `path`, `line` and `message` values are group numbers, each one digit; `message` may be left out. A larger number exits 2: `gauntlet: format <name>: <key> is group <n>; use a group from 0 to 9`. An optional `ignore:` pattern names lines of tool output to skip, instead of making the detector broken.

gauntlet ships three formats:
- `path-line` (`path:line[:col][: message]`), the default for `linter`, `rg` and `script` rules. It reads any linter that prints one such line per finding. A path that contains `:` is not readable by it: the run fails closed with `broken detector: <id>: unparsed line: …`, so rename the file or write a format for the tool.
- `github` (GitHub annotation lines), the default for `ast-grep`.
- `tsc`.

Add your own in `.gauntlet/formats/<name>.md`, and name it in the rule with `format: <name>`. A project format with the same name as a built-in one replaces it. Each format carries a sample of real output and the rows it must produce, and `gauntlet test-rules` checks them. Changing a format that a `block` rule reads through counts as loosening that rule, so it needs a `loosen` row.

## Test cases

Each rule has test cases next to it:
- `<id>.bad.<ext>` must be flagged;
- `<id>.good.<ext>` must not be flagged;
- a directory `<id>.bad/` or `<id>.good/` is one case made of all its files, for a rule that needs several files.

`gauntlet test-rules` runs the cases. `check --ci` runs them too whenever a file under `.gauntlet/rules/` or `.gauntlet/formats/` changed since the base, so pre-push and CI run them. A rule or format change on a branch therefore needs its cases on that branch. A detector that misses `bad` or flags `good` fails the gate. `check --ci` reads the tracked cases only, so `git add` new cases before you push; `gauntlet test-rules` on its own also reads untracked ones, so you can try a case first.

A case can have any extension, and `.gauntlet/.gitignore` brings back only `rules/*.md`. A root ignore rule such as `*.ts` therefore hides `todo.bad.ts` from `git add`, and from the gate in a clone. `gauntlet doctor` lists such a file (`a root ignore rule hides … remove or narrow that rule`); narrow the rule, or `git add -f` the case.

## Writing a good rule

Until the `add-rule` skill command exists, write a rule by hand in this order:

1. State the rationale and a primary source.
2. Show evidence in this repo: the count and the worst files.
3. Write the most declarative detector that works.
4. Write the fix hint, as one actionable line.
5. Check for conflict or overlap with existing rules and with linter-owned rules.
6. Add the `bad` and `good` cases, and run `gauntlet test-rules`.
7. Measure the baseline, then start in `shadow`.

## Linter-owned rules

A rule lives in exactly one place:

- **A linter rule with zero violations** stays in the linter at `error`. gauntlet ignores it.
- **A linter rule with debt** becomes a gauntlet rule that runs that linter rule.
- **When that rule reaches zero**, you may move it back to the linter at `error`. The guard that keeps it there is planned (IS-03). See [Guard](concepts.md#guard).
