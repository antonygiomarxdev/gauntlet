# Agents

gauntlet assumes most of your code is written by agents and holds them to the rules without trusting them to follow prose.

## The skill

`skills/gauntlet/SKILL.md` follows the [Agent Skills](https://github.com/anthropics/skills) format, so any harness that reads skills can use it. `gauntlet install` vendors it into `.agents/skills/gauntlet/` and symlinks it for Claude Code.

| Entry point | Does |
|---|---|
| `onboard` | detects, researches, proposes rules one at a time, measures, installs ([getting started](getting-started.md#2-onboard)) |
| `status` | regenerates `.gauntlet/STATUS.md` and summarizes it |
| `propose-rule` | turns a repeated mistake into a rule proposal, with a working detector and the current count |
| `add-rule` | writes an approved rule by the guide ([rules & detectors](rules-and-detectors.md#writing-a-good-rule)) |

### When the agent proposes a rule

Only on concrete signals:
- you corrected it twice for the same pattern;
- it fixed the same kind of mistake twice in one session;
- a `track` rule's count rose.

A proposal without a detector and a count is not a proposal. Nothing is added without your yes.

## Every harness: `AGENTS.md`

`install` adds a gauntlet block to `AGENTS.md`. The block has three parts:
- the rule summary;
- the commands;
- the prohibitions:
  - never use `--no-verify`;
  - never edit `baseline.tsv`, `exceptions.tsv` or an active rule;
  - when blocked, stop and notify.

These prohibitions are not trusted to the prose. The runner enforces them in CI whatever harness wrote the code:
- a baseline that does not equal the measurement fails;
- loosening without an exception fails.

## Adapters: biting earlier

Adapters move the bite from push time to write time. Claude Code is the first:

| Hook | Does |
|---|---|
| `SessionStart` | loads the rule summary into context |
| `PreToolUse` on file writes | runs the matching detectors on the written file and warns immediately |
| `PreToolUse` on shell | denies `git commit` / `git push` with `--no-verify` or `-n` |
| `PreToolUse` on file edits | denies edits to `baseline.tsv`, `exceptions.tsv` and active rules, except through `add-rule` after your yes |

Adapters for other harnesses are welcome; see [CONTRIBUTING](../CONTRIBUTING.md).
