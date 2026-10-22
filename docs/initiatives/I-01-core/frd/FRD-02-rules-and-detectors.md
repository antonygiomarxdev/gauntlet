# FRD — Rules and detectors

**Status:** Draft
**Key:** RULE
**Parent PRD:** [PRD — gauntlet](../PRD.md)
**Owner:** Antony Giomar Hernández

## 1. Functional problem

A rule written in prose gets forgotten. A rule backed by an ad-hoc script gets written a different way every time. The origin project grew 41 bespoke check scripts, with no shared format and no guide.

gauntlet admits a rule only when it has a declarative detector, a fix hint, a primary source and test cases. Every rule is written in one file format.

## 2. Actors and situations

| Actor | Situation |
|---|---|
| Owner | Approves rules, their sources and their severities; approves any custom script detector. |
| Agent | Writes rule files, detectors and cases after the Owner's yes; reads fix hints when blocked. |
| Contributor | Reads a violation and its fix line. |
| CI | Runs the rule tests whenever rules change. |

## 3. Preconditions

- gauntlet is installed in the repo.
- The tool each detector needs is on `PATH`: the project's linter, `ast-grep` or `rg`.

## 4. Business rules

1. **One file per rule.** A rule lives in `.gauntlet/rules/<id>.md`, with flat `key: value` frontmatter and a markdown body that holds the rationale and the repo evidence.
2. **Required keys:** `id`, which equals the file name; `severity`; `engine`; `detector`; `fix`; `source`; `since`. The optional keys are `stage`, which defaults to `commit`, `paths` and `exclude`.
3. **`severity` is one of three values.**
   - `block` is fully gated.
   - `shadow` reports "would have failed" and never fails.
   - `track` is counted and reported and never fails.
4. **`stage` is `commit` or `push`.** `push` rules (whole-program detectors such as type-check, dependency graph or duplicate definitions) do not run at commit, but always run at push and in CI.
5. **Detectors are declarative**, in this order of preference:
   1. a rule of the project's own linter;
   2. an `ast-grep` YAML rule, for structural rules in any language;
   3. an `rg` pattern, for rules that are genuinely textual.

   A custom script detector requires a human-approved `script` exception (EXC). It lives in `.gauntlet/detectors/`, is built from the fixed template, and has cases.
6. **Input contract.** At commit, `{files}` in the detector is replaced by the staged files. At push and in CI, it is replaced by every file matching `paths` minus `exclude`. A detector without `{files}` runs once over the whole repo.
7. **Output contract.** A detector prints one violation per line as `path:line[: message]`. A violation spanning several locations prints one line per location. Lines about files outside the input are dropped.
8. **Fail closed.**
   - A detector that exits non-zero with output that does not parse is broken, and the gate fails.
   - A missing tool fails with its install command.
   - Nothing is skipped silently.
9. **Every rule has cases.**
   - `<id>.bad.<ext>` must be flagged; `<id>.good.<ext>` must not be.
   - A case may instead be a directory (cross-file rules) or a fixture path inside the project's lint scope.
   - Guards (LIFE) are tested with a config fixture.

   A rule without a `bad` case fails its tests.
10. **When rule tests run.** `gauntlet test-rules` runs every rule's cases. Pre-push and CI run them whenever anything under `.gauntlet/rules/` changed.
11. **`source` is a primary source:** official documentation, the technology's official style guide, or a project ADR. A blog post is not enough. `pending` is allowed only until a session with web access confirms the source.
12. **The fix hint is one line.** `fix` is one actionable line, printed under every violation of the rule.
13. **One owner per rule.** A rule lives in exactly one place: the project's linter or gauntlet, never both (see LIFE for graduation).

## 5. Functional flows

### Flow A — a rule backed by a linter rule

1. `engine: linter`, and `detector` is the linter command with the rule enabled and `{files}`.
2. The output is mapped to `path:line[: message]`.

### Flow B — an `ast-grep` rule

1. `engine: ast-grep`, and `detector` points to `.gauntlet/rules/<id>.yml`.
2. The runner invokes `ast-grep` on the input files.

### Flow C — an `rg` rule

`engine: rg`, and `detector` is an `rg` command line with `--with-filename --line-number --no-heading … {files}`.

### Flow D — testing rules

1. `gauntlet test-rules` runs each rule's detector on its cases only.
2. It reports each case that was not flagged when it should have been, or was flagged when it should not have been, and each rule with no cases.

