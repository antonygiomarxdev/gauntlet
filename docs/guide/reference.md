# Command reference

Commands work from any directory inside the repository: they change to the repository root first. The guide writes `gauntlet`; in your repo that is `.gauntlet/bin/gauntlet`, the copy `install` vendored. The hooks and CI call it by that path from the root.

## Commands

| Command | What it does |
|---|---|
| `gauntlet install` | Copies the runner into `.gauntlet/bin/` and `.gauntlet/lib/`, replacing both, creates the missing state files and `.gauntlet/.gitignore`, then runs `install-hooks`. Run it from a gauntlet checkout, or through a symlink to one. Run from the vendored copy, it does not copy the runner (it gives back a missing exec bit) and goes on with the rest. Safe to run again. See [what it creates](#install-and-what-it-creates). |
| `gauntlet install-hooks` | Adds the gate to your hooks, or prints it. Writes no hook without an executable runner. See [hooks](gates.md#hooks-coexist-never-take-over). |
| `gauntlet baseline` | Measures the tracked files and writes `.gauntlet/baseline.tsv`. Untracked files are not measured: `git add` a new file first. |
| `gauntlet test-rules` | Runs each rule's `bad` and `good` cases and each output format's sample. |
| `gauntlet base [<ref>]` | Prints the base this branch is measured against. With `<ref>`, sets it for the current branch. |
| `gauntlet check --ci [--pre-push] [--base <ref>]` | The push and CI gate: the branch against the merge-base of HEAD and the base. `--pre-push` is for the `pre-push` hook: it reads git's ref lines on stdin and refuses a push of a commit that is not HEAD. See [the pre-push gate](gates.md#the-pre-push-gate). |
| `gauntlet check --staged` | The commit gate, run by `pre-commit`. Checks the staged files only. |
| `gauntlet status` | Prints the debt summary and writes `.gauntlet/STATUS.md`. |
| `gauntlet promote <id>` | Changes a `shadow` rule to `block` in its rule file. Any other severity is refused. |
| `gauntlet doctor` | Checks the setup. |
| `gauntlet waive <path> <reason>` | Waives a path on the current branch. |
| `gauntlet loosen <rule> <what> <reason>` | Records a loosening of a rule, so the gate accepts it. `<rule>` can be `@config`, which stands for `.gauntlet/config`. |
| `gauntlet remove <rule> <reason>` | Records the removal of a rule. |
| `gauntlet --version` | Prints the runner version. |

There is no `--help`. A missing or mistyped command prints `gauntlet: unknown command: <x>`. `waive`, `loosen`, `remove`, `check`, `promote`, `status` and `doctor` print their usage line when called with the wrong arguments (`gauntlet: usage: gauntlet waive <path> <reason>`); the other commands ignore extra arguments. Both exit 2.

`waive`, `loosen` and `remove` exit 2 with `gauntlet: no .gauntlet/ directory; run gauntlet install` when there is none. `loosen` and `remove` also refuse a rule that exists nowhere: `gauntlet: no rule <id>`. A rule exists when its file is in the working tree, in HEAD or at the merge-base. A case file such as `todo.bad.md` is not a rule.

Only `base <ref>` writes git config (`branch.<name>.gauntletBase`). `waive`, `loosen` and `remove` write `.gauntlet/exceptions.tsv`; `baseline` and `status` write their own files; the commit gate writes `baseline.tsv` only when a commit changes what it measures (a fix lowers it; a `shadow` or `track` rule, or a waived path, can raise it); `install` and `install-hooks` write the files in [install](#install-and-what-it-creates). `core.hooksPath` is never written.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Passed. |
| `1` | The gate failed: `check`, `test-rules` or `doctor` found a problem, or `check --ci --pre-push` refused a push of a commit that is not HEAD. |
| `2` | The setup is broken or the usage is wrong. Examples: not in a git repo, a missing tool, a bad config key, a dirty tree at `check --ci`, a shallow clone without the base, a tab or newline in a tracked path, a broken detector (`gauntlet: broken detector: <id>: exit 2`), a read of the base or the index that git cannot answer, an install lock that stays held. |
| `129`, `130`, `143` | SIGHUP, SIGINT or SIGTERM ended the run (128 plus the signal number). The run removes its temp files first. A SIGTERM sent to gauntlet alone is handled when the detector it is running returns; a signal to the process group, as Ctrl-C sends, ends the detector too. |

A read that git cannot answer is exit 2, never "the file is absent": `gauntlet: cannot read <path> at <sha>`, with git's first error line after it when git gave one. A path with a tab or a newline in its name is refused: `gauntlet: path with a tab or newline: <name>; rename the file`. That covers the tracked files a run measures. A diff or a tree listing that names such a path only scopes checks, so a branch can still rename or delete the offending file.

Names that come from the repo (paths, rule ids, refs, config values) are printed with control bytes escaped: `\x1b` for ESC, and the same for the C1 range, which a terminal in 8-bit mode reads as controls. A name that starts with `::` has its first colon written `\x3a`. `baseline.tsv` and `exceptions.tsv` keep the raw bytes. One limit: a valid UTF-8 character whose last byte falls in `0x80`-`0x9F` (the euro sign `E2 82 AC`, for one) stays as it is, because escaping it would break every non-ASCII name. A command that gauntlet asks you to paste (the `chmod +x` of a runner or a hook, `gauntlet base <ref>` and `gauntlet loosen @config <text>` in the base hint) carries the repo's text as one single-quoted word, with an embedded single quote written `'\''`, so pasting it runs nothing the repo chose.

## Config: `.gauntlet/config`

One `key=value` per line. A line starting with `#` is a comment.

| Key | Default | Meaning |
|---|---|---|
| `base` | none | The base for every branch in this repo, used when the branch has no `gauntlet base` setting. Set it when your default branch is not `main` and the clone has no `origin/HEAD`. A value with a control byte exits 2: `gauntlet: bad base= in .gauntlet/config: <value>`. Changing it is a loosening: see [Exceptions](exceptions.md#config-changes). |
| `touched` | `off` | `on` turns on the touched-file gate. Any other value exits 2. |
| `check.<name>` | none | A project check: a shell command, run from the repo root. |
| `check.<name>.paths` | empty | Space-separated path prefixes. The check runs when a changed file starts with one. Empty means always. |
| `check.<name>.ci` | `off` | `on` runs the check under `CI=true`. |

A check name uses only letters, digits, `_` and `-`. A malformed `check.` key (a bad name, a `ci` value other than `on` or `off`, or an attribute with no command) exits 2 before any check runs. Other unknown keys are ignored by the gate, and `doctor` reports them. A config saved with CRLF line endings reads like one with LF.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `CI` | unset | `true` makes `check --ci` run only the declared checks with `ci=on`. CI hosts such as GitHub Actions set it. |
| `GITHUB_HEAD_REF` | unset | When it is set, it is the current branch name, even on an attached HEAD. Waivers and the branch's base use it. CI sets it on pull requests, where HEAD is detached (FRD-04 §4, rule 5). |
| `GAUNTLET_COMMIT_BUDGET_MS` | `5000` | The commit budget, in milliseconds. A value that is not a whole number makes the commit gate and `status` exit 2. Over budget, `status` lists the commit rules at or over it and the commit gate prints `[slow]`. That only warns and never changes the exit code. |
| `GAUNTLET_TODAY` | today | The day `status` measures shadow rules against, as `YYYY-MM-DD`. A value that is not a real date exits 2. Mostly for tests. |
| `GAUNTLET_LOCK_WAIT` | `30` | How many seconds `install` and `install-hooks` wait for the install lock. A decimal number of at most four digits, polled five times a second; `0` does not wait. Anything else exits 2. |
| `GAUNTLET_LIB` | the runner's own `lib/` | Where the built-in output formats are read from. Leave it unset. |
| `TMPDIR` | `/tmp` | Each run makes one `gauntlet.XXXXXX` directory here for its scratch files, and removes it on exit and on HUP, INT and TERM. The pre-push hook line also makes a temp file here. |

`GAUNTLET_TMP`, `GAUNTLET_PARTIAL` and `GAUNTLET_LOCK` are the runner's own: whatever the environment holds under those names is dropped at start. Git's pathspec switches (`GIT_GLOB_PATHSPECS` and its siblings) are unset, and detectors run without `RIPGREP_CONFIG_PATH`, so one machine's flags cannot change what a rule finds.

## Files

| Path | Written by |
|---|---|
| `.gauntlet/rules/<id>.md` | You |
| `.gauntlet/formats/<name>.md` | You, for an output format that no built-in covers |
| `.gauntlet/config` | You |
| `.gauntlet/baseline.tsv` | `gauntlet baseline`, and the commit gate when it tightens. Never by hand. |
| `.gauntlet/exceptions.tsv` | `waive`, `loosen`, `remove`. A `script` row is added by hand. |
| `.gauntlet/STATUS.md` | `gauntlet status`. Ignored by `.gauntlet/.gitignore`. |
| `.gauntlet/.gitignore` | `gauntlet install`: it adds the lines it needs to an existing one and keeps yours. |
| `.gauntlet/bin/`, `.gauntlet/lib/` | `gauntlet install` |
| `.git/gauntlet-time.tsv` | The commit gate: the per-rule times of its last run. It lives in the git dir of the worktree and is never committed. |
| `.git/gauntlet-install.lock`, `.gauntlet/.install.lock` | `install` and `install-hooks`, while they run. See [the install lock](#the-install-lock). |

## `install` and what it creates

`gauntlet install` creates exactly this, and `install-hooks` adds the hooks:

| Path | What it holds |
|---|---|
| `.gauntlet/bin/gauntlet` | the runner |
| `.gauntlet/lib/*.sh` | its libraries |
| `.gauntlet/lib/formats/*.md` | the built-in output formats |
| `.gauntlet/rules/` | empty, for your rules |
| `.gauntlet/baseline.tsv` | empty until `gauntlet baseline` runs |
| `.gauntlet/exceptions.tsv` | the header row only |
| `.gauntlet/config` | `touched=off` |
| `.gauntlet/.gitignore` | `STATUS.md` and `.install.lock/`, then a `!` line for each file the runner reads from the working tree (the runner, its libraries and formats, your rules and formats, the config, the baseline, the exceptions and this file), so a root `.gitignore` such as `lib/`, `*.sh` or `*.tsv` cannot hide them |
| `pre-commit` and `pre-push` hooks | a new file, a line in an existing one, or a line printed for you: see [hooks](gates.md#hooks-coexist-never-take-over) |

An existing file is never overwritten. The two vendored folders are replaced, and an existing `.gauntlet/.gitignore` gets the lines it lacks added, with yours kept. `install` prints what it did (`created …`, `vendored runner to .gauntlet/`, `updated .gauntlet/.gitignore: added 15 lines`).

### The install lock

`install` and `install-hooks` serialize with a lock, so the `prepare` scripts of a monorepo can run them at the same moment. The lock is a directory made with `mkdir`: `gauntlet-install.lock` in the git common dir when the hooks directory is there (linked worktrees share it), and `.gauntlet/.install.lock` for every other layout (husky, a hooks directory in the worktree, a hook manager's config, a shared directory that is only printed). The two commands of one layout take the same lock.

- A command that finds the lock held waits `GAUNTLET_LOCK_WAIT` seconds and says so once: `gauntlet: waiting for another install to finish (<lock>)`.
- After the wait it gives up: `gauntlet: another install holds <lock>; if none is running, remove it`, exit 2.
- A lock left by a process killed with SIGKILL is never removed on a guess. Remove it by hand with `rmdir <lock>`, once you know no install is running. Do not remove it while one runs: the run that made the lock removes whatever directory is at that path when it ends.
- A git dir that is not writable is an error, not a fallback: `gauntlet: cannot lock: <dir> is not writable; fix the permissions`. A file named `.gauntlet` gives `gauntlet: cannot lock: .gauntlet is not a directory; remove or rename it` in the layouts whose lock lives in `.gauntlet/`. In the default `.git/hooks` layout the lock is in the git dir, and `install` stops earlier, at `gauntlet: cannot create .gauntlet`. Both exit 2.

An `install` killed halfway leaves `.gauntlet/.bin.new`, `.gauntlet/.lib.new` or `.gauntlet/.bin.old`, `.gauntlet/.lib.old`; the next `install` puts the runner right and removes them.

### Uninstall

There is no uninstall command. To remove gauntlet from a repo:

1. Delete every line of your hooks that runs `.gauntlet/bin/gauntlet`. `grep -rn 'gauntlet/bin/gauntlet' <hooks directory>` finds them: `.git/hooks`, `.husky`, or the directory in `core.hooksPath`. The lines end in `# gauntlet`, except the guarded lines `install-hooks` prints for a shared hooks directory (`if [ -d .gauntlet ]; then …; fi`), which carry no marker. For a script linked as both hooks, delete the `if [ "${0##*/}" = pre-commit ]; then … fi` blocks you added. A hook that gauntlet created holds only a shebang and its line; delete the file.
2. In a lefthook or prek config, delete the `gauntlet` commands or hooks you pasted.
3. Delete `.gauntlet/bin/` and `.gauntlet/lib/`. Delete the rest of `.gauntlet/` too if you want the rules, baseline and exceptions gone.
4. Delete the CI job, and `.git/gauntlet-time.tsv` if you like.

## `status`, `promote` and `doctor`

### `status`

`gauntlet status` reads `.gauntlet/baseline.tsv` as it is in the working tree (no detector runs). It prints, and writes to `.gauntlet/STATUS.md`, this text:

```
| rule | severity | total |
| --- | --- | --- |
| silent-catch | block | 2 |
| todo | shadow | 2 |

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
- `install` ignores `.gauntlet/STATUS.md` in `.gauntlet/.gitignore`. If you track it anyway, each `status` run that changes it makes the tree dirty, and `check --ci` refuses a dirty tree.
- If `.gauntlet/STATUS.md` is a symlink, `status` replaces it with a regular file.

### `promote`

`gauntlet promote <id>` changes `severity: shadow` to `severity: block` in the rule's file, and leaves every other byte alone. It prints `promoted <id>: shadow -> block; commit the rule file`. It exits 2, and changes nothing, for an unknown rule or for a rule whose severity is not `shadow`.

### `doctor`

`gauntlet doctor` prints one line per check: `ok <thing>`, `FAIL <thing>: <how to fix>`, or `note <thing>` for something it could not check, which is neither. It exits 1 on any FAIL, and 2 when it cannot run (not in a git repo, or no `.gauntlet/` directory). It never touches the network. It runs ten groups of checks, in this order:

1. **Tools.** Each rule's tool must be on `PATH`. For an `ast-grep` rule the tool is `ast-grep`. For `rg`, `linter` and `script` rules it is the first word of the detector. A first word with a quote, `$`, `=`, `~` or a backtick is not checked, and `doctor` says so with a `note`.
   - `FAIL tool <tool> for rule <id> is missing: <install hint>`, or `install it or fix the detector in .gauntlet/rules/<id>.md` when there is no hint.
   - `note tool for rule <id> not checked: the detector starts with <word>, which is not a plain command name, so doctor cannot tell whether it exists`
2. **Runner.** The vendored runner must be complete and run `--version`.
   - `FAIL .gauntlet/lib lacks files the runner sources (<names>): run gauntlet install to re-vendor`
   - `FAIL runner at <path> is not executable; run chmod +x '<path>'`
   - `FAIL .gauntlet/bin or .gauntlet/lib is broken or missing: run gauntlet install from a gauntlet checkout …`
3. **Formats.** Each rule's format must be built in or in `.gauntlet/formats/`.
   - `FAIL rule <id>: format <name> is unknown: use a built-in format or add .gauntlet/formats/<name>.md`
4. **Hooks.** Each hook must hold exactly one gauntlet line, the current form of its stage, or the lefthook or prek config must hold both commands.
   - `FAIL <stage> gate missing from <file>: run gauntlet install-hooks`, or `add this line by hand as the first command …` for a hook that `install-hooks` would only print.
   - `FAIL <stage> gate in <file> is an older gauntlet line (it differs from the current one): run gauntlet install-hooks`, or `replace the line ending in "# gauntlet" in <file> with: <line>` when it would only print.
   - `FAIL <file> has N lines ending in "# gauntlet" (lines a, b, ...); keep one, the current form, and remove the others`
   - `FAIL <stage> hook <file> is not executable: chmod +x '<file>'`
   - `FAIL gate missing from <config>: run gauntlet install-hooks and add the snippet it prints`
   - `FAIL lefthook pre-push gate in <file> has no use_stdin: true, so it judges the checked-out branch whatever git pushes: add use_stdin: true`
   - `FAIL <stage> gate in <file>: shared hooks directory: the gate must use the guarded form; run gauntlet install-hooks to see it`
5. **Ignored files.** No file of gauntlet's may be hidden from git. It lists every untracked file under `.gauntlet/` that git ignores, apart from `STATUS.md`, the lock and editor junk, and names the rule that hides it. It does not judge intent: a file you hide on purpose is listed too.
   - `FAIL a root ignore rule hides <paths> (<source>:<line>:<pattern>); remove or narrow that rule`
   - `FAIL required lines are missing from .gauntlet/.gitignore, so a root ignore rule hides <paths> (…): run gauntlet install to add them`
   - `FAIL .gauntlet/ is ignored by git (<source>:<line>:<pattern>): nothing in it can be committed; remove or narrow that rule`
   - `FAIL gauntlet: cannot read .gauntlet/.gitignore; fix the permissions`
6. **Base.** The base the gates would use must resolve in this clone.
   - `note base <ref> is not fetched yet; the gates fetch it`, for an `origin/` ref when a remote `origin` exists.
   - `FAIL base <ref> does not resolve; set base=<ref> in .gauntlet/config (all branches), or run gauntlet base <ref> (this branch only)`
7. **Baseline.** The committed baseline must equal the measurement.
   - `FAIL baseline differs from the code: run gauntlet baseline and commit it`
   - `FAIL baseline .gauntlet/baseline.tsv is missing: run gauntlet baseline and commit it`
8. **Config.** The keys must be `base`, `touched` (`on` or `off`) or `check.*`.
   - `FAIL config key <key> is not known; use base, touched or check.<name>`
   - `FAIL config line <n> has no '=': write key=value`
   - `FAIL touched must be on or off, got [<value>]: fix the touched line in .gauntlet/config`
9. **Rules.** Each rule must pass the required-fields check in [Rules & detectors](rules-and-detectors.md#rule-file): `FAIL rule <id>: <problem>; fix .gauntlet/rules/<id>.md`.
10. **Waivers.** `stale waive <path> (branch <branch>)` lists the waivers of other branches. They never fail.

Limits:
- Hooks: `doctor` checks that the gate line is there, not that it is reached. See [hooks](gates.md#what-doctor-checks-and-what-it-does-not). A lefthook `use_stdin: true` anywhere in the file satisfies the check, even on another command.
- If `.gauntlet/lib` is missing, the vendored script stops at startup with a `No such file` error and exit 1, before `doctor` prints anything. Run `gauntlet install` again from the checkout.
- `doctor` cannot tell a truncated file in `.gauntlet/lib` from a good one, unless it is empty.

## Known limits

These are known and not handled yet:
- A declared check has no timeout, so a hanging check holds the gate.
- A `status` that is killed with SIGKILL can leave `.gauntlet/.STATUS.md.<pid>` behind. Delete it.
- The detector files that the loosening check follows, and the ones it does not, are listed under [Exceptions](exceptions.md#which-detector-files-the-check-sees).
- Detectors, hooks and the install lock each have limits that are written where they are described: [Contract](rules-and-detectors.md#contract), [the hook line](gates.md#the-hook-line), [the install lock](#the-install-lock).
