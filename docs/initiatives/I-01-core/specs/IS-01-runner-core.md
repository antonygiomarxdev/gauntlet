# Implementation Spec — Runner core

**Status:** Approved by Antony Giomar Hernández on 2026-10-22
**Technical Proposal:** [TP-01 — gauntlet](../../../architecture/TP-01-gauntlet.md)
**FRD criteria covered:** see §FRD acceptance mapping below
**ADRs applied:** [0001](../../../adr/0001-runner-is-bash-awk-git.md) · [0002](../../../adr/0002-fingerprints-not-line-numbers.md) · [0003](../../../adr/0003-baseline-is-derived.md) · [0004](../../../adr/0004-declarative-detectors-only.md) · [0005](../../../adr/0005-exceptions-are-human-only-rows.md) · [0006](../../../adr/0006-coexist-with-existing-hooks.md) · [0007](../../../adr/0007-commit-time-check-in-pre-commit.md) · [0008](../../../adr/0008-base-is-the-branch-target.md) · [0009](../../../adr/0009-shadow-first-manual-promotion.md)
**Depends on:** none

> **For agentic workers:** execute task by task, test first. Steps use checkboxes (`- [ ]`) for tracking. Each task becomes one GitHub issue (`Path: full`, naming this spec and its task number).

## Objective

Ship the bash runner. It measures rules, keeps the baseline exact, and gates commits, pushes and CI, so a repository can adopt gauntlet by hand before the skill exists (release criteria CORE-PA1 and CORE-PA2).

## Design

- `bin/gauntlet` is a thin dispatcher that sources `lib/*.sh`.
- Each lib file owns one concern: config, rules, path selection, detectors, measurement, base resolution, checks, exceptions or hooks.
- Data moves between stages as TSV files in a temp dir for each run, and awk does every join.
- Tests build throwaway git repos and run the real binary.
- Stack: bash (3.2-compatible), POSIX awk, git, `rg` and `ast-grep` as detector engines, shellcheck, and GitHub Actions on ubuntu and macOS.

## Scope

