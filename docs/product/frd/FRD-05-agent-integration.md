# FRD — Agent integration

**Status:** Draft
**Key:** AGENT
**Parent PRD:** [PRD — gauntlet](../PRD.md)
**Owner:** Antony Giomar Hernández

## 1. Functional problem

Agents read the rules and agree with them, then break them three PRs later. Prose prohibitions such as "don't skip hooks" or "don't touch the baseline" are not enforcement. gauntlet must:
- give every agent the rules and the commands;
- bite at write time where the harness allows it;
- enforce the same protections in CI for every harness, whatever the agent did locally.

## 2. Actors and situations

| Actor | Situation |
|---|---|
| Agent | Works in Claude Code, Codex, Command Code or any other harness, with any model. |
| Owner | Approves rule changes and creates exceptions. |
| CI | Enforces, whatever happened locally. |

## 3. Preconditions

- gauntlet is installed and onboarded.
- For the adapter: the harness supports hooks. Claude Code is first.

## 4. Business rules

1. **The skill.** It ships in the Agent Skills format (`SKILL.md`), with the entry points `onboard`, `status`, `propose-rule` and `add-rule`. It is vendored into `.agents/skills/gauntlet/`, with a symlink for Claude Code.
2. **`AGENTS.md`** gets one gauntlet block, and only one, with three parts:
   - the rule summary;
   - the commands;
   - the prohibitions: never `--no-verify`; never edit `baseline.tsv`, `exceptions.tsv` or an active rule; when blocked, stop and notify.
3. **`CLAUDE.md` links `AGENTS.md`**, because Claude Code may not read `AGENTS.md` by itself. See open question 1.
4. **The Claude Code adapter:**
   - **`SessionStart`** loads the rule summary.
   - **`PreToolUse` on file writes** runs the matching detectors on the written file and warns at write time. It warns, it does not deny.
   - **`PreToolUse` on shell** denies `git commit` and `git push` with `--no-verify` or `-n`.
   - **`PreToolUse` on file edits** denies edits to `baseline.tsv`, to `exceptions.tsv` and to active rule files. The one exception is a change made through `add-rule` or `propose-rule` after the Owner's explicit yes.
5. **The runner enforces in every harness.** CI fails a baseline that does not equal the measurement and any loosening without an exception (GATE checks 4 and 5). The adapter only makes these bite earlier.
6. **When blocked, the Agent stops.** It proposes the exact exception command with its reason and notifies the human. It never works around the gate.

## 5. Functional flows

### Flow A — session start (Claude Code)

The rule summary is in context before the first edit.

### Flow B — the Agent writes a file

1. The adapter runs the detectors that match the file.
2. On a violation, the Agent sees the rule and the fix line right away, before committing.

### Flow C — the Agent tries to skip hooks

`git commit --no-verify` is denied, with the reason.

### Flow D — the Agent tries to edit the baseline

The edit is denied. The message says the baseline is derived, and that only `gauntlet baseline` or the commit gate writes it.

## 6. Edge cases and failure behavior

- **A harness without hooks.** The `AGENTS.md` block plus CI enforcement still hold. The adapter is optional.
- **The write-time check is slow.** It must stay within the latency the harness tolerates (see open question 2). If it cannot, it is skipped and push still catches the violation.
- **An agent edits a protected file in a harness without the adapter.** The CI exact and no-loosening checks fail, and the PR diff shows it.
- **`-n` on `git push`** means `--dry-run`, not `--no-verify`. Only `git commit -n` is denied. See open question 3.

## 7. Permissions

| Action | Owner | Agent |
|---|---|---|
| Change active rules | yes | only through `add-rule` or `propose-rule` after explicit yes |
| Edit `baseline.tsv` or `exceptions.tsv` | no, the runner and the exception commands own them | no (denied) |
| Use `--no-verify` | discouraged | no (denied) |

## 8. Data semantics

- **`AGENTS.md`:** one gauntlet block, delimited by begin and end markers so a re-install replaces it in place.
- **`.agents/skills/gauntlet/`:** the vendored skill, and its Claude Code symlink.
- **Claude Code hook config:** the four hooks in §4.4, added next to any existing hooks.

## 9. Functional acceptance criteria

- **AGENT-AC1:** Given install, when it finishes, then `AGENTS.md` contains exactly one gauntlet block, with the rule summary, the commands and the three prohibitions.
- **AGENT-AC2:** Given install run twice, when it finishes, then the block is not duplicated.
- **AGENT-AC3:** Given Claude Code with the adapter, when a session starts, then the rule summary is in context.
- **AGENT-AC4:** Given Claude Code with the adapter, when the Agent writes a file with a `block` violation, then it is warned immediately with the rule and the fix line.
- **AGENT-AC5:** Given Claude Code with the adapter, when the Agent runs `git commit --no-verify`, `git commit -n` or `git push --no-verify`, then the command is denied.
- **AGENT-AC6:** Given Claude Code with the adapter, when the Agent edits `.gauntlet/baseline.tsv` or `.gauntlet/exceptions.tsv`, then the edit is denied.
- **AGENT-AC7:** Given Claude Code with the adapter, when the Agent edits an active rule without the Owner's yes in `add-rule` or `propose-rule`, then the edit is denied.
- **AGENT-AC8:** Given any harness without an adapter, when an agent pushes a hand-edited baseline or a loosened rule, then CI fails.
- **AGENT-AC9:** Given install, when it finishes, then the skill is at `.agents/skills/gauntlet/SKILL.md`, and Claude Code can load it through its symlink.
- **AGENT-AC10:** Given a blocked agent, when it reports, then the report contains the exact exception command with a reason, and no workaround was applied.

## 10. Out of scope

- Adapters for other harnesses (Codex, Command Code, …). They are welcome as contributions.
- Multi-agent orchestration.

## 11. Dependencies on other FRDs

| FRD | Why |
|---|---|
| FRD-01 Onboarding (ONB) | Install writes the block and the adapter. |
| FRD-03 Gates (GATE) | The runner-side enforcement. |
| FRD-04 Exceptions (EXC) | The commands the agent proposes. |
| FRD-06 Rule lifecycle (LIFE) | `add-rule` and `propose-rule`. |

## 12. Open questions

1. **Does Claude Code read `AGENTS.md` natively?** pawl's docs say it does not. To be verified against the current docs before the adapter ships. Proposed default: link it from `CLAUDE.md` regardless, since a link is harmless.
2. **What is the latency budget for the write-time warning**? Proposed default: 1 s per write, running only the commit-stage rules whose `paths` match. Over budget, the warning is skipped with a one-line note that it was skipped; the commit gate still checks. Nothing is skipped silently.
3. **Is `git push -n` denied?** Proposed default: no, because `-n` is `--dry-run` for push. Deny only `--no-verify` on push, and both `--no-verify` and `-n` on commit.
