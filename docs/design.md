# gauntlet — design

Status: draft for owner approval (2026-10-22)
Owner: Antony Giomar Hernández.

## 1. Intent

An agent that writes code in a repo must not be able to make that repo worse.

gauntlet is a drop-in "gauntlet" for any repository. An agent installs it, studies the repo, agrees a set of rules with the owner, and measures every existing violation. From then on, debt can only go down. A new violation is caught at commit, at push and in CI.

It extracts a process that was built by hand in a large production monorepo ("the origin project", see [case-study.md](case-study.md)) into one tool that is agnostic to language, agent harness and model. That process is per-rule ratchets, a diff gate, a touched-file gate, escape hatches and a pre-push gate.

### Why

- **Rules in prose get forgotten.** A rule nobody counts gets violated, and nobody notices. A rule must bite at the moment the mistake is made.
- **The hand-built version is a pattern copied many times, not a system.** The origin project grew 41 bespoke check and ratchet scripts, each written its own way, with its own baseline format, no shared registry and no guide for adding a rule. Many are rules disguised as scripts.
- **The hand-built escape hatch became routine.** Up to 17 % of a week's commits carried a waiver trailer. An escape an agent can write for itself gets used as a habit.
- **The agent side is uncovered.** A 2026-10-22 survey of pawl, cleat, betterer, ESLint bulk suppressions, PHPStan/Psalm/detekt baselines, reviewdog and Trunk found that each covers part of the engine. None has a touched-file gate, rules as files with a rationale, onboarding that researches and proposes rules, or rules learned from an agent's repeated mistakes.

### Non-negotiable

**Nothing is pushed without knowing it passes CI.** The local pre-push gate runs everything CI would run, under the same conditions.

## 2. Goals

1. Onboard any repo, existing or empty, into a set of owner-approved rules with a measured baseline.
2. Back every rule with a deterministic, declarative detector. A rule without a detector is not a rule.
3. Catch new violations at commit, push and CI, and let debt only fall.
4. Work in any language, any agent harness (Claude Code, Codex, Command Code, …) and any model.
5. Learn: when the agent keeps making the same mistake, it proposes a new rule.
6. Coexist with whatever the project already has. Never break an existing setup.
7. Replace the origin project's hand-built ratchet scripts and pre-push gate completely.

## 3. Non-goals

- Coordinator/worker agent orchestration (briefs, review loops, task DAGs). That is a separate project.
- Imposing standards, ADRs or an architecture. gauntlet enforces what the owner agrees to, nothing else.
- A dashboard or HTML report. State lives as markdown in the repo.
- Publishing to npm or any registry. Distribution is a public git repo.

## 4. Anti-goals

Any of these counts as failure, even if the tool otherwise works:

- **The gate is slow, so people reach for `--no-verify`.** The commit-time check must stay under 5 s.
- **False positives make people hate the gate.** Every detector ships with test cases, and every new rule starts in shadow.
- **Known debt suddenly breaks CI.** Existing debt never fails the gate by itself. Nothing starts failing without the owner switching it on.
- **gauntlet breaks the project's existing hooks or tooling.**
- **The agent can loosen the rules it is bound by.**
- **Onboarding buries the owner.** Forty rules on day one, or rules activated without asking, is a failure.
- **Two ways do the same thing.** A rule lives in exactly one place: the project linter or gauntlet.
- **Everyone writes detectors their own way.** Detectors are declarative.

## 5. Concepts