## 6. Edge cases and failure behavior

- **The tool is missing.** The gate fails with `missing tool <x>` and the install command.
- **The detector crashes, or the rule file is invalid.** The gate fails as broken setup (exit 2), not as a violation.
- **No file matches `paths`.** The detector is not run, and the rule counts 0.
- **Paths contain spaces or non-ASCII characters.** They reach the detector intact, and are parsed back intact.
- **A reformat splits one flagged line into several.** The new text is a new fingerprint, so the gate reports it. This fails closed.
- **A rule's `id` does not match its file name.** The rule is invalid.

## 7. Permissions

| Action | Owner | Agent |
|---|---|---|
| Approve a new rule or a change to an active rule | yes | no |
| Write rule files, detectors and cases | yes | yes, only after the Owner's yes, through `add-rule` or `propose-rule` |
| Approve a custom script detector | yes, via `script` exception | no |
| Run `test-rules` | yes | yes |

## 8. Data semantics

- **`.gauntlet/rules/<id>.md`:** the rule. Its frontmatter keys are as in §4. `since` is the date the rule entered shadow, and drives the promotion reminder.
- **`.gauntlet/rules/<id>.yml`:** the `ast-grep` rule, when the engine is `ast-grep`.
- **`.gauntlet/rules/<id>.bad*` and `<id>.good*`:** the cases, each a file or a directory.
- **`.gauntlet/detectors/`:** custom script detectors, present only by exception.
- **`.gauntlet/HOW-TO-WRITE-A-RULE.md`:** the guide every rule follows (LIFE).

## 9. Functional acceptance criteria

- **RULE-AC1:** Given a rule file whose `severity` is not `block`, `shadow` or `track`, when any gate runs, then it fails as broken setup and names the file and the key.
- **RULE-AC2:** Given a rule with `engine: script` and no `script` exception, when any gate runs, then it fails as broken setup.
- **RULE-AC3:** Given a detector with `{files}` and staged files `a.ts` and `my dir/b.ts`, when the commit gate runs, then the detector receives exactly those two paths, intact.
- **RULE-AC4:** Given a detector that prints a violation for a file outside its input, when it runs, then that violation is ignored.
- **RULE-AC5:** Given a detector that exits non-zero and prints unparseable output, when any gate runs, then the gate fails and reports a broken detector.
- **RULE-AC6:** Given a detector whose tool is not installed, when any gate runs, then the gate fails with the tool name and its install command.
- **RULE-AC7:** Given an `rg` detector with no matches, when it runs, then the rule counts 0 and the gate does not fail.
- **RULE-AC8:** Given a `stage: push` rule, when the commit gate runs, then the rule is not run; when pre-push or CI runs, then it is.
- **RULE-AC9:** Given a rule whose `bad` case is not flagged, when `test-rules` runs, then it fails and names the rule and the case.
- **RULE-AC10:** Given a rule whose `good` case is flagged, when `test-rules` runs, then it fails.
- **RULE-AC11:** Given a rule with no cases, when `test-rules` runs, then it fails with `no cases`.
- **RULE-AC12:** Given a `bad` directory where one of two files violates, when `test-rules` runs, then the case passes.
- **RULE-AC13:** Given a change under `.gauntlet/rules/` in the branch, when pre-push or CI runs, then every rule's cases run.
- **RULE-AC14:** Given any violation printed by a gate, when shown, then the rule's `fix` line follows it.

## 10. Out of scope

- How violations are compared against the baseline (GATE).
- Exceptions for loosening a rule (EXC).
- Mapping specific linters' native output formats beyond `path:line`. Small adapters are added as consumers need them.

## 11. Dependencies on other FRDs

| FRD | Why |
|---|---|
| FRD-04 Exceptions (EXC) | `script` engine approval. |
| FRD-06 Rule lifecycle (LIFE) | Writing rules, `HOW-TO-WRITE-A-RULE.md`, and guards for linter-owned rules. |

## 12. Open questions

1. **Normalizing fingerprints for line-oriented `rg` rules when a reformat splits one flagged line into several**. Proposed default: treat it as new and report it (fail closed). Revisit only if it produces real false positives.
2. **Native linter output mapping** (ESLint JSON, ruff, golangci, …). Proposed default: support `path:line[:col][: message]` generically in v0.1, which covers `eslint --format unix` and `ruff --output-format concise`, and add adapters on demand.
