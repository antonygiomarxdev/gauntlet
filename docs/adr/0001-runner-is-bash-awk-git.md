# ADR-0001: The runner is bash, awk and git

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0004](0004-declarative-detectors-only.md), [ADR-0011](0011-changelog-fragments-with-changie.md), [VISION](../VISION.md), [TP-01](../architecture/TP-01-gauntlet.md)

## Context

gauntlet must work in any repository: any language, any agent harness, any model. A runner that needs Node, Python or a compiled binary drags a runtime into repos that have none, and adds an install step a teammate can forget. Every machine that runs git already has bash and awk.

## Decision

1. The runner is written in bash, POSIX awk and git, plus coreutils (`sed`, `sort`, `grep`, `mktemp`, `date`, `cat`, `cp`, `mkdir`, `rm`). No jq, no Node, no Python, no compile step.
2. It stays compatible with bash 3.2, which is the macOS default. That rules out associative arrays, `mapfile`, `readarray`, `${x,,}`, `declare -n` and `|&`.
3. awk stays POSIX, so it runs on BWK awk on macOS: no `gensub`, `asort`, `strftime`, `systime`, `\s` or `{n}` intervals.
4. Supported platforms are Linux, macOS, and Windows under the Git Bash that ships with git.
5. The runner is vendored into the consuming repo under `.gauntlet/` with a pinned version. A teammate who clones the repo gets gauntlet without installing anything.

Detector engines (`rg`, `ast-grep`, the project's linter) are not part of the runner. They are needed only when a rule uses them, and `doctor` names the missing ones.

## Consequences

- Zero runtime dependencies for gauntlet itself, and nothing to install beyond what git already brings.
- Data moves as TSV and every join is done in awk. That is slower to write than in a general-purpose language, and harder to read.
- Bash 3.2 and BWK awk limits must be tested: CI runs the suite on Linux and macOS.
- Maintainer tooling (changie, shellcheck) may need other runtimes. Those never ship to consumers.

## Alternatives considered

- **Node or Python.** Rich ecosystem, but it adds a runtime to every repo that lacks one, and readers would assume gauntlet needs it.
- **A Go or Rust binary.** Fast and self-contained, but it needs a release per platform, a compile step for contributors, and a binary that must be trusted in the repo.
- **jq for data handling.** It is not installed by default on macOS or in Git Bash.