| Term | Meaning |
|---|---|
| **Rule** | An agreed constraint: rationale, source, declarative detector, fix hint, test cases, severity. |
| **Detector** | A linter rule, an `ast-grep` YAML rule, or an `rg` pattern that yields violations as `path:line[: message]`. |
| **Fingerprint** | `rule + path + normalized text of the flagged line` (whitespace collapsed). This is the identity of a violation. Line numbers are never stored. |
| **Baseline** | The fingerprints present in the repo, with multiplicity. It is derived: only the runner writes it, and it always equals what the code measures. |
| **Severity** | `block` is fully gated. `shadow` is a new block rule that reports "would have failed" but does not fail. `track` is counted and shown, and never fails. |
| **Check** | A pass/fail project command (tests, build, type-check), declared and scoped by paths. |
| **Guard** | A `block` rule at zero that watches a rule which graduated back to the project linter. |
| **Exception** | A row in `.gauntlet/exceptions.tsv`. Only a human creates one. |

## 6. Layout in a consuming repo

```
.gauntlet/
  bin/gauntlet                 # vendored runner (bash), pinned version
  config                       # flat key=value: base ref, touched gate, checks, CI options
  rules/
    <id>.md                    # frontmatter + rationale
    <id>.yml                   # ast-grep rule, when the detector is ast-grep
    <id>.bad.<ext> / <id>.good.<ext>   # or directories, or in-project fixture paths
  detectors/                   # custom script detectors — only by approved exception, from a fixed template
  baseline.tsv                 # rule<TAB>path<TAB>fingerprint<TAB>count
  exceptions.tsv               # type<TAB>target<TAB>reason<TAB>date<TAB>branch
  ONBOARDING.md                # what was inferred and what the owner answered; rewritten in place
  STATUS.md                    # generated: counts per rule, worst files, trend, shadow rules due
  PROPOSALS.md                 # rules proposed but not accepted, or lacking a detector
  HOW-TO-WRITE-A-RULE.md       # the guide every rule follows
.agents/skills/gauntlet/       # the skill, vendored (+ symlink for Claude Code)
AGENTS.md                      # gauntlet block: rule summary, commands, prohibitions
```

## 7. Rule format

```markdown
---
id: silent-catch
severity: block                # block | shadow | track
stage: commit                  # commit (default) | push — whole-program detectors are push-only
engine: ast-grep               # linter | ast-grep | rg | script (script only by exception)
detector: .gauntlet/rules/silent-catch.yml
paths: src/**
exclude: **/*.test.ts
fix: Log the error with context and rethrow, or handle it; never leave the catch empty.
source: https://… (primary source) | ADR-0007 | pending
since: 2026-10-22              # when it entered shadow; drives the promotion reminder
---
Why this rule exists, what to do instead, and the evidence found in this repo at onboarding.
```

- Frontmatter is flat key/value so awk can parse it.
- `source` must be a primary source: official docs, the technology's style guide, or an ADR of the project. A blog post is not enough. When onboarding runs without web access, the field is `pending` until a session with web confirms it.

## 8. Detectors

- **Declarative only.** A detector is (1) a rule of the project's own linter, (2) an `ast-grep` YAML rule, for structural rules in any language, or (3) an `rg` pattern, for textual rules only, in that order of preference. A custom script needs an exception approved by the owner. It then lives in `.gauntlet/detectors/`, is built from a fixed template, and carries test cases.
- **One run per tool.** Several rules backed by the same linter share one cached run per gate invocation. In the origin project, ESLint ran three times per push (≈140 s).
- **Input.** In the commit stage, the runner passes the staged files. In push and CI, it passes every file that matches `paths` minus `exclude`. The runner also filters the output to those files.
- **Whole-program detectors** (type-check, dependency graph, duplicate definitions) set `stage: push`. They do not run at commit, but always run at push and in CI. They scan the whole repo, and the runner attributes each output line to its path. A violation that spans several locations prints one line per location.
- **Fail closed.** A non-zero exit with no parseable output means the detector is broken, and the gate fails. A missing tool fails with the install command. Nothing is skipped silently.
- **Tests.** When anything under `.gauntlet/rules/` changes, push and CI run every rule's cases. The gate fails if `bad` is not flagged or `good` is.
  - A case may be a single file, a directory (for cross-file rules), or a path inside the project's lint scope (for linter rules that ignore files outside the project config).
  - Guards are tested with a config fixture.