**Out of scope:** owned by IS-02 (skill and agent integration) and IS-03 (linter depth), per the [TP decomposition](../../../architecture/TP-01-gauntlet.md#15-implementation-spec-decomposition):
- the skill (`onboard`, the `status` trend, `propose-rule`, `add-rule`);
- `HOW-TO-WRITE-A-RULE.md` and the `AGENTS.md` block;
- the Claude Code adapter;
- CI job generation and PR comments;
- the shared linter cache, guards and graduation;
- `fix` and `update`;
- the catalog.

## Global Constraints

- The runner uses only bash, awk, git and coreutils (`sed sort grep mktemp date cat cp mkdir rm`). No jq, Node, Python or compile step. Source: [ADR-0001](../../../adr/0001-runner-is-bash-awk-git.md).
- Bash 3.2 compatible (macOS default): no associative arrays, `mapfile`, `readarray`, `${x,,}`, `declare -n` or `|&`.
- POSIX awk (BWK awk on macOS): no `gensub`, `asort`, `strftime`, `systime`, `\s` or `{n}` intervals.
- Every `sort` and `comm` runs under `LC_ALL=C`.
- Exit codes: `0` passes, `1` means the gate failed, `2` means the setup is broken or the usage is wrong.
- A fingerprint is `rule + path + normalized line text`. Line numbers are never stored. Source: [ADR-0002](../../../adr/0002-fingerprints-not-line-numbers.md).
- Normalization strips `\r`, collapses runs of spaces and tabs to one space, and trims both ends.
- The commit-time check runs in **`pre-commit`**, not `commit-msg`. A spike on git 2.43 showed that a baseline staged in `commit-msg` is left out of the commit. The docs were corrected in `d27c8c2`.
- `shellcheck -x bin/gauntlet lib/*.sh test/*.sh` is clean.
- Every behaviour starts with a failing fixture test (CONTRIBUTING).
- Conventional Commits, with no trailers of any kind.
- A user-visible change adds a `changie new` fragment.
- Layout:
  - In this repo: `bin/gauntlet` and `lib/*.sh`.
  - In a consuming repo: `.gauntlet/bin/gauntlet` and `.gauntlet/lib/*.sh`.
  - `bin/gauntlet` finds its libs at `$(dirname "$0")/../lib`.

## Decisions this plan makes (owner may override)

1. **The runner is split into `lib/` files and vendored as a folder.** Design §6 lists only `bin/gauntlet`; split files keep each concern small enough to review.
2. **`check --ci` refuses a dirty tree.** It exits 2 when tracked files differ from `HEAD`, with the message `gauntlet checks what you push; commit or stash first`. Measuring the working tree while pushing `HEAD` would break parity. Untracked files do not count.
3. **Partial staging** (HOOK-AC3). The `pre-commit` check runs on the working tree. When a staged file also has unstaged changes, auto-tighten is skipped and a notice is printed. Push and CI still verify the exact baseline. The ceiling: a commit check can pass on code that is not what gets committed. The push gate catches it.
4. **lefthook and prek configs are not edited.** They can be YAML, TOML or JSON. `install-hooks` prints the exact snippet for them and does not edit the file. `doctor` fails until the snippet is present. husky, a `core.hooksPath` inside the repo and plain `.git/hooks` get the line added automatically. A shared hooks directory outside the repo is printed only, in a guarded form that does nothing where the repository has no `.gauntlet/` (R25, R53).
5. **Waivers apply only on their own branch.** A `waive` row applies only when its `branch` column equals the current branch (`GITHUB_HEAD_REF` in CI, `git symbolic-ref --short HEAD` locally). Rows from merged branches are ignored, and `doctor` lists them as stale. Deleting them on merge is left for later.
6. **Loosening needs a new exception row.** A `loosen` or `remove` row counts only if it is new since the merge-base: present in the current `exceptions.tsv` and absent from the base's. Otherwise one old row would permit every future loosening.
7. **New rules, and the onboarding branch, are exempt from checks 1–3.**
   - A rule whose file does not exist at the merge-base is exempt from new, global and touched ([GATE-AC10](../frd/FRD-03-push-and-ci-gate.md)).
   - When the merge-base has no `.gauntlet/baseline.tsv`, checks 1–3 are skipped with the note `no baseline at base`.
8. **Detector exit codes.**
   - `0` is fine.
   - `1` is fine when stdout is empty or parses; with output that does not parse, the detector is broken.
   - `127` means a missing tool, and the error names the install command.
   - Any other code means the detector is broken.

   This matches `rg` (1 = no match) and `ast-grep` (1 = matches found, 6 = bad rule; see the spike output in Task 4).

## Review Focus

1. **Paths with spaces or non-ASCII characters** must survive `{files}` substitution and output parsing. Tested in Task 4.
2. **CRLF files and files edited on Windows** must fingerprint the same as LF. Tested in Task 5.
3. **CI runs on a detached HEAD.** Waivers must resolve the branch from `GITHUB_HEAD_REF`, or they silently never apply. Tested in Task 10.
4. **The onboarding PR, and a PR that adds a rule,** must not fail on the debt they introduce. Tested in Task 8.
5. **A hook file whose last line is `exit 0`,** common in hand-written hooks, must still run the gate. The gauntlet line goes first, right after the shebang, so no early exit, trailing exit, `exec` or failing last command can skip it (R26). Tested in Task 13.

---

### Task 1: Scaffold, test harness, self-CI

**Files:**
- Create: `bin/gauntlet`, `lib/core.sh`, `test/run.sh`, `test/lib.sh`, `test/core.test.sh`, `.github/workflows/test.yml`

**Interfaces:**
- Produces from `lib/core.sh`:
  - `die <msg> [code=2]`, which prints `gauntlet: <msg>` to stderr and exits;
  - `repo_root`, which prints the absolute top-level path;
  - `config_get <key> [default]`, which reads `.gauntlet/config` as `key=value` lines, skips `#` comments, and returns the last value set;
  - `now_ms`, in milliseconds from `date +%s%N`, falling back to seconds × 1000 when `%N` is unsupported;
  - `GAUNTLET_VERSION=0.1.0-dev`.
- Produces from `test/lib.sh`:
  - `$G` is the absolute path to `bin/gauntlet`.
  - `mkrepo` creates `$TMP/repo` and `cd`s into it. The repo has branch `main`, a user config, `.gauntlet/{rules/,config,baseline.tsv,exceptions.tsv}`, and an initial commit.
  - `rule <id> [key=value ...]` writes `.gauntlet/rules/<id>.md`. Defaults:
    - `severity=block`, `stage=commit`, `engine=rg`;
    - `detector=rg --with-filename --line-number --no-heading 'TODO' {files}`;
    - `paths=**`, `exclude=`;
    - `fix=remove it`, `source=pending`, `since=2026-10-22`.
  - Assertion helpers:
    - `run <cmd...>` captures `$OUT` (stdout and stderr) and `$STATUS`;
    - `assert_eq`;
    - `assert_contains <haystack> <needle>`;
    - `assert_not_contains`.
- Produces from `test/run.sh [group]`: sources each `test/<group>.test.sh`, or all of them, and runs every `test_*` function in its own subshell with a fresh `$TMP`. Prints `ok <name>` or `FAIL <name>: <msg>`, and exits 1 if any test fails.

- [ ] **Step 1: Write failing tests** in `test/core.test.sh`:
  - `test_version` asserts that `$G --version` prints `gauntlet 0.1.0-dev` with status 0;
  - `test_unknown_command` asserts that `$G nope` has status 2 and output containing `unknown command: nope`;
  - `test_config_last_wins` writes `touched=off` then `touched=on` and asserts that `config_get touched` returns `on` (source `lib/core.sh` inside `mkrepo`).
- [ ] **Step 2:** Run `test/run.sh core`. Expected: FAIL, because `bin/gauntlet` is missing.
- [ ] **Step 3:** Implement `bin/gauntlet`:
  - `set -eu`;
  - source the libs;
  - a `case` dispatch on `$1` that handles `--version` and otherwise calls `die "unknown command: $1"`.

  Implement `lib/core.sh` and the harness.
- [ ] **Step 4:** Run `test/run.sh` and `shellcheck -x bin/gauntlet lib/*.sh test/*.sh`. Expected: all ok.
- [ ] **Step 5:** Write `.github/workflows/test.yml`:
  - triggers: `on: [push, pull_request]`;
  - matrix: `ubuntu-latest` and `macos-latest`;
  - checkout with `fetch-depth: 0`;
  - install tools: on ubuntu, `sudo apt-get install -y ripgrep shellcheck` and `pipx install ast-grep-cli`; on macOS, `brew install ripgrep ast-grep shellcheck`;
  - then run shellcheck and `test/run.sh`.

  Validate the YAML with `python3 -c 'import yaml,sys;yaml.safe_load(open(sys.argv[1]))' .github/workflows/test.yml`.
- [ ] **Step 6:** Commit: `chore: add runner skeleton, test harness and CI`.

### Task 2: Rule files

**Files:**
- Create: `lib/rules.sh`, `test/rules.test.sh`

**Interfaces:**
- Produces:
  - `rule_get <file> <key>` prints the value from the frontmatter (the lines between the first two `---` lines, `key: value`). A trailing `  # comment` is stripped only for `severity`, `stage`, `engine`, `since` and `format` (R2), because detector strings may contain ` #`.
  - `rule_ids` prints the stems of `.gauntlet/rules/*.md`, sorted, without the Markdown case files (`<id>.bad.md`, `<id>.good.md`, `<id>.bad.<n>.md`).
  - `rule_validate <file>` prints one `<file>: <problem>` per error and returns 1 if there are any. Requirements:
    - the frontmatter is closed by a second `---` line (`frontmatter not closed`);
    - `id` equals the file stem;
    - `severity` ∈ {block, shadow, track};
    - `stage` ∈ {commit, push}, defaulting to `commit`;
    - `engine` ∈ {linter, ast-grep, rg, script};
    - `detector`, `fix` and `source` are non-empty;
    - `since` matches `YYYY-MM-DD`;
    - `engine=script` requires an `exceptions.tsv` row `script	<id>…`.

    `baseline`, `check --ci` and `check --staged` run `rule_validate` on every rule before they measure anything, whatever its `stage`, and exit 2 with `rule <id>: <problem>; run gauntlet doctor` for each problem (R27, RULE-AC1, RULE-AC2).
  - `severity_rank <sev>` prints block=3, shadow=2, track=1, and returns 1 for any other severity (R9).

- [ ] **Step 1: Failing tests:**
  - `test_get_strips_comment_on_enum_keys`: `severity: block   # block | shadow` returns `block`.
  - `test_get_keeps_hash_in_detector`: `detector: rg '# x' {files}` returns the string unchanged.
  - `test_validate_rejects_bad_severity`: `severity=hard` makes validation return 1 with output containing `severity`.
  - `test_validate_script_needs_exception`: `engine=script` with no exception row returns 1, and passes once the row is added.
  - `test_ids_sorted`: rules `b` and `a` print `a\nb`.
- [ ] **Step 2:** Run `test/run.sh rules`. Expected: FAIL.
- [ ] **Step 3:** Implement `lib/rules.sh`, using one awk program for frontmatter parsing.
- [ ] **Step 4:** Run `test/run.sh rules`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: parse and validate rule files`.

### Task 3: Path selection

**Files:**
- Create: `lib/paths.sh`, `test/paths.test.sh`

**Interfaces:**
- Produces:
  - `select_files <paths> <exclude>` reads paths on stdin and prints those that match any glob in `paths` and no glob in `exclude`. Both are space-separated glob lists; an empty `paths` means `**`.

    Glob to regex, done in awk as one left-to-right scan, so the escaping never touches the brackets the scan produces (R10):
    - `**/` becomes `(.*/)?`;
    - `**` becomes `.*`;
    - `*` becomes `[^/]*`;
    - `?` becomes `[^/]`;
    - every other regex metacharacter is escaped;
    - the result is anchored with `^…$`.
  - `tracked_files` prints the files in the index that exist on disk, once each: `git ls-files -t -c -d -z`, with the deleted ones dropped. Untracked files are left out, so a local measurement equals what CI sees (R19). Gitlinks (submodules), skip-worktree entries and symlinks whose target is missing are left out too: no detector can read them. `baseline`, `check --ci` and the rule tests of `check --ci` read this list.
  - `all_files` prints the same list, dangling symlinks included, plus the untracked files git does not ignore (`git ls-files -o --exclude-standard -z`). Only `test-rules` uses it, for case discovery, because a rule being written has untracked cases.
  - A tracked path that holds a tab or a newline fails closed: exit 2, `gauntlet: path with a tab or newline: <name>; rename the file`, because the TSV tables cannot carry such a name (R31, which replaces R21). Only the paths that survive the branch are checked: a diff or tree listing that names such a path being removed or renamed does not refuse. An untracked path like that is left out of `all_files`.
  - `staged_files` runs `git diff --cached --name-only --diff-filter=ACMRT`, which adds type changes, and leaves out gitlinks and dangling symlinks.

- [ ] **Step 1: Failing tests:**
  - `test_double_star_matches_root_and_nested`: with exclude `**/*.test.ts`, both `a.test.ts` and `x/y/a.test.ts` are excluded.
  - `test_single_star_stays_in_dir`: `src/*.ts` matches `src/a.ts` but not `src/x/a.ts`.
  - `test_dot_is_literal`: `*.ts` does not match `axts`.
  - `test_staged_files_excludes_deleted`: stage a deletion and a modification; only the modified path is printed.
- [ ] **Step 2:** Run `test/run.sh paths`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `test/run.sh paths`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: select files by rule globs`.

### Task 4: Detectors

**Files:**
- Create: `lib/detect.sh`, `lib/formats/path-line.md`, `lib/formats/github.md`, `lib/formats/tsc.md`, `test/detect.test.sh`, `test/fixtures/ast-grep-github.txt`

**Interfaces:**
- Consumes: `rule_get`, `select_files`.
- Produces: `run_detector <rule-file> <files-list-file> <out-tsv>`. It writes `rule	path	line	message` rows and returns 0, or 2 with a message on stderr. The command is built per engine:
  - **`rg`, `linter`, `script`:** the `detector` string, with `{files}` replaced by the single-quoted paths (an embedded `'` becomes `'\''`, and a path that starts with `-` is passed as `./<path>`, so a tool reads it as a path), run by `bash -o pipefail -c` from the repo root, with stdin on `/dev/null` and `RIPGREP_CONFIG_PATH` unset (a developer's ripgrep flags would change the rows on one machine and not on CI).
    - The path list is split into batches of at most 25000 bytes, the command's own text counted against that budget, and the detector runs once per batch (R13). A batch that exits 2 or more makes the detector broken.
    - A stage of the command's last pipeline, other than its last stage, that exits 2 or more (not 141, SIGPIPE) makes the detector broken, so `rg … | grep …` cannot hide a crashed `rg`. Limits: only the last pipeline of the text is judged, and a subshell `(a | grep x)`, `set -e` and `a | grep x || true` hide a crash.
    - With an empty file list and `{files}` present, the detector is not run at all. `measure` also skips a rule with no file in scope, `{files}` or not (R30).
    - Without `{files}`, it runs as-is. This is the whole-program case: output is filtered by the rule's `paths` and `exclude` instead of the input list, and then by `measure` to the tracked files (the staged ones at commit) that are not under `.gauntlet/` (R15, R28).
  - **`ast-grep`:** `ast-grep scan --rule '<detector>' --format github --error {files}`. `--error` makes every match exit `1` whatever the severity in the rule file; without it a rule at the default severity (`hint`) prints nothing and the gate would pass over it.
  - **Parsing through output formats** (FRD-02 §4.14). No format is hard-coded in `detect.sh`.
    - `load_format <name>` reads `.gauntlet/formats/<name>.md` if present, else `<runner>/lib/formats/<name>.md`, else returns 2 with `unknown format <name>`. Frontmatter keys: `match` (ERE), `path`, `line`, `message` (group numbers from 0 to 9, `message` optional; a larger number is exit 2, `format <name>: <key> is group <n>; use a group from 0 to 9`), `ignore` (ERE, optional).
    - The rule's `format` defaults to `github` for `engine: ast-grep` and `path-line` otherwise.
    - Each output line is tried against `ignore`, then rewritten with `sed -E` using `match` and the group numbers into `path<TAB>line<TAB>message`. Use a control character as the `s` delimiter so patterns may contain `/`, and build the tab with `printf`, because BSD sed does not expand `\t`.
    - A non-empty line that matches neither pattern makes the detector broken (exit 2, `broken detector: <rule>: unparsed line: <line>`), whatever the detector's exit code.
    - Built-in formats:
      - `path-line`: `^([^:]+):([0-9]+)(:[0-9]+)?(: ?(.*))?$`, path 1, line 2, message 5; `ignore: ^[^:]+: binary file matches \(found`, the line `rg` prints for a binary file it matched. The path cannot contain `:`, a known ceiling; `rg --with-filename` paths from the repo never hit it in practice.
      - `github`: `^::(error|warning|notice) file=([^,]+),line=([0-9]+)[^:]*::(.*)$`, path 2, line 3, message 4.
      - `tsc`: `^(.+)\(([0-9]+),[0-9]+\): (error|warning) (.*)$`, path 1, line 2, message 4; `ignore: ^Found [0-9]+ errors?`.
    - Each built-in format file carries its cases in its body: a fenced `sample` block and a fenced `expected` block of rows. `test-rules` runs them (Task 6).
    - A leading `<repo root>/` and then a leading `./` are stripped from the path.
    - Rows whose path is not in the input list are dropped.
    - NUL bytes in the output are removed. Control bytes in anything gauntlet prints from a detector or a path are written `\xNN` (`path_spell`, `report_spell`).
  - **Exit codes** follow decision 8. A missing tool fails with `missing tool <x>`; for `rg` and `ast-grep` the message adds the install hint `brew install ripgrep ast-grep | apt install ripgrep; pipx install ast-grep-cli`.

- [ ] **Step 1:** Record the fixture by running `ast-grep scan --rule r.yml --format github x.ts > test/fixtures/ast-grep-github.txt`, using the empty-catch rule from `docs/guide/rules-and-detectors.md` with `severity: error`. The expected line shape is `::error file=x.ts,line=1,endLine=1,title=silent-catch::empty catch`. ast-grep 0.51 exits `1` on matches (with `--error`, which the runner always passes, whatever the rule's severity), `0` when clean, and `6` or `8` when the rule file is missing or not valid; the runner treats any exit above `1` as a broken detector.
- [ ] **Step 2: Failing tests:**
  - `test_rg_rows`: a file containing `TODO` on line 2 produces the row `todo	a.ts	2	…`.
  - `test_path_with_space`: the file `my dir/ä b.ts` is detected, with the path preserved.
  - `test_ast_grep_parse`: a stub detector that `cat`s the fixture and exits 1 yields `silent-catch	x.ts	1	empty catch`.
  - `test_exit1_empty_is_clean`: rg with no match yields 0 rows and status 0.
  - `test_unparseable_output_fails_closed`: the detector `echo garbage; exit 1` returns 2 with stderr containing `broken detector`.
  - `test_unmatched_line_fails_even_on_exit0`: the detector `echo garbage; exit 0` returns 2 with stderr containing `unparsed line: garbage` (RULE-AC16).
  - `test_project_format_no_runner_change`: `.gauntlet/formats/mylint.md` with `match: ^([^|]+)\|([0-9]+)\|(.*)$`, path 1, line 2, message 3; a rule with `format: mylint` whose detector prints `a.ts|7|bad thing` yields `r	a.ts	7	bad thing` (RULE-AC15).
  - `test_ignore_drops_summary_line`: with the `tsc` format, `Found 2 errors.` is ignored and the two error lines become rows.
  - `test_project_format_overrides_builtin`: a project `path-line.md` is used instead of the built-in one.
  - `test_unknown_format_is_broken_setup`: `format: nope` returns 2 with `unknown format nope`.
  - `test_missing_tool`: detector `nosuchtool {files}` returns 2 with `missing tool nosuchtool`.
  - `test_output_filtered_to_inputs`: the detector prints a row for a file not in the list, and the row is dropped.
  - `test_whole_program_filtered_by_paths`: a detector without `{files}`, with `paths=src/**`, drops a row for `lib/x.ts`.
- [ ] **Step 3:** Run `test/run.sh detect`. Expected: FAIL.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Run `test/run.sh detect`. Expected: PASS.
- [ ] **Step 6:** Commit: `feat: run declarative detectors and parse their output`.

### Task 5: Measure and `baseline`

**Files:**
- Create: `lib/measure.sh`, `test/measure.test.sh`
- Modify: `bin/gauntlet` (add the `baseline` command)

**Interfaces:**
- Consumes: `run_detector`, `rule_ids`, `select_files`, `tracked_files`, `staged_files`.
- Produces:
  - `measure <mode> <workdir> [rule-ids...]`, where mode is `all` (tracked files only, R19) or `staged`. It writes:
    - `<workdir>/located.tsv`, with rows `rule	path	line	fingerprint	message`;
    - `<workdir>/measure.tsv`, with rows `rule	path	fingerprint	count`, `LC_ALL=C` sorted and with no header;
    - `<workdir>/time.tsv`, with rows `rule	ms`, which the check report prints under `[time]` (R17).

    The fingerprint text comes from the working-tree file's line, normalized per Global Constraints. Rule ids default to all rules. Stage filtering is the caller's job. Files under `.gauntlet/` are never measured, whatever a rule's `paths` say (R15), and only rows of the kept files (tracked, or staged at commit) are counted, whichever way a detector found them (R28). A matched file that cannot be read is exit 2, `gauntlet: cannot read <path>`.
  - `gauntlet baseline` validates every rule (R27), measures every rule in `all` mode and writes `.gauntlet/baseline.tsv`.

- [ ] **Step 1: Failing tests:**
  - `test_fingerprint_ignores_line_shift`: insert 3 blank lines above a violation and re-measure; `measure.tsv` is byte-identical.
  - `test_reformat_whole_file_same_fingerprints`: re-indent every line and turn spaces into tabs; the output is identical. FRD-02 requires this test.
  - `test_crlf_equals_lf`: the same content saved with CRLF gives an identical `measure.tsv`.
  - `test_count_duplicates`: two identical violating lines in one file give `count` 2.
  - `test_baseline_command_writes_file`: `$G baseline`, then `.gauntlet/baseline.tsv` equals the expected TSV.
- [ ] **Step 2:** Run `test/run.sh measure`. Expected: FAIL.
- [ ] **Step 3:** Implement. One awk pass reads the needed lines from each file and aggregates counts.
- [ ] **Step 4:** Run `test/run.sh measure`. Expected: PASS.
- [ ] **Step 5:** Run `changie new` (Added: "`gauntlet baseline` measures every rule into `.gauntlet/baseline.tsv`.").
- [ ] **Step 6:** Commit: `feat: fingerprint violations and write the baseline`.

### Task 6: `test-rules`

**Files:**
- Create: `lib/cases.sh`, `test/cases.test.sh`
- Modify: `bin/gauntlet`

**Interfaces:**
- Consumes: `run_detector`.
- Produces: `run_rule_tests [tracked]` returns 0 (all pass), 1 (a case fails) or 2 (the setup is broken) and prints failures as `  <id>  <case>  <problem>`. Cases are found among the files git lists that are not ignored (a rule being written has untracked cases), or among the tracked files only with `tracked`, which `check --ci` passes because a clone has no other (R28).
  - Cases are `.gauntlet/rules/<id>.bad*` and `<id>.good*`. Each is a file or a directory; a directory contributes every file under it. A Markdown case (`<id>.bad.md`) is a case and not a rule (`rule_ids` leaves it out).
  - The detector is run on the case paths explicitly, and the rule's `paths` and `exclude` are ignored.
  - `bad` must produce at least 1 row and `good` must produce 0.
  - A rule with no `bad` case fails with the problem `no cases`.
  - Every output format, built-in and project, is also tested, whether or not a rule uses it (a project file replaces the built-in of the same name, R16): its `sample` block is parsed and must equal its `expected` block. A format without both blocks fails with `no cases`.

  `gauntlet test-rules` wraps it, with exit 0, 1 or 2.

- [ ] **Step 1: Failing tests:**
  - `test_bad_flagged_good_clean_passes`;
  - `test_bad_not_flagged_fails` (the bad case has no `TODO`);
  - `test_good_flagged_fails`;
  - `test_directory_case`: a `bad` dir with two files, one violating, passes;
  - `test_rule_without_cases_fails`, with output containing `no cases`;
  - `test_format_sample_matches_expected`: each built-in format passes; a project format whose `expected` differs fails and names the format;
  - `test_format_without_cases_fails`, with output containing `no cases`.
- [ ] **Step 2:** Run `test/run.sh cases`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `test/run.sh cases`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: run each rule's bad and good cases`.

### Task 7: Base resolution

**Files:**
- Create: `lib/base.sh`, `test/base.test.sh`
- Modify: `bin/gauntlet` (add the `base` command)

**Interfaces:**
- Produces:
  - `resolve_base [ref]` picks the first that is set:
    1. the explicit ref;
    2. `git config branch.<cur>.gauntletBase`;
    3. `config_get base`, where a value that holds a control byte is exit 2, `bad base= in .gauntlet/config: <value>`;
    4. `origin/HEAD` resolved to `origin/<default>`;
    5. `main`. `master` is not tried: a repository whose default branch is `master` and has no `origin/HEAD` sets `base=`.
  - `resolve_base_default [ref]` is the same chain without step 3: the base a run would have if the tracked config had no `base=`. The loosening check of `base=` compares with it (R42).
  - `current_branch` returns `$GITHUB_HEAD_REF` when set, else `git symbolic-ref --short HEAD`, else `HEAD`.
  - `merge_base <ref>` runs `git fetch --quiet origin +refs/heads/<branch>:refs/remotes/origin/<branch>` first, with the credential prompt off, when the ref starts with `origin/`. A failed fetch prints `gauntlet: fetch of <ref> failed; using the local ref` and continues with the local ref. It then prints the sha. A ref that does not resolve is exit 2, `unknown ref: <ref>; set base=<ref> in .gauntlet/config (all branches), or run gauntlet base <ref> (this branch only)`, or `base <ref> given with --base does not resolve` when the ref came from `--base`. A shallow clone is exit 2, `shallow clone: fetch full history`: the merge-base is never guessed. `check --ci` fetches the default base the same way, through the same function, when it differs from the selected one (R55).
  - `at_base <sha> <path>` runs `git show <sha>:<path>`, printing nothing if the path is absent. `base_has <sha> <path>` returns 0 when the path is there, 1 when it is absent and 2 when git cannot tell, and an unreadable base is exit 2 and never an absent one (R32).
  - `gauntlet base [ref]` sets `branch.<cur>.gauntletBase` (on a detached HEAD: `detached HEAD: check out a branch first`), or prints the resolved base when called without a ref.

- [ ] **Step 1: Failing tests:**
  - `test_branch_config_wins`: after `$G base feature-a` on branch `feature-b`, `resolve_base` returns `feature-a`.
  - `test_falls_back_to_main` (no remote).
  - `test_github_head_ref`: with `GITHUB_HEAD_REF=pr-1` on a detached HEAD, `current_branch` returns `pr-1`.
  - `test_stacked_merge_base`: `main`, then `a`, then `b`; with base `a`, the merge-base is the tip of `a`, not of `main`.
- [ ] **Step 2:** Run `test/run.sh base`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `test/run.sh base`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: resolve the base from the branch target`.

### Task 8: `check --ci`, part one (new, global, exact, shadow, track)

**Files:**
- Create: `lib/check.sh`, `test/check.test.sh`
- Modify: `bin/gauntlet`

**Interfaces:**
- Consumes: `measure`, `resolve_base`, `merge_base`, `at_base`, `rule_get`, `severity_rank`.
- Produces: `check_ci [--ci] [--pre-push] [--base <ref>]`, the command `gauntlet check --ci`.
  - **Output format** (pinned for every later task):
    - header: `gauntlet  ci · <n> rules · <s> s`, with `1 rule` for one rule and `<s>` the whole run in seconds with one decimal;
    - `note:` lines, among the sections, for what is not a failure: `note: no baseline at base; new, global, shadow and track checks skipped`, `note: the vendored runner changed in this branch (.gauntlet/bin or .gauntlet/lib differ from the base); review it` (R37) and `note: loosened <rule>: <what>; covered by "<reason>"` (a loosening that a new row covers);
    - one section per failed check: `[new]`, `[global]`, `[touched]`, `[baseline]`, `[loosened]`, `[rule-tests]`, `[checks]`;
    - informational sections: `[shadow] would have failed` and `[track]`;
    - violation lines: `  <path>:<line>  <rule>  <message>`, each followed by `      fix: <fix>`;
    - timings: `[time]`, with one line per rule, and one per declared check and for the rule tests when they ran: `  <rule>  <ms> ms`, `  check:<name>  <ms> ms`, `  rule-tests  <ms> ms`;
    - final line: `gauntlet: ok`, or `gauntlet: FAIL (<n> problems)`, `1 problem` for one.

    There is no fail-fast: every check runs before the exit. Everything printed goes through `report_spell`, so control bytes in a path or a message are written `\xNN`.
  - **Dirty tree:** tracked files that differ from `HEAD` make it exit 2 (decision 2).
  - **`--pre-push`** is the flag the pre-push hook passes. It reads the ref lines git sends on stdin before anything else and exits 1 when a pushed branch tip (`refs/heads/*`, or a Gerrit `refs/for/*`) is not `HEAD`: `gauntlet checks the checked-out branch; check out <branch> and push again` (R35 as revised, R43), or, when the local ref is not a branch, `gauntlet checks the checked-out commit; check out the commit you are pushing and push again`. A delete (a zero local sha) and a ref in any other namespace (a tag, a note) are skipped. A stdin that is a terminal or empty judges `HEAD`, as a run by hand does. A line with fewer than four fields is exit 2, `gauntlet: unexpected pre-push input`. A manual run and CI never read stdin.
  - **New:** a `(rule,path,fingerprint)` of a `block` rule whose current count is higher than at base is reported. The rule must exist at base (decision 7), and the path must not be waived (waivers arrive in Task 10; Task 8 ships a stub that waives nothing).
  - **Global:** a `block` rule whose current total is higher than at base is reported as `  <rule>  <base> → <now>`.
  - **Exact:** `.gauntlet/baseline.tsv` must be byte-equal to `measure.tsv`. Otherwise the check prints `  baseline differs from the code; run gauntlet baseline and commit it`, followed by a unified diff of at most 20 lines.
  - **Shadow:** new fingerprints of shadow rules are listed under `[shadow]` and never fail.
  - **Track:** a rising total prints `  <rule>  <base> → <now> (+<d>); consider promoting` and never fails.

- [ ] **Step 1: Failing tests** (each one: commit the baseline on `main`, branch, change, commit, run `$G check --ci --base main`):
  - `test_new_violation_fails`: status 1, output contains `[new]`, `a.ts:`, `todo` and `fix: remove it`.
  - `test_moved_line_passes`: the violation moves within its file; status 0.
  - `test_global_rise_fails`: a second identical line in another file is listed in `[global]`.
  - `test_baseline_lie_fails`: hand-editing the baseline lower gives status 1 and `[baseline]`.
  - `test_shadow_never_fails`: with `severity=shadow` and a new violation, status 0 and output contains `would have failed`.
  - `test_track_rise_reports`: with `severity=track`, status 0 and output contains `consider promoting`.
  - `test_all_problems_reported_together`: a new violation and a baseline lie both appear, and the output says `FAIL (2 problems)`.
  - `test_onboarding_branch_skips_1_to_3`: there is no baseline at base; output contains `no baseline at base` and the status depends only on exact.
  - `test_new_rule_exempt`: a rule added in the branch, with existing debt and an exact baseline, gives status 0.
  - `test_dirty_tree_refuses`: status 2 and `commit or stash first`.
- [ ] **Step 2:** Run `test/run.sh check`. Expected: FAIL.
- [ ] **Step 3:** Implement. Each comparison is one awk program that joins two TSVs; keep them in `lib/check.sh` as named functions (`new_rows`, `global_rows`).
- [ ] **Step 4:** Run `test/run.sh check`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: gate new violations, rising totals and a lying baseline`.

### Task 9: Touched-file check

**Files:**
- Modify: `lib/check.sh`, `test/check.test.sh`

**Interfaces:**
- Produces: `cmp_touched <diff> <base.tsv> <measure.tsv> <rules.tsv> <waived>` (R20). It runs only when `config_get touched off` is `on`; any other value than `on` or `off` is exit 2, `touched must be on or off, got [<value>]`, so the gate is never turned off by a typo.
  - The changed set comes from `git diff -M -z --name-status <mb> HEAD` (at commit, the index against `HEAD`). Entries under `.gauntlet/` are dropped (R15), and a type change (`T`) is not judged.
  - `A`: the file must come out at 0.
  - `M`: if the base total is above 0, the current total must be strictly lower; if it was 0, it must stay 0.
  - `R<100`: the old path's base total is compared with the new path's current total.
  - `R100` and `D` are skipped.
  - Totals sum only `block` rules that exist at base, and waived paths are skipped.
  - Output line: `  <path>  <base> → <now>  (must go down)`, or `(must be 0)` for an added file, or `(must stay 0)` for a file with no debt at the base (R20).

- [ ] **Step 1: Failing tests:**
  - `test_touched_off_by_default`: a modified file with unchanged debt gives status 0.
  - `test_touched_requires_decrease`: with `touched=on`, editing a non-violating line of a file that has debt fails in `[touched]`.
  - `test_pay_one_any_rule_passes`: two rules; removing one violation of either one passes.
  - `test_added_file_must_be_zero`.
  - `test_pure_rename_skipped`.
  - `test_rename_with_edit_follows_old_path`.
- [ ] **Step 2:** Run `test/run.sh check`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `test/run.sh check`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: optional touched-file gate`.

### Task 10: Exceptions and the loosening check

**Files:**
- Create: `lib/exceptions.sh`, `test/exceptions.test.sh`
- Modify: `lib/check.sh` (use `waived_paths` in place of the Task 8 stub, add `cmp_loosened`), `bin/gauntlet`

**Interfaces:**
- Produces:
  - `.gauntlet/exceptions.tsv` has the header `type	target	reason	date	branch`.
  - `gauntlet waive <path> <reason>` appends `waive	<path>	<reason>	<today>	<current_branch>`. The path is relative to the repo root, without a leading `./` or a trailing `/`, and must exist in git or in the working tree. On a detached HEAD it exits 2.
  - `gauntlet loosen <rule> <what> <reason>` appends `loosen	<rule>: <what>	<reason>	<today>	-`. `<rule>` is a rule that exists in the working tree, in `HEAD` or at the merge-base (`gauntlet: no rule <id>` otherwise; a Markdown case file is not a rule), or `@config` (R34).
  - `gauntlet remove <rule> <reason>` appends `remove	<rule>	<reason>	<today>	-`, for a rule that exists in the same places.
  - An empty reason exits 2, and so does a missing `.gauntlet/` (`gauntlet: no .gauntlet/ directory; run gauntlet install`). No command writes a `script` row: `doctor` prints the row to add by hand.
  - `waived_paths` prints the paths the current branch waives (decision 5). It replaces the waiver stub of Task 8.
  - `cmp_loosened <mb> [<covered-file> [<default-base> [<hint-file>]]]`: for each rule file at base, any of the following without a new row (decision 6) is reported as `  <rule>  <what changed>`:
    - **removed** (`rule file removed`) needs a `remove` row;
    - **severity lowered** (a lower `severity_rank`) needs a `loosen` row whose target starts with `<rule>:`;
    - **`paths` narrowed** (a base glob missing from the current list) needs the same `loosen` row;
    - **`exclude` widened** (a current glob missing from the base list) needs the same `loosen` row;
    - **`engine` or `detector` string changed** needs the same `loosen` row;
    - **a file the detector names changed:** each word of an unchanged `detector` that names a file of the repository is judged by that file's content at the base and now (`detector file <path> changed`). The words are cut the way the shell cuts them, with nothing expanded (R44 and R56 list what is not followed);
    - **`format` changed, or the project format file it resolves to added, changed or removed** since the base, for a `block` rule, needs the same `loosen` row.

    A change of `stage` is not loosening: a push-stage rule is still enforced at push and in CI.
  - **`.gauntlet/config` is judged like a rule file, as the pseudo-rule `@config`** (R34, approved 2026-10-23): one new `loosen @config` row covers every item below, as a rule's row covers its changes. Reported as `  @config  <what changed>`:
    - `base <old> → <new>`: the bases the two files select differ, compared as bases (no `base=` selects the default base). It is judged against the selected base and against the default-resolved base (R42), because a committed `base=` can aim the run at the branch itself and CI names the target. A change only the default-base comparison finds, with no covering row, prints `gauntlet: base= is also judged against <default-base> (the base without it); add a row with gauntlet loosen @config "<what>" "<reason>", or run gauntlet base <selected> on this branch` (R54). The default base is fetched like the selected one, and a failed fetch warns and uses the local ref (R55);
    - `touched on → off` (deleting the line of an enabled gate counts);
    - `check <name> removed`, `check <name> ci on → off`, `check <name> paths narrowed: <prefix>` (`all files → <paths>` for an empty scope that gets one), `check <name> command changed`.

    Not loosening: a check added, `.ci` turned on, `.paths` widened, `touched` turned on, comments, blank lines and spacing.
  - A loosening that a new row covers is not reported as a problem. The report prints `note: loosened <rule>: <what>; covered by "<reason>"` for each (Task 8).

- [ ] **Step 1: Failing tests:**
  - `test_waive_exempts_new_on_branch`: on branch `f`, after `$G waive a.ts "reason"`, the new violation in `a.ts` passes `[new]` while the global total still applies.
  - `test_waive_other_branch_ignored`: a row with branch `g` does not exempt anything on `f`.
  - `test_waive_detached_ci`: with `GITHUB_HEAD_REF=f` on a detached HEAD, the waiver applies.
  - `test_lower_severity_fails_without_row`: block to shadow fails in `[loosened]`.
  - `test_lower_severity_passes_with_new_row`.
  - `test_old_loosen_row_does_not_cover_new_loosening`: a row committed on `main` does not cover the branch's change.
  - `test_widen_paths_is_not_loosening`: `paths=src/**` becomes `src/** lib/**`, and the status is 0.
  - `test_format_change_is_loosening`: adding `.gauntlet/formats/path-line.md` that ignores every line fails in `[loosened]` for each `block` rule using it.
  - `test_remove_rule_needs_remove_row`.
  - `test_empty_reason_rejected`: status 2.
  - `test_trailer_not_a_waiver`: a commit message ending in `Standards-waiver: a.ts — x` waives nothing.
- [ ] **Step 2:** Run `test/run.sh exceptions`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `test/run.sh exceptions`. Expected: PASS.
- [ ] **Step 5:** Run `changie new` (Added: "Exceptions: `waive`, `loosen` and `remove` write rows to `.gauntlet/exceptions.tsv`.").
- [ ] **Step 6:** Commit: `feat: human exceptions and the no-loosening check`.

### Task 11: Rule tests and declared checks inside `check --ci`

**Files:**
- Modify: `lib/check.sh`, `test/check.test.sh`

**Interfaces:**
- Consumes: `run_rule_tests`.
- Produces:
  - **Rule tests** run when a file under `.gauntlet/rules/` or `.gauntlet/formats/` changed since the merge-base (R5), reported under `[rule-tests]`. They read the case files of the tracked files only (`run_rule_tests tracked`, R28).
  - **Declared checks** come from config keys:
    - `check.<name>=<cmd>`, where `<name>` uses letters, digits, `-` and `_`;
    - `check.<name>.paths=<prefix> ...`, where an empty value means always;
    - `check.<name>.ci=on|off`, default `off`.

    A key that is not valid (a bad name, an attribute without a command, an empty command, a `.ci` that is not `on` or `off`) is exit 2, `gauntlet: bad check key <key>: <reason>`.
  - A check runs when any changed file (a deleted one too) starts with one of its prefixes. When the environment has `CI=true`, only checks with `.ci=on` run.
  - Each check runs as `bash -c` from the repo root, with stdin on `/dev/null`. A failure prints `  <name>  exit <code>` and the last 20 lines of its output, indented, under `[checks]`. Its time is added to `[time]` as `check:<name>`.

- [ ] **Step 1: Failing tests:**
  - `test_rule_change_runs_cases`: editing a rule so that its good case is flagged fails in `[rule-tests]`.
  - `test_declared_check_runs_on_scope`: `check.t=false` with `paths=src/` fails when `src/a` changed.
  - `test_declared_check_skipped_off_scope`: a change only to `docs/x` passes.
  - `test_ci_env_runs_only_ci_on`: with `CI=true` and `.ci=off`, the check is skipped and the status is 0.
- [ ] **Step 2:** Run `test/run.sh check`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `test/run.sh check`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: run rule cases and declared checks in the gate`.

### Task 12: `check --staged` and auto-tighten

**Files:**
- Modify: `lib/check.sh`, `bin/gauntlet`
- Create: `test/staged.test.sh`

**Interfaces:**
- Produces: `check_staged`, run from `pre-commit`.
  - **Scope:**
    - There is nothing to do without a `HEAD` (exit 0 with a note).
    - Rules: those with `stage=commit`.
    - Files: `staged_files`.
    - Reference: `git show HEAD:.gauntlet/baseline.tsv`.
    - The rules that exist at `HEAD` play the role of "rules at base".
  - **Checks:** new (block, minus waived) and touched (when enabled, from `git diff --cached -M --name-status`), plus the `[shadow]` and `[track]` reporting. There is no global or exact check at commit; push owns those.
  - **Auto-tighten**, on pass:
    1. Take the baseline as the index holds it, not HEAD's (R22).
    2. Drop the rows for commit-stage rules on every staged path, including deleted paths and both sides of a rename.
    3. Add the rows just measured.
    4. If the result differs from the working-tree `baseline.tsv`, write it and `git add` it.
    5. Print `  <rule>  <old> → <new>   baseline updated and staged into this commit`.

    Shadow and track rows may rise here: the baseline must stay exact. Block rows only fall, because a rise has already failed the check. When a staged file has unstaged changes, auto-tighten is skipped and the output says `partially staged; run gauntlet baseline before pushing` (decision 3). Auto-tighten is also skipped when the working-tree `baseline.tsv` has unstaged changes, when the commit is `git commit <path>`, and when `baseline.tsv` is not in the index (R22). A skip never skips the check.
  - **Budget:** the header (`gauntlet  commit · <n> rules · <s> s`) shows the elapsed time, and a run over the budget adds `[slow] over the 5 s commit budget`. It never changes the exit code. The budget is 5 s; `GAUNTLET_COMMIT_BUDGET_MS` overrides it for tests only, like `GAUNTLET_TODAY`, and the line then names that number: `[slow] over the <n> ms commit budget`. A value that is not a whole number is exit 2. The per-rule times of each run are kept in `gauntlet-time.tsv` in the git dir, for `status` (Task 14).
  - **Notes:** `note: no HEAD yet; the commit gate has nothing to compare and passes` on the first commit; `note: no baseline at HEAD; new, touched, shadow and track checks skipped`; and one note for each reason auto-tighten was skipped (`note: partially staged; run gauntlet baseline before pushing`, `note: partial commit by path; run gauntlet baseline before pushing`, `note: baseline.tsv is not in the index; nothing tightened`, `note: baseline.tsv has unstaged changes; run gauntlet baseline before pushing`). Rows of push-stage rules stay as the index has them, and follow a renamed file to its new path (R40).

- [ ] **Step 1: Failing tests:**
  - `test_staged_new_violation_blocks`, run through a real `git commit` with the hook installed by hand: the commit fails and `HEAD` is unchanged.
  - `test_fix_lands_with_lower_baseline_same_commit`: after removing a violation and committing, `git show --stat HEAD` contains `.gauntlet/baseline.tsv` and `git status --short` is empty. This guards the spike finding.
  - `test_commit_a_flag_also_tightens`: the same, with `git commit -am`.
  - `test_partial_stage_skips_tighten`, with output containing `partially staged`.
  - `test_deleted_file_rows_removed`.
  - `test_push_stage_rules_not_run_at_commit`: a `stage=push` rule whose detector is `false {files}` does not fail the commit.
  - `test_first_commit_passes_with_note`: in a repo with no `HEAD`, the commit succeeds and the output contains a note (HOOK-AC5).
  - `test_over_budget_warns_not_fails`: with `GAUNTLET_COMMIT_BUDGET_MS=1`, a clean commit succeeds and the output contains `[slow]` (HOOK-AC6).
- [ ] **Step 2:** Run `test/run.sh staged`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `test/run.sh staged`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: commit-time check with auto-tighten in pre-commit`.

### Task 13: `install` and `install-hooks`

**Files:**
- Create: `lib/hooks.sh`, `test/hooks.test.sh`
- Modify: `bin/gauntlet`

**Interfaces:**
- Produces:
  - `gauntlet install`, run from a gauntlet checkout inside the target repo, under the install lock (below):
    - copies `bin/gauntlet` and `lib/` into `.gauntlet/bin/` and `.gauntlet/lib/`, through `.bin.new` and `.lib.new`, swapped in only once the copy succeeded and rolled back if a move fails (R25);
    - creates the files that are missing: `.gauntlet/rules/`, an empty `baseline.tsv`, an `exceptions.tsv` with its header, a `config` containing `touched=off`, and `.gauntlet/.gitignore`. That is everything `install` creates, apart from the hooks;
    - then runs `install-hooks`.

    It is idempotent. A vendored runner without the exec bit gets it back (`updated mode of .gauntlet/bin/gauntlet; commit the mode change: git add --chmod=+x .gauntlet/bin/gauntlet`).
  - **`.gauntlet/.gitignore`** (R50) holds `STATUS.md` and `.install.lock/`, and brings back every file that gauntlet creates and the runner reads from the working tree: `bin/gauntlet`, `lib/*.sh`, `lib/formats/*.md`, `rules/*.md`, `formats/*.md`, `/config`, `/baseline.tsv`, `/exceptions.tsv` and `/.gitignore`, each preceded by the directories above it (a file cannot be re-included under an ignored directory). Without it, a root `.gitignore` with `lib/`, `*.sh` or `*.tsv` leaves a file out of the commit, and the local gate judges what CI never sees. `install` writes it, or adds the lines an existing one lacks and keeps the user's own (`created .gauntlet/.gitignore`, `updated .gauntlet/.gitignore: added N lines`).
  - **The install lock** (R36, R49, R51, R52, R56). `install` and `install-hooks` take one `mkdir` lock per hooks layout, so that monorepo `prepare` scripts that run them at the same moment cannot lose a hook's own body or double a gate line. The lock is `gauntlet-install.lock` in the git common dir when the hooks directory is under it (the default `.git/hooks`, which linked worktrees share), and `.gauntlet/.install.lock` for every other layout (husky, a hooks directory in the worktree, a hook manager's config, a shared directory that is only printed), where nothing is written under the git dir. A run that finds it held waits `GAUNTLET_LOCK_WAIT` seconds (30 by default; a whole number of at most four digits, read as decimal, polled five times a second) and says so once on stderr (`gauntlet: waiting for another install to finish (<lock>)`); then it exits 2 with `gauntlet: another install holds <lock>; if none is running, remove it`. A lock left by a SIGKILL is removed by hand. Ownership is by path, not by token: a lock removed by hand while its owner still runs can be removed by that owner when it exits. A directory that cannot be written is an error, not a fallback: `gauntlet: cannot lock: <dir> is not writable; fix the permissions`.
  - `gauntlet install-hooks` adds one gate line to each hook, marked `# gauntlet`. The pre-commit line is `.gauntlet/bin/gauntlet check --staged  # gauntlet`. The pre-push line is one line that gives git's stdin back to the project's own commands (R41):

    ```
    _gauntlet_in=$(mktemp) || { echo "gauntlet: cannot create a temp file; check TMPDIR" >&2; exit 2; }; [ -t 0 ] || cat >"$_gauntlet_in" || { rm -f "$_gauntlet_in"; echo "gauntlet: cannot buffer git's stdin; check TMPDIR" >&2; exit 2; }; .gauntlet/bin/gauntlet check --ci --pre-push <"$_gauntlet_in" || { _gauntlet_rc=$?; rm -f "$_gauntlet_in"; exit "$_gauntlet_rc"; }; [ -t 0 ] || exec <"$_gauntlet_in" || { rm -f "$_gauntlet_in"; exit 2; }; rm -f "$_gauntlet_in"  # gauntlet
    ```

    Git sends the ref lines once, on stdin, and `check --ci --pre-push` reads them to the end, so a command of the project's own after the gate (git-lfs, a loop over the ref lines) would read nothing. The line copies stdin to a temp file, runs the gate on the file, and re-points stdin at the same file for the commands that follow. It is POSIX sh and fails closed: no temp file is exit 2 with `gauntlet: cannot create a temp file; check TMPDIR`, a copy that fails is exit 2 with `gauntlet: cannot buffer git's stdin; check TMPDIR`, and a failing gate is its own status, with the temp file removed. A terminal on stdin (a hook run by hand) is not read and is kept for the project's commands; a hook run by hand with a stdin that is not a terminal and never closes blocks reading it. A push interrupted during the gate (Ctrl-C) can leave `tmp.XXXXXXXX` in `$TMPDIR`; it holds the ref lines, tens of bytes. An older vendored runner under this line prints its own old usage. Where they go:
    - **husky** (`core.hooksPath` is `.husky` or `.husky/_`): the gate goes first in `.husky/pre-commit` and `.husky/pre-push`, each created if missing (R26).
    - **lefthook** (`lefthook.{yml,yaml,json,toml}`, `.lefthook.*`, `.config/lefthook.*`) or **prek** (`.pre-commit-config.yaml`, `prek.toml`): no edit. It prints `ACTION NEEDED: add to <file>:` followed by the exact snippet, or `already configured in <file>` when the config holds both commands, and exits 0 (decision 4; R25). The pre-push command is `.gauntlet/bin/gauntlet check --ci --pre-push`, and lefthook must pass git's stdin on to it (`use_stdin: true`), or the gate cannot see the refs: `ACTION NEEDED: add use_stdin: true to the pre-push gauntlet command in <file>, so that git's ref lines reach it`. A config that runs an older command gets `ACTION NEEDED: replace the gauntlet command in <file> with: <command>`. A line of the config that starts with `#` is a comment and counts for nothing.
    - **Another `core.hooksPath`:** that directory when it is inside the repo or its git dir. Outside both (a hooks directory shared with other repositories), the lines are printed only, in the guarded form `if [ -d .gauntlet ]; then <gate>; fi` (R25, R53). It does nothing in a repository that never adopted gauntlet, and where `.gauntlet/` exists and the runner is missing or not executable it fails loudly, as CI would.
    - **Otherwise:** the `hooks` directory of the git common dir.
    - **One script serving both hooks** (the same file after resolving symlinks and hard links) is never edited, because one gate line would run in both hooks. The lines to add by hand are printed inside `if [ "${0##*/}" = pre-commit ]; then … fi` and `if [ "${0##*/}" = pre-push ]; then … fi`.
  - Rules for every location:
    - a hook file that is created gets `#!/usr/bin/env sh`, the plain form and `chmod +x` (`created <file>`);
    - an existing hook gets the gate form `<cmd> || exit $?  # gauntlet` on the line after its shebang (line 1 when there is none), so it runs first (R26), and `added gauntlet line to <file>`. The project's own hook then runs unchanged and keeps its own exit status. A hook this project must not edit is printed as `ACTION NEEDED: add to <file>:`, with the line and the words "place it as the first command, after the shebang line if there is one" (R25): a shebang that is not sh, bash, dash, zsh, ksh or ash, CRLF line endings, a NUL byte, a dangling symlink, a symlink to a file outside the repo, a hooks directory outside the repo and its git dir. A non-executable hook gets a warning on stderr and its mode is never changed; an empty hook gets the shebang;
    - **a hook has exactly one gauntlet line** (R47, R57). A line that ends in `# gauntlet` and runs the gate of its stage is gauntlet's. When there is one marked line and it is not the current form, `install-hooks` replaces it where it stands (`updated gauntlet line in <file>`). gauntlet never deletes a line from a hook (R59): with two or more marked lines it edits nothing and prints `gauntlet: <file> has N lines ending in "# gauntlet" (lines a, b); keep one, the current form, and remove the others` with the current line, and the user edits the file. In a hook it does not edit for another reason, the advice says `replace the line ending in "# gauntlet" in <file> with:`. `install-hooks` overwrites a customised marked line (for example one with `--base origin/develop`): the base belongs in `base=` of the config, not in the hook line. `doctor` fails a line that is not the current form and, with two or more marked lines, the same sentence as `install-hooks` (without the `gauntlet:` prefix);
    - the pre-commit plain form (`… check --staged  # gauntlet`) and its gate form both count as present and are not added again;
    - `core.hooksPath` is never written, and one that cannot be read is exit 2, `gauntlet: cannot read core.hooksPath: <git's line>`;
    - a runner that is missing is `gauntlet: no runner at <path>; run gauntlet install first` and one that is not executable is `gauntlet: runner at <path> is not executable; run chmod +x '<path>'`: both refuse for a hooks directory the project owns, and warn for what is only printed, since a hook that calls it would fail every commit;
    - a hook or directory that cannot be written is exit 2, `gauntlet: cannot write <path>: <reason>; fix the permissions or add the line by hand`, followed by the line to add (with a shebang when the file is new). Writes are in place (`hook_overwrite`), so a full disk could truncate a hook;
    - print-only advice is repeated on every run, even when the line is already there.
  - **Uninstall** is the reverse of this list: delete the lines ending in `# gauntlet` from the hooks (or the gauntlet commands from the hook manager's config, or the guarded block of a shared directory), then `.gauntlet/bin` and `.gauntlet/lib`, and `.gauntlet/` if wanted. A stale `.git/gauntlet-install.lock` is removed by hand.

- [ ] **Step 1: Failing tests:**
  - `test_plain_repo_gets_hooks`;
  - `test_existing_hook_keeps_content`: the original lines are unchanged and the marker is added once, even after running install twice;
  - `test_insert_before_exit` (Review Focus 5; the name is historical, the test checks gate-first placement);
  - `test_husky_v9_layout`: with `core.hooksPath=.husky/_`, the line lands in `.husky/pre-commit`;
  - `test_lefthook_prints_snippet_no_edit`: the file hash is unchanged and the output contains `ACTION NEEDED`;
  - `test_hookspath_never_set`;
  - `test_install_vendors_runner`: `.gauntlet/bin/gauntlet --version` works from the target repo.
- [ ] **Step 2:** Run `test/run.sh hooks`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `test/run.sh hooks`. Expected: PASS.
- [ ] **Step 5:** Run `changie new` (Added: "`install` vendors the runner and adds one line to existing hooks.").
- [ ] **Step 6:** Commit: `feat: vendor the runner and coexist with existing hooks`.

### Task 14: `status`, `promote`, `doctor`

**Files:**
- Create: `lib/status.sh`, `test/status.test.sh`
- Modify: `bin/gauntlet`

**Interfaces:**
- Produces:
  - **`gauntlet status`** prints and writes `.gauntlet/STATUS.md`:
    - a table of `rule | severity | total`;
    - the top 5 files by `block` total;
    - `promote due: <id> (shadow since <date>, <n> days), <n> found` for shadow rules at 7 days or more;
    - `slow: <rule> <ms> ms (consider stage: push)` for commit-stage rules whose time, as `check --staged` last recorded it, is at or over the budget (FRD-07 §4.6).

    The totals are the committed baseline's, so no detector runs. Days are computed in awk from `YYYY-MM-DD` with a days-from-civil formula, because there is no portable `date -d`. The text goes through `path_spell` once, so the file and the terminal get the same bytes.
  - **`gauntlet promote <id>`** rewrites `severity: shadow` to `severity: block`, and prints `promoted <id>: shadow -> block; commit the rule file`. Any other severity exits 2.
  - **`gauntlet doctor`** prints `ok <thing>`, `note <text>` (something it could not check, neither a pass nor a failure) or `FAIL <thing>: <how to fix>` lines, and exits 1 on any FAIL. It checks:
    - each engine's tool is on `PATH` (for `linter`, `rg` and `script`, the first word of the detector; a first word that is not a plain command name is a `note`);
    - the vendored runner is complete and loads: every lib file `bin/gauntlet` sources is there, it is executable, and `--version` runs;
    - each rule's output format exists, built-in or in `.gauntlet/formats/`;
    - each hook holds exactly one gauntlet gate line of the current form, wherever `install-hooks` would put it, or the lefthook/prek config holds the commands (and lefthook `use_stdin: true`); a hook that git would ignore for lack of the exec bit is a FAIL too. It checks that the lines are present, not that the gate runs;
    - no file under `.gauntlet/` is ignored by git while untracked, which `git add -A` would leave out of the commit (`STATUS.md`, the lock and editor junk excepted). It lists the files and names the pattern git matched, and it does not judge intent: a file hidden on purpose is a FAIL too;
    - the base resolves, looked up locally: doctor never fetches. An `origin/*` base that is not fetched yet is a `note` (`base <ref> is not fetched yet; the gates fetch it`), not a FAIL; any other base that does not resolve is a FAIL that names `base=` and `gauntlet base <ref>`;
    - the baseline is exact;
    - the config keys are only `base`, `touched` and `check.*`, `touched` is `on` or `off`, and every check key is valid;
    - every rule passes `rule_validate`;
    - stale waivers are listed (decision 5).

- [ ] **Step 1: Failing tests:**
  - `test_status_totals_and_worst_files`;
  - `test_promote_due_after_7_days`, with `since` 8 days before a fixed `GAUNTLET_TODAY=2026-10-30` override;
  - `test_promote_flips_shadow`;
  - `test_promote_rejects_block`;
  - `test_doctor_flags_missing_hook`;
  - `test_doctor_flags_unknown_config_key`;
  - `test_doctor_clean_repo_ok`.
- [ ] **Step 2:** Run `test/run.sh status`. Expected: FAIL.
- [ ] **Step 3:** Implement. `GAUNTLET_TODAY`, which defaults to `date +%Y-%m-%d`, is the only clock input.
- [ ] **Step 4:** Run `test/run.sh status`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: status, promote and doctor`.

### Task 15: End-to-end and docs sync

**Files:**
- Create: `test/e2e.test.sh`
- Modify: `docs/getting-started.md`, `docs/gates.md` (only where the decisions above changed behaviour), `README.md` (Status note)

- [ ] **Step 1: Write `test_full_lifecycle`.** One test that walks the whole lifecycle:
  1. `install` into a fresh repo.
  2. Add an rg rule with its cases; `test-rules` passes.
  3. Run `baseline` and commit on `main`.
  4. On branch `f`:
     - add a violation, so the commit is blocked;
     - fix it; the commit passes;
     - remove an old violation; the baseline tightens in the same commit;
     - `check --ci --base main` passes.
  5. Lower the severity: the gate fails, then `loosen` makes it pass.
  6. `doctor` reports ok.
- [ ] **Step 2:** Run `test/run.sh`. Expected: all PASS on Linux. Push the branch and confirm the macOS job in `test.yml` is green.
- [ ] **Step 3:** Update the docs for decisions 2–5 (the dirty tree, partial staging, hook-manager configs, waiver branch scope). Change the README status note to "runner usable by hand; skill in progress".
- [ ] **Step 4:** Run `changie new` (Changed: "The commit-time check runs in `pre-commit`.").
- [ ] **Step 5:** Commit: `test: end-to-end lifecycle; docs follow the runner`.

## FRD acceptance mapping

| FRD criteria | Task |
|---|---|
| RULE-AC1, AC2 | 2 |
| RULE-AC3–AC7, AC15, AC16 | 4 |
| RULE-AC8 | 12 |
| RULE-AC9–AC12 | 6 |
| RULE-AC13 | 11 |
| RULE-AC14 | 8 |
| GATE-AC1 | 5 and 8 |
| GATE-AC2–AC4, AC8–AC11, AC13 | 8 |
| GATE-AC5, AC6 | 9 |
| GATE-AC7 | 7 |
| GATE-AC12 | 11 |
| HOOK-AC1–AC3, AC5, AC6 | 12 |
| HOOK-AC4, AC7, AC8 | 13 (the `doctor` half of AC7 in 14) |
| EXC-AC1–AC10, AC13 | 10 |
| EXC-AC11 | 14 |
| LIFE-AC1–AC4, AC10, AC11 | 14 |

Not covered here, and owned by later specs:
- GATE-AC14 and EXC-AC12 (CI job and PR comments) and LIFE-AC5–AC7, AC12 (agent proposals, trend) go to IS-02;
- LIFE-AC8 and AC9 (guards) go to IS-03;
- ONB and AGENT go to IS-02.

## Self-review notes

- **Spec coverage.**
  - Design §7–9 and §13 are covered: rule format, detectors, gates checks 1–7, auto-tighten, exceptions, hooks, `base`, `status` (without trend), `promote` and `doctor`.
  - Deferred, with the plan each belongs to:
    - §8's shared linter run and §10's guards go to plan 3;
    - §9's CI job generation and PR comments go to plan 2;
    - §11 (the skill) and §12 (agent integration) go to plan 2;
    - `fix` and `update` go to plan 3.
- **Open items from §16:**
  - linter output mapping: declarative output formats (Task 4), decided by the owner on 2026-10-22; a new linter is one format file, never runner code;
  - partial staging: decision 3;
  - write-time latency: plan 2;
  - `rg` multi-line normalization: deferred. A reformat that splits one flagged line produces a new fingerprint, and the check reports it. That fails closed, not open.

## Implementation rulings

Binding rulings made while this spec was built, condensed from the controller's `rulings.md`. Each says what it is, why, and what it costs if it is wrong. Rulings marked **Needs owner approval (FRD change):** go beyond the approved FRD text and are for the owner to accept or reject.

**R1. Doc paths.** The plan's `docs/getting-started.md`, `docs/gates.md` and `docs/rules-and-detectors.md` live under `docs/guide/`. Why: the guide moved before the build. Cost if wrong: a path fix.

**R2. Comment stripping.** `format` is read like `severity`, `stage`, `engine` and `since`: a trailing `# comment` is removed. Why: `format` is an enum-like name, while a `detector` may contain `#`. Cost if wrong: one key in a list.

**R3. Format resolution.** `format_file <name>` prints a format's path: the project's `.gauntlet/formats/<name>.md` first, then the built-in one. An unknown name exits 2. Why: rules, `test-rules` and loosening all read formats, and one resolver keeps them in agreement. Cost if wrong: one function moves.

**R4. Changelog for formats.** Declarative output formats get a changelog note: a new linter is one format file in `.gauntlet/formats/`, never runner code. Why: the owner's decision of 2026-10-22. Cost: none.

**R5. Rule tests on format changes.** The rule cases run in `check --ci` when a file under `.gauntlet/rules/` or `.gauntlet/formats/` changed since the merge-base. Why: a format change can break a rule's output without touching the rule. Cost if wrong: extra test runs on renames.

**R6. Commits and process.** No commit trailers of any kind. `CHANGELOG.md` is never edited by hand. Git user config is never touched. Nothing is pushed without the owner's go. Why: history and attribution belong to the owner. Cost if wrong: a rewritten history.

**R7. Changie runs.** Two `changie new` runs in the same second overwrite each other, so each run waits one second. Cost if wrong: a lost changelog entry.

**R8. Tooling on the build machine.** The build machine has bash 5.2, `rg`, ast-grep 0.51 and shellcheck. The binary is `ast-grep`, not `sg`. Tests run with `bash test/run.sh <group>`. The code must stay bash 3.2 compatible, and the macOS CI job is the real 3.2 check. Cost if wrong: a bash 4 feature reaches users, and macOS CI catches it.

**R9. `severity_rank`.** It prints the rank (block 3, shadow 2, track 1) and returns 1 for any other severity. Callers read it with `$(...)`. Why: an exit status of 3 would trip `set -e` and collide with the exit codes. Cost if wrong: one line in each caller.

**R10. Glob conversion.** One left-to-right scan in POSIX awk. `**/` matches zero or more directories, `**` matches anything, `*` matches within one directory, `?` matches one character, and the other regex metacharacters are escaped. Why: the order in the brief escaped the brackets it had just produced. Cost if wrong: one function rewrite.

**R11. Runner library path.** `lib/detect.sh` sets `GAUNTLET_LIB` from its own location, and the built-in formats live under it. Format frontmatter is read by the same reader as rule frontmatter. Why: no runner-root variable existed yet. Cost if wrong: the variable moves to `core.sh`.

**R12. `path-line` regex.** It is `^([^:]+):([0-9]+)(:[0-9]+)?(: ?(.*))?$`, so the path is everything before the first colon. Why: a greedy path group swallowed the line number when a column was present. Known ceiling: a path with a colon in its name. Cost if wrong: one regex.

**R13. Batching.** A `{files}` list is split into batches of at most 25000 bytes of quoted words, counted in bytes with the command's own text included, so each `bash -c` command stays well under the 128 KiB per-argument limit (and under 100000 bytes even for a tool that counts characters). The detector runs once per batch, and a batch that exits 2 or more makes the detector broken. Why: the limit is reached on real repos. Cost if wrong: a loop.

**R14. Detector stderr.** The detector's stderr goes to a temp file. The broken-detector and missing-tool messages show its first five lines. Why: a bare exit code is hard to act on. Cost if wrong: noisier messages.

**R15. `.gauntlet/` is never measured.** **Needs owner approval (FRD change):** FRD-02 §4.6 says `{files}` is "every file matching `paths`", and this narrows it. Files under `.gauntlet/` are skipped whatever a rule's `paths` say. Why: rule files contain the patterns they detect, so the default `**` would make a rule flag itself. Cost if wrong: no rule can lint gauntlet's own config.

**R16. Format tests.** `test-rules` checks every built-in format and every project format. A project file replaces the built-in of the same name. Each sample is parsed by the same parser that reads detector output. Why: one parser, and unused formats are still checked. Cost if wrong: a filter added later.

**R17. The base side of the comparisons.** The merge-base's `baseline.tsv` is read as committed and never re-measured. Severity and fix come from the current rule file. A rule exists at the base if its file exists at the merge-base commit. Per-rule times are written by `measure`. Cost if wrong: re-measuring the base later is additive.

**R18. Problem count.** One problem per `[new]` line, one for `[baseline]`, one per `[loosened]` line, `[rule-tests]` line and failed check, and one per `[touched]` line that no `[new]` line explains. `[global]` still prints every rising rule (GATE-AC3). It is a problem only when its `[new]` lines do not already explain the rise, which happens when the rise came from waived paths. Shadow and track count nothing, and are skipped on onboarding (no baseline at base). A rising violation reports its last occurrences. Cost if wrong: one counting function.

**R19. Tracked files only.** **Needs owner approval (FRD change):** FRD-02 §4.6 says "every file matching `paths`", and this narrows it. `baseline` and `check --ci` measure the index's tracked files and never untracked ones. Why: CI never sees untracked files, so a local baseline would disagree with CI. Cost if wrong: a mode switch. A new file must be `git add`ed before it is measured.

**R20. Touched rows.** A `[touched]` line is a problem only when its file has no `[new]` line, because that line already explains it. Every failing file is still printed, with the rule it failed: `(must go down)`, `(must be 0)` for an added file, or `(must stay 0)` for a file with no debt at the base. Cost if wrong: one counting rule.

**R21. Newline and tab in paths. Superseded by R31.** The TSV tables cannot carry these characters. Without a guard a tab dropped that file's rows with no message, and a newline split the file list, so `check --ci` could print ok for a file it never measured. A tracked path that holds either now fails closed (R31).

**R22. Tighten from the index, with skip modes. Needs owner approval (FRD change):** Auto-tighten starts from the baseline the index holds, not from HEAD's. The new, touched, shadow and track checks still compare with HEAD, so nothing new can be smuggled in. Tightening is skipped (the check still runs and blocks) when a staged file has unstaged changes, when the working-tree baseline has unstaged changes, when the commit is `git commit <path>` (a `next-index-*` file), or when `baseline.tsv` is not in the index (`note: baseline.tsv is not in the index; nothing tightened`). Measured rows at commit are filtered to staged paths. Partial staging skips only the tighten. Also at commit, no waivers apply on a detached HEAD, and a rule absent at HEAD is exempt from new and touched. Why: starting from HEAD would revert a baseline regenerated on the branch, which deadlocks push recovery. Cost if wrong: a hand-staged baseline is kept as staged, and push's exact check still catches a wrong one.

**R23. Renames carry their debt. Needs owner approval (FRD change):** A rename that git reports as `R` in `git diff -M` moves the old path's baseline rows to the new path, in `check --ci` and at commit (FRD-03 §4.6). Copies, and delete-plus-add pairs below git's similarity threshold, do not carry debt. Limits: a file moved over an existing one (git reports `M` plus `D`) and an `A` ↔ `B` swap count as new debt; `waive` is the escape. A branch that changes too many files for git's `diff.renameLimit` (default 1000) loses rename detection, with a warning from git. Why: existing debt must not fail the gate by itself, and a rename is not new debt. Cost if wrong: renamed legacy files get blocked.

**R24. A deleted rule leaves its rows.** Deleting a rule that has debt leaves its baseline rows in place until `gauntlet baseline` runs, and push's exact check reports them. Why: the rows stay the record until someone regenerates the baseline, and the deletion is judged as a loosening anyway. Cost if wrong: one extra step on rule removal.

**R25. Editing existing hooks.** The runner edits only a hook it can change without changing what the project's own code does. Print-only (`ACTION NEEDED`, with the line to add): a shebang that is not sh, bash, dash, zsh, ksh or ash (directly or through `env`); CRLF line endings; a NUL byte; a dangling symlink; a symlink to a file outside the repo; a hooks directory outside the repo and its git dir (there the lines are the guarded form, R53). The advice printed for a hook that cannot be created or written starts with a `#!/bin/sh` line, so that what is pasted into a new file is a hook that runs. An empty hook gets the shebang and the gate line. A non-executable hook gets a warning on stderr, and its mode is never changed. A lefthook or prek config that already holds both command strings prints `already configured in <file>` instead of the snippet. `core.hooksPath` is read with `git config --path`, so `~` expands. A husky layout is a `core.hooksPath` that ends in `/.husky` or `/.husky/_` inside the repo; the edited directory is that path with `/_` removed. Vendoring copies into `.new` directories, swaps them in only after the copy succeeds, and rolls back on failure. The exit-detection parts of this ruling are superseded by R26. Cost if wrong: a hook needs a hand edit.

**R26. The gate goes first. Approved by the owner on 2026-10-23 (ADR-0006 and FRD-07 §6 amended):** In an existing hook the runner may edit, the gate line goes on the line right after the shebang (line 1 when there is none), as `<cmd> || exit $?  # gauntlet`. Why: a line placed at the end can be skipped by an early exit, `exec`, a line continuation or a failing last command, and review rounds showed each of these. A created hook uses the plain pinned form. For pre-commit, presence accepts either form, per hook. The pre-push line is one form for every case (R41), and a hook has exactly one gauntlet line (R47, R57). The print-only cases of R25 still print the gate form, for a person to place first by hand. The gate runs before the project's own steps, so a formatter in lint-staged runs after it. `doctor` checks that the line is present and that the vendored runner loads, not that the gate runs. Cost if wrong: the gate runs before the project's own steps.

### Rulings after the whole-branch review and the fix rounds (R27–R58)

Condensed from the controller's `rulings.md` in the same way. R38 and R46 only ordered the work and are left out.

**R27. Every gate validates every rule.** `baseline`, `check --ci` and `check --staged` call `rule_validate` for every rule and exit 2 with `rule <id>: <problem>; run gauntlet doctor`. The script-row lookup lives in `lib/exceptions.sh`. Why: RULE-AC1 and RULE-AC2. Cost if wrong: one call.

**R28. Rows count only for files a clone has.** Whole-program detector rows are filtered to the kept list (the tracked files, or the staged ones at commit). The rule tests of `check --ci` read the tracked files; `test-rules` by hand keeps `all_files`. Detectors run with `RIPGREP_CONFIG_PATH` unset. Why: a whole-program detector also reports untracked and ignored files, which a fresh clone does not have. Cost if wrong: a filter.

**R29. Repo commands run from the repo root.** `bin/gauntlet` changes to it once (not for `--version` or `install`, which resolve the root themselves), and `ls-tree --full-tree` is used wherever a pathspec is. Why: a path given to git must not be relative to a subdirectory.

**R30. Detector hardening.** `LC_ALL=C sed`; a `./` in front of a tracked path that starts with `-`; `bash -o pipefail -c` with a check of `PIPESTATUS`; `ast-grep --error`; `path-line` ignores `rg`'s `binary file matches` line; no detector runs when no file is in scope; `detect_scan` quotes the file list into batches in one awk pass (`baseline` of 20000 tracked files with one `rg` rule took 0.6 s on the build machine). Why: each was a way for a detector to pass over a violation or fail on a clean repo.

**R31. A tab or newline in a tracked path fails closed.** Exit 2, naming the path, with `rename the file`. It is detected once, in the path listers. A diff or tree listing that names such a path being removed or renamed does not refuse. Supersedes R21.

**R32. One answer for "is it there".** `base_has <sha> <path>` returns 0 present, 1 absent, 2 on a git error, and every base read uses it. An unreadable base is exit 2 and never onboarding mode.

**R33. One temp root per run.** `bin/gauntlet` creates it and removes it on EXIT, INT, TERM and HUP. The wrapper and worker pairs are not collapsed, and the two copies of the rule table and report logic are not merged: a follow-up. Known limit: a SIGTERM sent to gauntlet alone is handled when the foreground detector returns, because bash defers the trap; a signal to the process group, as Ctrl-C sends, ends the detector too.

**R34. Config loosening. Approved by the owner on 2026-10-23 (FRD-04 §4.8, §8 and EXC-AC13 amended).** A change to `.gauntlet/config` that relaxes a gate is loosening: a changed `base=`, `touched` going from on to off (deleting the line counts), a declared check removed, its `.ci` going from on to off, its `.paths` narrowed or its command changed. One `loosen @config` row covers them (Task 10). A `stage:` change in a rule file is not loosening, because a push-stage rule is still enforced at push and in CI. Why: a committed config line could relax a gate without a row, and the owner closed the gap between what the docs say and what the gate does. Cost if wrong: a config change needs a row.

**R35. The pre-push gate checks what is pushed.** Revised on 2026-10-23: it reads the ref lines git sends and refuses, with exit 1, a pushed branch tip (`refs/heads/*`) that is not the checked-out `HEAD` (Task 8, FRD-03 §4.11). Deletes and refs in other namespaces are skipped. The temporary-worktree option (FRD-03 §12.1) is not built. Cost if wrong: pushing a branch you have not checked out is refused until you check it out.

**R36. Install hardening.** `install` and `install-hooks` take the install lock (R49) and re-check marker presence under it. `install` writes `.gauntlet/.gitignore` (R50). `doctor` checks the runner and the files under `.gauntlet/` against git's ignore rules and that the base resolves. `install-hooks` detects one script serving both hooks and only prints. `loosen` and `remove` reject an unknown rule id (`loosen` also takes `@config`). `waive` without `.gauntlet/` prints a clean message.

**R37. The CI trust model, as revised on 2026-10-23.** Nothing may reach CI without being proven locally, so pre-push and CI run the same `gauntlet check --ci` from the same tree: the branch's own vendored runner. A different runner locally and in CI would pass in one and fail in the other. That runner cannot protect against its own author. `check --ci` prints `note: the vendored runner changed in this branch (.gauntlet/bin or .gauntlet/lib differ from the base); review it`, locally and in CI; it is not a failure and takes no exception row (there is no `@runner` type), and it is skipped when the base has no runner (the first install). CODEOWNERS on `.gauntlet/` routes a change to a reviewer. Optional hardening, with its cost: CI runs the base's runner against the PR tree (`git archive origin/$BASE .gauntlet/bin .gauntlet/lib | tar -x -C "$RUNNER_TEMP/g"`, then `"$RUNNER_TEMP/g/.gauntlet/bin/gauntlet" check --ci --base origin/$BASE`), and a PR that upgrades gauntlet is then judged by the old runner and can fail only in CI. The gate belongs on `pull_request`; `pull_request_target` gives a fork's PR a privileged context. Cost if wrong: a deliberate runner tamper passes unless the project adopts the recipe.

**R39. A foreign branch cannot be refused under prek.** prek runs hooks with stdin on `/dev/null`, so the gate sees no refs and judges the checked-out branch. The claim of FRD-03 §4.11 holds for plain git hooks, husky and lefthook with `use_stdin: true`.

**R40. Renames at commit.** `carry_renamed`, not `rekey_base`, carries the kept push-stage rows to the new path, because `rekey_base` would drop push-stage rows at the destination after a baseline regenerated after the rename.

**R41. The pre-push line keeps git's stdin whole.** The gate must not drain stdin for the project's own commands (git-lfs `git lfs pre-push` reads the ref lines). The line buffers stdin in a temp file, runs the gate on it and re-points stdin at the file (Task 13), fail-closed. One form for every pre-push line (new file, in-place edit, advice, guarded form). The lefthook and prek snippets keep the bare command, because the hook manager owns stdin.

**R42. A committed `base=` is judged against the default base too.** `base=` can aim the local run at the branch itself (`base=HEAD`) while CI, which names the target, fails. The `@config` judgement compares the effective bases against the selected base and against the base resolved without HEAD's `base=` (flag, `branch.<b>.gauntletBase`, `origin/HEAD`, `main`), and reports `base A → B` if either differs. When the default does not resolve, that comparison is skipped and CI judges. `branch.<b>.gauntletBase` stays trusted: it is local state, the same class as the developer's own checkout, and CI judges the same way.

**R43. Refusal details.** A Gerrit `refs/for/*` push is refused like `refs/heads/*`; tags and other namespaces are skipped. The message names the branch only when the local ref is `refs/heads/<name>`, and otherwise says the pushed commit is not the checked-out one. `doctor` sees a lefthook pre-push without `use_stdin: true`. The advice says "replace the old line" where an old line exists. `exc_rule_known` asks `rule_is_case_file`.

**R44. The detector command is cut like the shell cuts it.** At an unquoted space, tab, newline or `; & | < > ( )`; `--opt=path` also yields the part after `=`; the `ast-grep` rule field is one word. Not followed, and a limit: `cd dir && ./x` (the word is `./x` relative to the root), brace expansion, scripts inside a submodule, `$VAR` and globs, helpers a script `source`s, `.ignore` files that a search tool reads, a symlinked detector compared by its target (R56 adds quoted `-c` strings and backticks).

**R45. Text from the repo reaches the terminal escaped.** A `base=` with a control byte is exit 2 when read. Base and ref text on the printed sinks, and `gauntlet base`'s output, go through `path_spell`; a leading `::` in a printed name is escaped (GitHub workflow commands); one trailing CR is dropped from displayed source lines. Detector reads are bounded: memoized, batched, one read of a word per run.

**R47. A marked line is gauntlet's.** A line ending in `# gauntlet` that runs the gate of its stage is replaced in place by `install-hooks` when it differs from the current form, and `doctor` fails a differing marked line. No list of older forms is kept: nothing was installed outside test repos.

**R48. Accepted limits of the install work.** `.gauntlet/.gitignore` has the lines of R50 because git 2.43 does not re-include under a root `*.sh` or `*.md` with `!lib/` alone. A lock left by a SIGKILL needs manual removal after the wait (exit 2, with the path). Print-only advice repeats on every run. `hook_overwrite` writes in place, so ENOSPC could truncate a hook.

**R49. The lock stays out of a read-only git dir where it can.** It lives under the git common dir only when the hooks directory is there (the shared `.git/hooks`, where linked worktrees must serialize); for husky, lefthook, prek and print-only layouts it is `.gauntlet/.install.lock`. `doctor` never fetches: it resolves the base locally, and an unfetched `origin/*` base is a note. See R56 for the git dir that cannot be written.

**R50. `.gauntlet/.gitignore` re-includes exactly what gauntlet creates** (Task 13), from one list that `install` and `doctor` share. `install` adds missing lines to an existing file and keeps the user's own. `doctor` lists every ignored untracked file under `.gauntlet/` with the pattern git matched, and its FAIL says by cause: required lines missing (run `gauntlet install`), a root rule still hides the file (name it; remove or narrow it), or `.gauntlet/` itself is ignored.

**R51. `GAUNTLET_LOCK_WAIT`** is read base 10 and capped at four digits. `BASE_HINT` says the durable fix is `base=` (`gauntlet base <ref>` fixes the current branch only) and does not misdirect when the base came from `--base`.

**R52. Lock ownership is by path, not by token.** A lock removed by hand while its owner runs can be removed by the owner when it exits. Documented limit.

**R53. The guarded form guards on `.gauntlet/`.** `if [ -d .gauntlet ]; then <gate>; fi` skips a repository that never adopted gauntlet, and a `.gauntlet/` with a missing or non-executable runner fails loudly, as CI would. A guard on an executable runner skipped in silence while CI failed.

**R54. The default-base comparison stays.** Locally the PR target CI will name is unknown, so the strict direction is the only sound one: a local run stricter than CI is friction, a lenient one is the hole R42 closed. In a gitflow layout (default branch `main`, `base=develop` committed on `develop` only) the way out is a `loosen @config` row, or `gauntlet base develop` on the branch, and the FAIL prints both (Task 10).

**R55. The default base is fetched like the selected one,** only when it differs from the selected base. A failed fetch warns and uses the local ref. A detector word that starts with `-` is tested before its `./` is stripped, so `./-x.sh` is a file.

**R56. Documented limits.** Quoted `-c` strings and backtick substitution are not followed by the detector-file check (quoted words stay out to avoid false positives). A push interrupted during the gate can leave `tmp.XXXXXXXX` in `$TMPDIR` (a trap in a one-liner that is the first line of someone else's hook costs more than it buys). `install-hooks` overwrites a customised marked line: put the base in `base=` of the config, not in the hook line. A git dir that cannot be written is an error (`cannot lock: <dir> is not writable; fix the permissions`), not a fallback to the worktree lock. `install` and `install-hooks` share ONE lock per layout, so they cannot wait for each other. Rule case files are Markdown (`<id>.bad.md`), covered by `!rules/*.md`.

**R57. A hook has exactly one gauntlet line.** `install-hooks` replaces a single marked line that is not the current form where it stands (`updated gauntlet line in <file>`). Superseded in part by R59: it never removes a line; with two or more marked lines it edits nothing, names the lines (`<file> has N lines ending in "# gauntlet" (lines a, b); keep one, the current form, and remove the others`) and `doctor` fails with the same sentence. A commented-out line never counts as configuration: not a lefthook `use_stdin`, not a gate command string in a hook manager's config. The hook line's own failure paths print one `gauntlet:` line on stderr before exit 2.

**R58. Re-review fixes.** The shared-directory advice says the lines do nothing where there is no `.gauntlet/` directory and fail where it exists and the runner is missing or not executable. `.gauntlet` as a file is named in the lock message. `gauntlet_keeps` does not let `*` cross `/`. `doctor` with an unreadable `.gauntlet/.gitignore` prints one `gauntlet:` FAIL and does not leak git or awk lines.

**R59. gauntlet never deletes a line from a hook.** Deleting lines by pattern can break the hook around them (the only command of an `if` block, a function body, a project command that holds the gate text). One marked line is replaced in place (R47). Two or more leave the hook untouched: `install-hooks` prints `gauntlet: <file> has N lines ending in "# gauntlet" (lines a, b); keep one, the current form, and remove the others` and the current line, and `doctor` fails with the same sentence. Known edge: in a shared hooks directory, the unmarked guarded form next to one marked plain line counts as one marked line.

**R60. A command printed for the user to paste quotes the repo's text.** `sh_quote` (in `lib/core.sh`) wraps a value in single quotes, an embedded `'` as `'\''`. It is applied to the base ref in the `gauntlet loosen` / `gauntlet base` hint and to the path in every `chmod +x` hint. Constants (`git add --chmod=+x .gauntlet/bin/gauntlet`) and placeholders (`<reason>`) are not quoted. Not built: a check that a gauntlet line sits before an `exit` or inside a here-doc.
