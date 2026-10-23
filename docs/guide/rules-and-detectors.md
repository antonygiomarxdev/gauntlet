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

- **Required:** `id` (it must equal the file name), `severity`, `engine`, `detector`, `fix`, `source` and `since` (a real date, `YYYY-MM-DD`). `source` only has to be non-empty; see below.
- **Optional:** `stage` (default `commit`), `paths` (default: every file), `exclude`, and `format` (default: `path-line`, or `github` for `ast-grep`).
- `gauntlet doctor` checks every rule against this list.
- A rule's `id` must not end in `.bad` or `.good`, and must not contain `.bad.` or `.good.`. Those names are for case files (see [Test cases](#test-cases)).

Globs in `paths` and `exclude`: `**` matches anything, including `/`; `**/` matches zero or more directories; `*` matches within one directory; `?` matches one character.

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

The `severity: error` line matters. `ast-grep` prints no annotation for a rule without a severity, so the rule would find nothing. `gauntlet test-rules` catches this with `bad case not flagged`. Use `severity: warning` if you want the rule to report without failing.

### 3. An `rg` pattern

Use this for rules that really are textual.

```yaml
engine: rg
detector: rg --with-filename --line-number --no-heading 'console\.log\(' {files}
```

### Custom scripts

`engine: script` runs the command in `detector` as written, like `rg`. A script is allowed only by exception: the rule needs a `script` row in `.gauntlet/exceptions.tsv`, and a human adds that row by hand. No command writes it yet. The exception keeps the detectors uniform, because a project that lets everyone write detectors "their own way" ends up with dozens of incompatible scripts. A fixed template for detector scripts is planned; the runner does not require one.

## Contract

- **Input.** At commit, `{files}` is the staged files that exist on disk. At push and in CI, it is every tracked file that matches `paths` minus `exclude`. Untracked files are not seen. Files under `.gauntlet/` are never measured, whatever `paths` says, because a rule file contains the pattern it detects.
- **Output.** One violation per line, read through the rule's output format. Rows about files the detector was not given are dropped. A detector without `{files}` runs once, and its rows are filtered by `paths` and `exclude`.
- **Multi-location violations** print one line per location.
- **Exit codes.** `0` and `1` are normal (`rg` exits 1 when nothing matches), but with `1` the output must still parse. `127` means the tool is missing: the message names the install command for `rg` and `ast-grep`. Any other code means a broken detector. A detector's stderr is kept, and its first 5 lines appear with the message.
- **Long file lists** are split into batches, so each command stays under about 100 KB. A batch that fails with exit 2 or more makes the detector broken.
- **Fail closed.** An output line that the format can neither read nor ignore means a broken detector, and the gate fails. Nothing is skipped silently.
- **Unsupported paths.** A path with a tab or a newline in its name cannot be carried by the runner's tables. It is not measured, and nothing reports that. Rename such files.

## Output formats

Supporting another linter means describing its output, not changing gauntlet. A format is a small file with a pattern and the positions of the path, the line and the message:

```markdown
---
match: ^(.+)\(([0-9]+),[0-9]+\): (error|warning) (.*)$
path: 1
line: 2
message: 4
ignore: ^Found [0-9]+ errors?
---
```

gauntlet ships three formats:
- `path-line` (`path:line[:col][: message]`), the default for `linter`, `rg` and `script` rules. It reads any linter that prints one such line per finding.
- `github` (GitHub annotation lines), the default for `ast-grep`.
- `tsc`.

Add your own in `.gauntlet/formats/<name>.md`, and name it in the rule with `format: <name>`. A project format with the same name as a built-in one replaces it. Each format carries a sample of real output and the rows it must produce, and `gauntlet test-rules` checks them. Changing a format that a `block` rule reads through counts as loosening that rule, so it needs a human's `loosen` row.

## Test cases

Each rule has test cases next to it:
- `<id>.bad.<ext>` must be flagged;
- `<id>.good.<ext>` must not be flagged;
- a directory `<id>.bad/` or `<id>.good/` is one case made of all its files, for a rule that needs several files.

`gauntlet test-rules` runs the cases. `check --ci` runs them too whenever a file under `.gauntlet/rules/` or `.gauntlet/formats/` changed since the base, so pre-push and CI run them. A rule or format change on a branch therefore needs its cases on that branch. A detector that misses `bad` or flags `good` fails the gate.

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