- **Reformat-proof.** gauntlet's own test suite includes "reformatting a whole file changes no verdict".

## 9. Gates

The same runner runs in three places:

| Where | What runs | Role |
|---|---|---|
| `commit-msg` hook | `stage: commit` rules on staged files: new-violation check, touched check if enabled, auto-tighten | fast feedback; target under 5 s |
| `pre-push` hook | `gauntlet check --ci` plus every declared check | the developer's guarantee before sending |
| CI | `gauntlet check --ci` always; heavy checks per project config | catches anyone who skipped the hooks |

The commit-time check runs in `commit-msg` rather than `pre-commit`, so the runner can tighten the baseline into the same commit.

### Parity

- Push and CI use the same vendored runner and the same base. The base is the branch's target:
  - In CI, it is the PR's target branch.
  - Locally, it is `git config branch.<name>.gauntletBase`, which a stack tool or `gauntlet base <ref>` sets. It falls back to `origin/<default>`.
  - Using the target keeps stacked PRs from being charged with the whole stack.
- The runner fetches the base and computes the merge-base.
- CI checks out the full history. This comes from the origin project: its diff gate passed locally and failed in CI because of a shallow checkout. Reproduce the condition, not just the command.
- CI always runs the rules, which takes seconds and needs no opt-in label. Heavy checks (tests, build) run in CI only when the project's config says so; CI minutes cost money. Pre-push always runs everything.

### What `check --ci` verifies

1. **No new violations.** A `block` fingerprint that is absent from the merge-base baseline fails, unless it is waived. Fingerprints make the check immune to line shifts, moved code and reformatting.
2. **Global.** A `block` rule's total must not rise.
3. **Touched** (configurable, **off by default in an existing project**):
   - Every file the branch changed comes out with a strictly lower `block` total than it went in with. A file at 0 stays at 0.
   - Added files come out at 0.
   - Renames are followed, and pure renames are skipped.
   - The total is summed across `block` rules: paying down one violation of any rule passes. This is what the origin project settled on.
   - `shadow` and `track` rules never count toward it.
4. **Baseline is exact.** The runner re-measures, and the committed baseline must equal the measurement: higher is loose, lower means the code is above the baseline. Nobody edits the baseline by hand, agent or human.
5. **No loosening.** Each of the following fails unless a matching exception exists:
   - a rule's file removed;
   - its severity lowered;
   - `paths` narrowed or `exclude` widened;
   - its detector changed (compared against the merge-base).
6. **Rule tests**, when the rules changed (§8).
7. **Declared checks** (tests, build, type-check, …), each scoped by path prefixes.

### Behaviour

- **No fail-fast.** Every check runs, and every violation is reported together as `path:line  rule  message`, followed by the rule's `fix` line. The agent fixes everything in one pass.
- **Wall time** is printed per rule and per check.
- **Auto-tighten.** When counts fall, `commit-msg` rewrites `baseline.tsv` and stages it into the same commit. A fix and its lowered number always travel together, and nobody has to remember.
- **`shadow`** prints "would have failed" with the details and never fails. A shadow rule stays in shadow until the owner promotes it. After 7 days, `status` and the agent remind the owner to promote it, with how often it would have failed and any false positives reported. Promotion is never automatic.
- **`track`** is counted and printed and never fails. When its count rises, the output says so with the delta, and the agent proposes promoting it.

### Exceptions

Exceptions live in `.gauntlet/exceptions.tsv`. They are not commit trailers, because the owner forbids trailers in commits.

| Type | Target | Lifetime |
|---|---|---|
| `waive` | a path | the branch only; removed from the file when the branch merges |
| `loosen` | a rule, plus what changed | permanent, recorded |
| `remove` | a rule | permanent, recorded |
| `script` | a custom detector | permanent, recorded |

