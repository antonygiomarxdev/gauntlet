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
source: https://… | ADR-0007 | pending
since: 2026-10-22
---
Why this rule exists, what to do instead, and the evidence found in this repo.
```

The frontmatter is flat `key: value` pairs, so it parses with awk.

### `source`

`source` must be a primary source:
- the technology's official documentation;
- its official style guide;
- one of your own ADRs.

A blog post is not enough to block a commit. If onboarding ran without web access, `source` is set to `pending` until a session with web access confirms it.

### `stage`

- **`commit`** rules run in `commit-msg`, on staged files only, and must be fast.
- **`push`** is for whole-program detectors (type-check, dependency graph, duplicate definitions). These rules are skipped at commit, but always run at pre-push and in CI.

## Detectors

### 1. A linter rule

This is the preferred engine. Your linter already knows your code.

```yaml
engine: linter
detector: eslint --format unix --rule '{"@typescript-eslint/explicit-function-return-type":"error"}' {files}
```

Several rules backed by the same linter share **one cached run** per gate invocation.

### 2. An `ast-grep` rule

Use this for structural rules in any language `ast-grep` supports.

```yaml
# .gauntlet/rules/silent-catch.yml
id: silent-catch
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

### 3. An `rg` pattern

Use this for rules that really are textual.

```yaml
engine: rg
detector: rg --line-number --no-heading 'console\.log\(' {files}
```

### Custom scripts

A custom script is allowed only by exception. A human approves a `script` exception, and the detector lives in `.gauntlet/detectors/`, built from the fixed template, with test cases. This rule exists because a project that lets everyone write detectors "their own way" ends up with dozens of incompatible scripts.

## Contract

- **Input.** At commit, the runner substitutes `{files}` with the staged files. At push and in CI, it substitutes every file that matches `paths` minus `exclude`.
- **Output.** One violation per line: `path:line[: message]`. The runner then drops lines about files it did not pass in.
- **Multi-location violations** print one line per location.
- **Fail closed.** A non-zero exit with no parseable output is treated as a broken detector, and the gate fails. A missing tool fails with its install command. Nothing is skipped silently.

## Test cases

Each rule has test cases next to it:
- `<id>.bad.<ext>` must be flagged;
- `<id>.good.<ext>` must not be flagged.

Three alternatives cover the cases a single file can't:
- **A directory**, for cross-file rules.
- **A `fixtures:` path inside the project's lint scope**, for linter rules that ignore files outside the project config.
- **A config fixture**, for guards.

Whenever anything under `.gauntlet/rules/` changes, pre-push and CI run all the cases. A detector that misses `bad` or flags `good` fails the gate.

## Writing a good rule

`add-rule` follows `HOW-TO-WRITE-A-RULE.md` (installed into `.gauntlet/` with v0.1):

1. State the rationale and a primary source.
2. Show evidence in this repo: the count and the worst files.
3. Write the most declarative detector that works.
4. Write the fix hint, as one actionable line.
5. Check for conflict or overlap with existing rules and with linter-owned rules.
6. Add the `bad` and `good` cases.
7. Measure the baseline, then start in shadow.

## Linter-owned rules

A rule lives in exactly one place:

- **A linter rule with zero violations** stays in the linter at `error`. gauntlet ignores it.
- **A linter rule with debt** becomes a gauntlet rule that runs that linter rule.
- **When that rule reaches zero**, it goes back to the linter at `error`, and gauntlet keeps a [guard](concepts.md#guard).
