# Command reference

Run every command from the repository root. The guide writes `gauntlet`; in your repo that is `.gauntlet/bin/gauntlet`, the copy `install` vendored.

## Commands

| Command | What it does |
|---|---|
| `gauntlet install` | Copies the runner into `.gauntlet/bin/` and `.gauntlet/lib/`, replacing both, creates the missing state files, then runs `install-hooks`. Run it from a gauntlet checkout, or through a symlink to one. Safe to run again. |
| `gauntlet install-hooks` | Adds the gate to your hooks. See [hooks](gates.md#hooks-coexist-never-take-over). |
| `gauntlet baseline` | Measures the tracked files and writes `.gauntlet/baseline.tsv`. Untracked files are not measured: `git add` a new file first. |
| `gauntlet test-rules` | Runs each rule's `bad` and `good` cases and each output format's sample. |
| `gauntlet base [<ref>]` | Prints the base this branch is measured against. With `<ref>`, sets it for the current branch. |
| `gauntlet check --ci [--base <ref>]` | The push and CI gate: the branch against the merge-base of HEAD and the base. |
| `gauntlet check --staged` | The commit gate, run by `pre-commit`. Checks the staged files only. |
| `gauntlet status` | Prints the debt summary and writes `.gauntlet/STATUS.md`. |
| `gauntlet promote <id>` | Changes a `shadow` rule to `block` in its rule file. Any other severity is refused. |
| `gauntlet doctor` | Checks the setup. |
| `gauntlet waive <path> <reason>` | Waives a path on the current branch. |
| `gauntlet loosen <rule> <what> <reason>` | Records a loosening of a rule, so the gate accepts it. |
| `gauntlet remove <rule> <reason>` | Records the removal of a rule. |
| `gauntlet --version` | Prints the runner version. |

Only `base <ref>` writes git config (`branch.<name>.gauntletBase`). `waive`, `loosen` and `remove` write `.gauntlet/exceptions.tsv`; `baseline` and `status` write their own files; the commit gate writes `baseline.tsv` only when it tightens it.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Passed. |
| `1` | The gate failed: `check`, `test-rules` or `doctor` found a problem. |
| `2` | The setup is broken or the usage is wrong. Examples: not in a git repo, a missing tool, a bad config key, a dirty tree at `check --ci`, a shallow clone without the base. |

## Config: `.gauntlet/config`

One `key=value` per line. A line starting with `#` is a comment.

| Key | Default | Meaning |
|---|---|---|
| `base` | none | The base for every branch in this repo, used when the branch has no `gauntlet base` setting. |
| `touched` | `off` | `on` turns on the touched-file gate. Any other value exits 2. |
| `check.<name>` | none | A project check: a shell command, run from the repo root. |
| `check.<name>.paths` | empty | Space-separated path prefixes. The check runs when a changed file starts with one. Empty means always. |
| `check.<name>.ci` | `off` | `on` runs the check under `CI=true`. |

A check name uses only letters, digits, `_` and `-`. A malformed `check.` key (a bad name, a `ci` value other than `on` or `off`, or an attribute with no command) exits 2 before any check runs. Other unknown keys are ignored by the gate, and `doctor` reports them.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `CI` | unset | `true` makes `check --ci` run only the declared checks with `ci=on`. CI hosts such as GitHub Actions set it. |
| `GITHUB_HEAD_REF` | unset | The branch name when HEAD is detached. CI sets it on pull requests. Waivers and the branch's base use it. |
| `GAUNTLET_COMMIT_BUDGET_MS` | `5000` | The commit budget, in milliseconds. `status` lists the commit rules at or over it, and the commit gate prints `[slow]`. It only warns. |
| `GAUNTLET_TODAY` | today | The day `status` measures shadow rules against, as `YYYY-MM-DD`. Mostly for tests. |
| `GAUNTLET_LIB` | the runner's own `lib/` | Where the built-in output formats are read from. Leave it unset. |

## Files

| Path | Written by |
|---|---|
| `.gauntlet/rules/<id>.md` | You |
| `.gauntlet/formats/<name>.md` | You, for an output format that no built-in covers |
| `.gauntlet/config` | You |
| `.gauntlet/baseline.tsv` | `gauntlet baseline`, and the commit gate when it tightens. Never by hand. |
| `.gauntlet/exceptions.tsv` | `waive`, `loosen`, `remove`. A `script` row is added by hand. |
| `.gauntlet/STATUS.md` | `gauntlet status`. Put it in `.gitignore`. |
| `.gauntlet/bin/`, `.gauntlet/lib/` | `gauntlet install` |
| `.git/gauntlet-time.tsv` | The commit gate: the per-rule times of its last run. It lives in the git dir of the worktree and is never committed. |

## `status`, `promote` and `doctor`

### `status`

`gauntlet status` reads the committed baseline (no detector runs). It prints, and writes to `.gauntlet/STATUS.md`, this text:

```
| rule | severity | total |
| --- | --- | --- |
| todo | block | 2 |

| file | block total |
| --- | --- |
| src/a.ts | 1 |
| src/b.ts | 1 |

promote due: todo (shadow since 2026-10-01, 22 days), 2 found
slow: todo 51 ms (consider stage: push)
```

- The rule table lists every rule with its severity and its total, the sum of its rows in the baseline.
- The file table lists up to five files with the most `block` violations.
- A `promote due:` line appears for each shadow rule that is 7 days old or more. The `<total>` after `found` is the rule's current total.
- `slow:` lines list commit-stage rules whose time in the last commit run was at or over the budget. See [Performance](gates.md#performance).
- The text has no timestamp, and there is no trend. `status` shows the state now.
- Put `.gauntlet/STATUS.md` in `.gitignore`. If it is tracked, each `status` run that changes it makes the tree dirty, and `check --ci` refuses a dirty tree.
- If `.gauntlet/STATUS.md` is a symlink, `status` replaces it with a regular file.

### `promote`

`gauntlet promote <id>` changes `severity: shadow` to `severity: block` in the rule's file, and leaves every other byte alone. It prints `promoted <id>: shadow -> block; commit the rule file`. It exits 2, and changes nothing, for an unknown rule or for a rule whose severity is not `shadow`.

### `doctor`

`gauntlet doctor` prints one line per check: `ok <thing>`, or `FAIL <thing>: <how to fix>`. It exits 1 on any FAIL, and 2 when it cannot run (not in a git repo, or no `.gauntlet/` directory). It runs six groups of checks, in this order:

1. **Tools.** Each rule's tool must be on `PATH`. For an `ast-grep` rule the tool is `ast-grep`. For `rg`, `linter` and `script` rules it is the first word of the detector. A first word with quotes, `$`, `=` or `~` is not checked.
   - `FAIL tool <tool> for rule <id> is missing: <install hint>`, or `install it or fix the detector in .gauntlet/rules/<id>.md` when there is no hint.
2. **Runner, formats and hooks.** The vendored runner must run `--version`. Each rule's format must be built in or in `.gauntlet/formats/`. Each hook must hold the gate line, in either form, or the lefthook or prek config must hold both commands.
   - `FAIL .gauntlet/bin or .gauntlet/lib is broken or missing: run gauntlet install from a gauntlet checkout …`
   - `FAIL rule <id>: format <name> is unknown: use a built-in format or add .gauntlet/formats/<name>.md`
   - `FAIL <stage> gate missing from <file>: run gauntlet install-hooks`, or `add this line by hand as the first command …` for a hook that `install-hooks` would only print.
   - `FAIL <stage> hook <file> is not executable: chmod +x <file>`
   - `FAIL gate missing from <config>: run gauntlet install-hooks and add the snippet it prints`
3. **Baseline.** The committed baseline must equal the measurement.
   - `FAIL baseline differs from the code: run gauntlet baseline and commit it`
   - `FAIL baseline .gauntlet/baseline.tsv is missing: run gauntlet baseline and commit it`
4. **Config.** The keys must be `base`, `touched` (`on` or `off`) or `check.*`.
   - `FAIL config key <key> is not known; use base, touched or check.<name>`
   - `FAIL config line <n> has no '=': write key=value`
   - `FAIL touched must be on or off, got [<value>]: fix the touched line in .gauntlet/config`
5. **Rules.** Each rule must pass the required-fields check in [Rules & detectors](rules-and-detectors.md#rule-file): `FAIL rule <id>: <problem>; fix .gauntlet/rules/<id>.md`.
6. **Waivers.** `stale waive <path> (branch <branch>)` lists the waivers of other branches. They never fail.

Limits:
- Hooks: `doctor` checks that the gate line is there, not that the gate runs. See [hooks](gates.md#what-doctor-checks-and-what-it-does-not).
- If `.gauntlet/lib` is missing, the vendored script stops at startup with a `No such file` error and exit 1, before `doctor` prints anything. Run `gauntlet install` again from the checkout.
- `doctor` cannot tell a truncated or emptied file in `.gauntlet/lib` from a good one.

## Known limits

These are known and not handled yet:
- A path with a tab or a newline in its name is not measured, and nothing reports it. See [Contract](rules-and-detectors.md#contract).
- A config saved with CRLF line endings makes `check` exit 2 with `touched must be on or off, got [off]`. Save it with LF line endings.
- A check named `BAD` is refused with exit 2, `bad check key off`. Rename it.
- A declared check has no timeout, so a hanging check holds the gate.
- A `status` that is killed can leave `.gauntlet/.STATUS.md.<pid>` behind. Delete it.
- `GAUNTLET_COMMIT_BUDGET_MS` changes when `[slow]` appears, not its text.
- Changes to `.gauntlet/config` and `stage:` changes are not detected as loosening. See [Exceptions](exceptions.md#what-counts-as-a-loosening).
- A rename of a file with `stage: push` debt is not carried by the commit gate. Run `gauntlet baseline` after such a rename. See [Renames](gates.md#renames).
