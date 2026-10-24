# Concepts

gauntlet has eight ideas. Everything else is plumbing.

## Rule

A rule is an agreed constraint. It lives in `.gauntlet/rules/<id>.md` and carries:
- why the rule exists;
- a primary source;
- a detector;
- a fix hint;
- test cases;
- a severity.

A constraint that cannot be detected is not admitted as a rule: write its detector first. Prose rules get forgotten; counted rules don't.

## Detector

A detector is a declarative way to find violations:

1. a rule of the project's own linter,
2. an [`ast-grep`](https://ast-grep.github.io) YAML rule, for structural rules in any language,
3. an `rg` pattern, for textual rules only.

That order is the order of preference. A custom script detector needs a `script` row in `exceptions.tsv`, which you add by hand. [Rules & detectors](rules-and-detectors.md) covers the details.

## Fingerprint

A violation's identity is **rule + file + the flagged line's text, with whitespace collapsed**, never its line number. Inserting lines, moving a line within its file, re-indenting and changing line endings leave fingerprints unchanged. Only runs of spaces and tabs are normalized: a formatter that changes the text of a flagged line (splits it, or changes quotes or punctuation) makes a new fingerprint, and so does moving the line to another file. A violation is *new* when its fingerprint appears more often than it did at the base.

## Baseline

`.gauntlet/baseline.tsv` lists every fingerprint present in the repo, with its multiplicity:

```
silent-catch	src/api/client.ts	catch (e) { }	2
raw-status	src/orders/list.tsx	if (o.status === "paid")	1
```

The baseline is **derived**:
- The runner writes it: `gauntlet baseline`, and the commit gate when it tightens.
- A hand edit is caught, not prevented: CI re-measures and requires the committed baseline to equal the measurement exactly.
- Edit it only through the runner.

When debt falls, the lowered baseline is staged into the same commit that paid it.

## Severity

| Severity | Counted | Reported | Fails the gate |
|---|---|---|---|
| `block` | yes | yes | yes |
| `shadow` | yes | "would have failed" | no; stays until you promote it |
| `track` | yes | yes, with the delta when it rises | never |

Write every new `block` rule as `shadow` first, so a false positive is caught before it ever blocks anyone. Once a shadow rule is 7 days old, `gauntlet status` lists it as due for promotion, with the number of violations it finds. Promotion is always manual: `gauntlet promote <id>`.

## Gate

The same runner runs at three points:
- the `pre-commit` hook, which checks staged files and must finish in under 5 s;
- the `pre-push` hook, which runs everything CI runs;
- CI itself.

The pre-push and CI runs check:
- that no new fingerprint appears;
- that no rule total rises;
- optionally, that every touched file comes out lower;
- that the baseline is exact;
- that no rule was loosened.

The commit gate checks only the new fingerprints and, when it is on, the touched files. Its job is fast feedback.

Existing debt never fails the gate by itself. [Gates](gates.md) covers the details.

## Exception

An exception is a row in `.gauntlet/exceptions.tsv`. There are four kinds:
- `waive` a path for one branch;
- `loosen` a rule;
- `remove` a rule;
- `script`: approve a custom detector.

Exceptions are rows in `exceptions.tsv`, written by `gauntlet waive …` and its siblings. The gate fails a loosening that has no row. The runner cannot tell who wrote a row, so review the diff. There are no commit trailers. [Exceptions](exceptions.md) covers the details.

## Guard

**Planned (IS-03).** When a ratcheted linter rule reaches zero, it graduates back to the linter at `error` level. gauntlet would keep a guard: a `block` rule at zero that fails in two cases:
- the linter's effective config stops treating the rule as an error;
- new inline suppressions of that rule appear.

Graduating a rule does not mean letting it go.