- **Only a human creates an exception,** with `gauntlet waive <path> "<reason>"` and its siblings. In Claude Code the owner runs it as `! gauntlet waive …`. That is the owner's own command, not an agent tool call, so it is not blocked.
- **The agent may propose the exact command and its reason.** It never writes the file.
- **When the agent is blocked and the owner is away,** it stops, leaves the command ready, and notifies the owner. It never works around the gate.
- **CI comments every new exception on the PR.**

### Hooks: coexist, never take over

- If the project already uses husky, lefthook, the `pre-commit` framework or its own hooks, gauntlet adds **one line** that calls it inside the existing hook and touches nothing else.
- It never changes `core.hooksPath` when one is already set.
- It installs its own hooks only when the project has none.
- `core.hooksPath` does not travel with a clone, so onboarding wires installation into the project's existing setup step (`prepare` script, `make setup`, …). A teammate who clones is protected without remembering.
- gauntlet offers a declared place for extra checks (`config`), rather than forbidding what the project already runs.

### CI

- Onboarding writes a CI job, GitHub Actions first, that runs `gauntlet check --ci` on every PR.
- Without branch protection, a red run does not block a merge. In that case the job also comments the violations and the new exceptions on the PR, and onboarding recommends turning protection on.

## 10. Linter-owned rules

This follows the origin project's criterion: `rules-of-hooks` stays at `error` in ESLint with no ratchet, while the `react-hooks/*` rules that carry debt are ratcheted.

- **A linter rule with zero violations** stays in the linter at `error`. gauntlet does not duplicate it.
- **A linter rule with debt** becomes a gauntlet rule whose detector runs that linter rule.
- **A ratcheted linter rule that reaches 0** graduates back to the linter at `error`, and gauntlet keeps a **guard**. The guard fails if either of these happens:
  - the linter's effective config no longer has the rule at `error` (`eslint --print-config`, `ruff check --show-settings`, …);
  - new inline suppressions of that rule appear.

## 11. The skill

The skill uses the Agent Skills format (`SKILL.md`). It is vendored into `.agents/skills/gauntlet/` and symlinked for Claude Code.

### `onboard`

1. **Detect** the stack, the languages, the existing linters and their configs, the existing hooks and setup steps, the test and build commands, and the architecture and its patterns. In an empty repo, ask about the stack and architecture instead.
2. **Research** best practices for the detected technologies from primary sources. Without web access, use the catalog and the repo evidence, and mark `source: pending`.
3. **Ask before proposing anything from the catalog.** `catalog/` (in this repo) holds rule patterns generalized from the origin project: silent catch, raw string comparison instead of enums, missing return type, layers importing the wrong way, and others. The catalog is inspiration only. A catalog rule is never activated without evidence in the repo and the owner's yes.
4. **Propose** each rule under a number, with:
   - why;
   - the source;
   - the violation count and the worst files;
   - the detector;
   - the fix hint.

   The owner accepts, rejects or adjusts each rule, and picks its severity. A new `block` rule enters as `shadow`, unless the owner skips the shadow period. Every detectable rule the owner accepts enters on day one. `PROPOSALS.md` holds only rules that were not accepted or that lack a detector.
5. **Write** the detectors and their cases, run the rule tests, and measure `baseline.tsv`.
6. **Confirm the checks**: the commands that pre-push runs, their path scopes, and which of them CI runs.
7. **Install**:
   - the hook lines, coexisting with the existing hooks;
   - the setup-step wiring;
   - the CI job;
   - the `AGENTS.md` block;
   - `ONBOARDING.md` and `STATUS.md`.

   The touched gate stays off in an existing repo until the owner turns it on.

Re-running `onboard` updates everything in place and never duplicates.

### `status`

`status` regenerates `STATUS.md`:
- counts per rule;
- the files with the most debt;
- the trend against earlier baselines in git history;
- shadow rules that are due for promotion.

It also summarizes the result in chat.

### `propose-rule`

The agent proposes a rule only on a concrete signal:
- the owner corrected it for a pattern;
- it fixed the same kind of mistake twice in a session;
- a `track` rule rose.

The proposal always carries a working detector and the current count. Nothing is added without the owner's yes.

### `add-rule`

`add-rule` follows `HOW-TO-WRITE-A-RULE.md`. A rule needs:
- a rationale and a primary source;
- evidence in the repo;
- a declarative detector;
- a fix hint;
- a check for conflict or overlap with existing rules and with linter-owned rules;
- its cases;
- a measured baseline.

## 12. Agent integration

**Core, for every harness:** a gauntlet block in `AGENTS.md`. It holds the rule summary, the commands, and these prohibitions:
- no `--no-verify`;
- no edits to `baseline.tsv`, `exceptions.tsv` or active rules;
- stop and notify when blocked.

**Adapters, Claude Code first:**
- `SessionStart` loads the rule summary.
- `PreToolUse` on file writes runs the matching detectors on the written file and warns at write time.
- `PreToolUse` on shell denies `git commit` or `git push` with `--no-verify` or `-n`.
- `PreToolUse` on file edits denies edits to `baseline.tsv`, to `exceptions.tsv`, and to active rule files unless the change comes from `add-rule`/`propose-rule` after the owner's explicit yes.

**The runner enforces the same protections in every harness** (§9 checks 4 and 5). The adapter only makes them bite earlier.

Claude Code does not read `AGENTS.md` natively (as pawl's docs state; verify this). The adapter links it from `CLAUDE.md`.

## 13. Runner

- Written in bash + awk + git, with no jq, no Node and no compile step. It runs on Linux and macOS, and on Windows under the Git Bash that ships with git.
- Vendored at `.gauntlet/bin/gauntlet` with a pinned version. `gauntlet update` pulls a newer runner and skill from this repo.
- Commands:
  - `check [--staged | --ci]`
  - `baseline`
  - `status`
  - `test-rules`
  - `fix` (applies the linter's or ast-grep's autofixes)
  - `doctor` (are the tools installed, the hooks wired, the baseline exact, the config valid?)
  - `waive` / `loosen` / `remove` (human-only)
  - `promote <id>`
  - `base <ref>`
  - `install`
  - `update`

## 14. Rollout

1. **Build gauntlet in this repo.** It is tested with fixture git repos driven from bash.
2. **The origin project.** It migrates one hand-built ratchet per PR into gauntlet rules with the same counts, deleting the old script in the same PR. Ratchets that only locked a global number gain the new-violation and touched checks; the debt this exposes is fixed, not waived. Its commit-trailer waivers stop working. The last PR replaces its pre-push gate with `gauntlet check --ci` plus declared checks.
3. **A second repo in another language** (Python) proves language independence.

## 15. Decided by the builder (owner may override)

- `config` uses flat key=value, not YAML.
- The first CI template is GitHub Actions. Other CI providers come when a consumer needs them.
- The tool's own tests are fixture repos plus a bash test script, with no test framework dependency.
- `stage: commit | push` is set per rule, for whole-program detectors (§8).
- The commit-time check runs in `commit-msg` (§9).
- The base ref is the branch's target, for stacked PRs (§9).
- Rule cases may be single files, directories, in-project fixture paths, or config fixtures for guards (§8).
- `doctor` checks the installation and `fix` fixes the code. They are separate commands.

## 16. Open for the builder

- How each linter's native output (ESLint JSON, ruff, golangci, …) maps to `path:line`. Small adapters are written as consumers need them.
- What auto-tighten stages when a commit is partial (`git add -p`).
- How the `PreToolUse` write-time warning stays inside the latency a harness tolerates.
- How to normalize fingerprints for line-oriented `rg` rules, when a reformat splits one flagged line into several.
